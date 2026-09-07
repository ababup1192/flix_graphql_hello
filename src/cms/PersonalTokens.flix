///
/// Personal Access Token（PAT）。人の代わりに CLI やスクリプトが使う。本人の役割で動き（read なら読むだけ）、
/// 生のトークンは作った時に 1 回だけ返し、DB には sha256(pepper + token) だけ置く。期限は必須（既定 90 日、最長 365 日）。
/// プロジェクトを持たない（本人に付く）ので Tenant は取らない。
///
/// WhyNot: 期限無しを許さないのは、人のトークンは漏れても気づきにくく、鍵の棚卸しが要るため。長く使う物はプロジェクトの API キーを使う。
///
mod PersonalTokens {

    /// 生のトークンの接頭辞。API キー（cms_）とは別の形にして、ヘッダの値だけで見分けられるようにする。
    pub def prefix(): String = "cmspat_"

    /// 既定と上限の有効期間（日）。
    pub def defaultTtlDays(): Int32 = 90
    pub def maxTtlDays(): Int32 = 365

    ///
    /// 発行する。本人（書ける主体）だけ。ttlDays は 1 〜 365。
    ///
    pub def issue(pepper: ApiKeys.Pepper, draft: PersonalTokenDraft, nowMillis: Int64): IssuedPersonalAccessToken \ DbWrite + CmsErr + IdGen + Session =
        let user = Session.currentUser();
        CmsErr.raiseIfAny(Naming.validateName("name", draft#name));
        let ttlDays = draft#ttlDays |> Option.getWithDefault(defaultTtlDays());
        CmsErr.raiseIfAny(if (ttlDays >= 1 and ttlDays <= maxTtlDays()) Nil else Violation.Violation("ttlDays", "1 〜 ${maxTtlDays()} 日にしてください") :: Nil);
        let token = prefix() ++ IdGen.freshSecret();
        let publicId = IdGen.freshPublicId();
        let expiresAt = Timestamp.fromEpochMillis(nowMillis + Int32.toInt64(ttlDays) * 86_400_000i64);
        let id = AuthQueries.insertPersonalToken({
            publicId = publicId, userId = UserId.toInt64(user), name = draft#name, tokenHash = ApiKeys.hash(pepper, token),
            pepperId = pepper#pepperId, scope = PatScope.text(draft#scope), expiresAt = expiresAt }) |> Rows.expectId;
        { id = id, publicId = publicId, name = draft#name, scope = draft#scope, expiresAt = expiresAt, token = token }

    ///
    /// 失効する。本人の物だけ（他人の物は notFound。RLS も同じ行しか見せない）。
    ///
    pub def revoke(publicId: String): Unit \ DbWrite + CmsErr + Session =
        let user = Session.currentUser();
        let changed = AuthQueries.revokePersonalToken({ publicId = publicId, userId = UserId.toInt64(user) });
        if (changed == 0) CmsErr.notFound(Entity.PersonalAccessToken, publicId) else ()

    ///
    /// 自分の PAT の一覧。人でなければ空。
    ///
    pub def list(): List[PersonalAccessToken] \ DbRead + DbErr + Session =
        Session.currentUserForRead()
            |> Option.map(user -> AuthQueries.listPersonalTokens(UserId.toInt64(user)) |> List.map(AuthRows.toPersonalAccessToken))
            |> Option.getWithDefault(Nil)

    ///
    /// 生のトークンから本人と範囲。hash を Tx の印にしてから引く（RLS はその 1 行だけ見せる）。失効・期限切れ・知らない物は None。
    ///
    pub def resolve(pepper: ApiKeys.Pepper, raw: String, nowMillis: Int64): Option[ResolvedPersonalToken] \ DbRead =
        if (not String.startsWith(prefix = prefix(), raw)) None
        else {
            let tokenHash = ApiKeys.hash(pepper, raw);
            discard TenantQueries.stampTokenHash(tokenHash);
            AuthQueries.findPersonalTokenByHash(tokenHash)
                |> Option.filter(row -> ApiKeys.isAlive({ expiresAt = Some(row#expiresAt), revokedAt = row#revokedAt }, nowMillis))
                |> Option.flatMap(row -> PatScope.parse(row#scope) |> Option.map(scope -> { id = row#id, userId = UserId.UserId(row#userId), scope = scope }))
        }

    ///
    /// 最終使用時刻を書く。1 分に 1 回だけ。本人の印（Accounts.resolveUserById）を置いた後に呼ぶ。
    ///
    pub def touch(id: Int64): Unit \ DbWrite =
        discard AuthQueries.touchPersonalToken(id)

}
