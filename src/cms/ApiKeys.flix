///
/// 公開 API の鍵。人ではなくアプリ用。生の鍵は作った時に 1 回だけ返し、DB には sha256(pepper + key) だけ置く。
///
mod ApiKeys {

    ///
    /// ハッシュに混ぜる秘密と、その版（回した時に古い鍵を見分ける）。
    ///
    pub type alias Pepper = { pepperId = String, secret = String }

    /// 生の鍵の接頭辞。secret scanning に引っかかる形で、他の文字列と見分けやすくする。
    pub def prefix(): String = "cms_"

    ///
    /// 発行する。今のプロジェクトに付く。
    ///
    pub def create(pepper: Pepper, name: String, scope: ApiKeyScope): IssuedApiKey \ DbWrite + CmsErr + IdGen + Tenant + Session =
        Session.require(Permission.ManageApiKeys);
        CmsErr.raiseIfAny(if (String.isEmpty(String.trim(name))) Violation.Violation("name", "名前を付けてください") :: Nil else Nil);
        let key = prefix() ++ IdGen.freshSecret();
        let publicId = IdGen.freshPublicId();
        let id = AuthQueries.insertApiKey({ publicId = publicId, projectId = Tenant.currentId(), name = name, keyHash = hash(pepper, key), pepperId = pepper#pepperId, scope = ApiKeyScope.text(scope) }) |> Rows.expectId;
        { id = id, publicId = publicId, name = name, scope = scope, key = key }

    ///
    /// 失効する。行は残す。
    ///
    pub def revoke(publicId: String): Unit \ DbWrite + CmsErr + Tenant + Session =
        Session.require(Permission.ManageApiKeys);
        let changed = AuthQueries.revokeApiKey({ publicId = publicId, projectId = Tenant.currentId() });
        if (changed == 0) CmsErr.notFound(Entity.ApiKey, publicId) else ()

    ///
    /// 今のプロジェクトの鍵の一覧。
    ///
    pub def list(): List[ApiKey] \ DbRead + DbErr + CmsErr + Tenant + Session =
        Session.require(Permission.ManageApiKeys);
        AuthQueries.listApiKeys(Tenant.currentId()) |> List.map(row -> {
            id = row#id, publicId = row#publicId, name = row#name,
            scope = ApiKeyScope.parse(row#scope) |> Rows.orRaise("api_keys.scope", row#scope),
            createdAt = row#createdAt, revokedAt = row#revokedAt
        })

    ///
    /// 生の鍵からこのプロジェクトの範囲を引く。hash で引いた後にプロジェクトが一致するかを確かめる（鍵がプロジェクトを決めない）。
    /// 失効した物、他のプロジェクトの物、知らない物は None。
    ///
    pub def resolve(pepper: Pepper, key: String, projectId: ProjectId): Option[ApiKeyScope] \ DbRead =
        AuthQueries.findApiKeyByHash(hash(pepper, key))
            |> Option.filter(row -> row#projectId == ProjectId.toInt64(projectId) and Option.isEmpty(row#revokedAt))
            |> Option.flatMap(row -> ApiKeyScope.parse(row#scope))

    ///
    /// sha256(pepper + key) の 16 進。
    ///
    pub def hash(pepper: Pepper, key: String): String =
        SigV4.sha256Hex("${pepper#secret}:${key}")

}
