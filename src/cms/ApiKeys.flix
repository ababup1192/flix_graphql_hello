///
/// 公開 API と CI 用の鍵。人ではなくアプリ用。生の鍵は作った時に 1 回だけ返し、DB には sha256(pepper + key) だけ置く。
/// read / readDraft は読むだけ、write は役割（writer / editor / owner）の範囲で管理 API を叩ける（メンバー・鍵・プロジェクトの管理は不可）。
///
mod ApiKeys {

    ///
    /// ハッシュに混ぜる秘密と、その版（回した時に古い鍵を見分ける）。
    ///
    pub type alias Pepper = { pepperId = String, secret = String }

    ///
    /// 生の鍵から解いた結果。主体と、使用時刻を書くための id。
    ///
    pub type alias ResolvedApiKey = { id = Int64, scope = ApiKeyScope }

    /// 生の鍵の接頭辞。secret scanning に引っかかる形で、他の文字列と見分けやすくする。
    pub def prefix(): String = "cms_"

    ///
    /// 発行する。今のプロジェクトに付く。write の鍵は発行者が持つ役割より高い役割にはできない。
    ///
    pub def create(pepper: Pepper, draft: ApiKeyDraft): IssuedApiKey \ DbWrite + CmsErr + IdGen + Tenant + Session =
        Session.require(Permission.ManageApiKeys);
        CmsErr.raiseIfAny(Naming.validateName("name", draft#name));
        requireRoleWithinIssuer(draft#scope);
        let key = prefix() ++ IdGen.freshSecret();
        let publicId = IdGen.freshPublicId();
        let id = AuthQueries.insertApiKey({
            publicId = publicId, projectId = Tenant.currentId(), name = draft#name, keyHash = hash(pepper, key), pepperId = pepper#pepperId,
            scope = ApiKeyScope.text(draft#scope), role = ApiKeyScope.roleOf(draft#scope) |> Option.map(Role.text) |> Option.getWithDefault(""),
            expiresAtMillis = draft#expiresAt |> Option.map(Timestamp.toEpochMillis) |> Option.getWithDefault(0i64) }) |> Rows.expectId;
        { id = id, publicId = publicId, name = draft#name, scope = draft#scope, expiresAt = draft#expiresAt, key = key }

    ///
    /// write の鍵の役割は writer 以上で、発行者の役割を超えていれば invalid。人でない主体（System）は発行者の検査をしない。
    ///
    /// WhyNot: forbidden でなく invalid にするのは、鍵を作る権限自体はあり、入力（role）が合わないだけのため。
    ///
    def requireRoleWithinIssuer(scope: ApiKeyScope): Unit \ Session + CmsErr = match scope {
        case ApiKeyScope.Write(role) =>
            CmsErr.raiseIfAny(if (ApiKeyScope.isWritingRole(role)) Nil else Violation.Violation("role", "WRITE の鍵の役割は WRITER / EDITOR / OWNER です") :: Nil);
            match Session.current() {
                case Actor.User(_, _, roles) =>
                    CmsErr.raiseIfAny(if (Authz.highestRole(roles) |> Option.exists(highest -> highest >= role)) Nil
                                      else Violation.Violation("role", "自分の役割より高い役割（${Role.text(role)}）の鍵は作れません") :: Nil)
                case _ => ()
            }
        case _ => ()
    }

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
        AuthQueries.listApiKeys(Tenant.currentId()) |> List.map(AuthRows.toApiKey)

    ///
    /// 生の鍵からこのプロジェクトの範囲を引く。hash で引いた後にプロジェクトが一致するかを確かめる（鍵がプロジェクトを決めない）。
    /// 失効した物、期限の切れた物、他のプロジェクトの物、知らない物は None。
    ///
    pub def resolve(pepper: Pepper, key: String, projectId: ProjectId, nowMillis: Int64): Option[ResolvedApiKey] \ DbRead =
        AuthQueries.findApiKeyByHash(hash(pepper, key))
            |> Option.filter(row -> row#projectId == ProjectId.toInt64(projectId) and isAlive({ expiresAt = row#expiresAt, revokedAt = row#revokedAt }, nowMillis))
            |> Option.flatMap(row -> ApiKeyScope.parse(row#scope, row#role) |> Option.map(scope -> { id = row#id, scope = scope }))

    ///
    /// 失効しておらず、期限が来ていないか。期限が無ければ切れない。純粋。
    ///
    pub def isAlive(key: { expiresAt = Option[Timestamp.Timestamp], revokedAt = Option[Timestamp.Timestamp] }, nowMillis: Int64): Bool =
        Option.isEmpty(key#revokedAt) and (key#expiresAt |> Option.forAll(deadline -> Timestamp.toEpochMillis(deadline) > nowMillis))

    ///
    /// 最終使用時刻を書く。1 分に 1 回だけ（それより新しければ何もしない）。
    ///
    pub def touch(id: Int64): Unit \ DbWrite + Tenant =
        discard AuthQueries.touchApiKey({ id = id, projectId = Tenant.currentId() })

    ///
    /// sha256(pepper + key) の 16 進。
    ///
    pub def hash(pepper: Pepper, key: String): String =
        Sha256.hex("${pepper#secret}:${key}")

}
