///
/// Personal Access Token（PAT）。人の代わりに CLI やスクリプトが使う。本人の役割で動き（read なら読むだけ）、
/// 生のトークンは作った時に 1 回だけ返し、DB には sha256(pepper + token) だけ置く（SecretHash）。期限は必須（既定 90 日、最長 365 日）。
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
    /// 発行する。ログインの JWT で来た本人だけ（PAT から PAT は作れない。漏れた PAT を失効すれば、それで作った物が無い）。ttlDays は 1 〜 365。
    ///
    pub def issue(pepper: SecretHash.Pepper, draft: PersonalTokenDraft, nowMillis: Int64): IssuedPersonalAccessToken \ DbWrite + CmsErr + IdGen + Session =
        Session.requireInteractive();
        let user = Session.currentUser();
        CmsErr.raiseIfAny(Naming.validateName("name", draft#name));
        let ttlDays = draft#ttlDays |> Option.getWithDefault(defaultTtlDays());
        CmsErr.raiseIfAny(if (ttlDays >= 1 and ttlDays <= maxTtlDays()) Nil else Violation.Violation("ttlDays", "1 〜 ${maxTtlDays()} 日にしてください") :: Nil);
        let token = prefix() ++ IdGen.freshSecret();
        let publicId = IdGen.freshPublicId();
        let expiresAt = Timestamp.fromEpochMillis(nowMillis + Int32.toInt64(ttlDays) * 86_400_000i64);
        let id = AuthQueries.insertPersonalToken({
            publicId = publicId, userId = UserId.toInt64(user), name = draft#name, tokenHash = SecretHash.hash(pepper, token),
            pepperId = pepper#pepperId, scope = PatScope.text(draft#scope), expiresAt = expiresAt }) |> Rows.expectId;
        { id = id, publicId = publicId, name = draft#name, scope = draft#scope, expiresAt = expiresAt, token = token }

    ///
    /// 失効する。本人の物だけ（他人の物は notFound。RLS も同じ行しか見せない）。write の PAT からもできる（減らす方向は許す）。
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
    /// 生のトークンから本人と範囲。hash を Tx の印にしてから引く（RLS はその 1 行だけ見せる）。
    /// 失効・期限切れ・知らない物は理由付きで Err（Runner が「認証に失敗しました」にする）。
    ///
    pub def resolve(pepper: SecretHash.Pepper, raw: String, nowMillis: Int64): Result[PatRejection, ResolvedPersonalToken] \ DbRead =
        if (not String.startsWith(prefix = prefix(), raw)) Err(PatRejection.Unknown)
        else {
            let tokenHash = SecretHash.hash(pepper, raw);
            discard TenantQueries.stampTokenHash(tokenHash);
            match AuthQueries.findPersonalTokenByHash(tokenHash) {
                case None                                          => Err(PatRejection.Unknown)
                case Some(row) if Option.nonEmpty(row#revokedAt)   => Err(PatRejection.Revoked)
                case Some(row) if Timestamp.toEpochMillis(row#expiresAt) <= nowMillis => Err(PatRejection.Expired)
                case Some(row) =>
                    PatScope.parse(row#scope)
                        |> Option.map(scope -> { id = row#id, userId = UserId.UserId(row#userId), scope = scope })
                        |> Option.toOk(PatRejection.Unknown)
            }
        }

    ///
    /// 最終使用時刻を書く。1 分に 1 回だけ。本人の印（Accounts.resolveUserById）を置いた後に呼ぶ。書いた行数を返す。
    ///
    pub def touch(id: Int64): Int32 \ DbWrite =
        AuthQueries.touchPersonalToken(id)

}
