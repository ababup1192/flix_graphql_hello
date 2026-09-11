///
/// 公開 API と CI 用の鍵。人ではなくアプリ用。生の鍵は作った時に 1 回だけ返し、DB には sha256(pepper + key) だけ置く（SecretHash）。
/// read / readDraft は読むだけ、write は役割（writer / editor / owner）の範囲で管理 API を叩ける（メンバー・鍵・プロジェクトの管理は不可）。
///
mod ApiKeys {

    ///
    /// 生の鍵から解いた結果。主体と、使用時刻を書くための id。
    ///
    pub type alias ResolvedApiKey = { id = Int64, name = String, scope = ApiKeyScope }

    /// 生の鍵の接頭辞。secret scanning に引っかかる形で、他の文字列と見分けやすくする。
    pub def prefix(): String = "cms_"

    ///
    /// 一覧に出す目印。末尾 4 文字だけで、これだけでは鍵にならない（Stripe / AWS と同じ長さ）。
    ///
    pub def hint(key: String): String =
        let n = String.length(key);
        if (n <= 4) key else String.sliceRight(start = n - 4, key)

    ///
    /// 発行する。今のプロジェクトに付く。manageApiKeys の証明と、ログインの JWT で来た本人の証明（`Granted[Interactive]`。PAT や鍵からは作れない）の 2 つを受ける。
    /// write の鍵は発行者が持つ役割より高い役割にはできず、期限は未来だけ。
    ///
    pub def create(_proof: Granted[ManageApiKeys], _login: Granted[Interactive], pepper: SecretHash.Pepper, draft: ApiKeyDraft, nowMillis: Int64): IssuedApiKey \ Db + CmsErr + IdGen + Tenant + Session =
        CmsErr.raiseIfAny(Naming.validateName("name", draft#name));
        requireUniqueName(draft#name);
        requireRoleWithinIssuer(draft#scope);
        CmsErr.raiseIfAny(validateExpiry(draft#expiresAt, nowMillis));
        let key = prefix() ++ IdGen.freshSecret();
        let publicId = IdGen.freshPublicId();
        let id = AuthQueries.insertApiKey(AuthRows.toApiKeyInsert({
            publicId = publicId, projectId = Tenant.currentId(), name = draft#name, keyHash = SecretHash.hash(pepper, key), keyHint = hint(key),
            pepperId = pepper#pepperId, scope = draft#scope, expiresAt = draft#expiresAt })) |> Rows.expectId;
        Audit.record(AuditChange.ApiKeyCreated(publicId, draft#name));
        { id = id, publicId = publicId, name = draft#name, scope = draft#scope, expiresAt = draft#expiresAt, key = key }

    ///
    /// 生きている鍵の中で同じ名前は 1 本だけ。失効した物とは被って良い。
    ///
    /// WhyNot: 失効した物も含めて断らない。鍵の入れ替えは「同じ名前で発行し直す → 差し替える → 古い方を失効」の
    /// 順で、失効した名前が使えないと入れ替えのたびに名前を変える事になる。
    /// WhyNot: 一意制約で守らない。同じ Tx の中で先に読んで検査する（一意制約の違反は Tx を abort させ、翻訳できない）。
    ///
    def requireUniqueName(name: String): Unit \ DbRead + CmsErr + Tenant =
        let taken = AuthQueries.countActiveApiKeysNamed({ projectId = Tenant.currentId(), name = name }) |> Rows.total;
        CmsErr.raiseIfAny(if (taken == 0i64) Nil else Violation.Violation("name", "「${name}」はすでにあります。古い方を失効するか、別の名前にしてください") :: Nil)

    ///
    /// 期限は今より後。無ければ期限無し。純粋。
    ///
    pub def validateExpiry(expiresAt: Option[Timestamp.Timestamp], nowMillis: Int64): List[Violation] =
        if (expiresAt |> Option.forAll(deadline -> Timestamp.toEpochMillis(deadline) > nowMillis)) Nil
        else Violation.Violation("expiresAt", "期限は未来にしてください") :: Nil

    ///
    /// write の鍵の役割は writer 以上で、発行者の役割を超えていれば invalid。人でない主体（System）は発行者の検査をしない。
    ///
    /// WhyNot: forbidden でなく invalid にするのは、鍵を作る権限自体はあり、入力（role）が合わないだけのため。
    ///
    pub def requireRoleWithinIssuer(scope: ApiKeyScope): Unit \ Session + CmsErr = match scope {
        case ApiKeyScope.Write(role) =>
            CmsErr.raiseIfAny(if (ApiKeyScope.isWritingRole(role)) Nil else Violation.Violation("role", "WRITE の鍵の役割は WRITER / EDITOR / OWNER です") :: Nil);
            match Session.current() {
                case Actor.User(_, _, roles, _) =>
                    CmsErr.raiseIfAny(if (Authz.highestRole(roles) |> Option.exists(highest -> highest >= role)) Nil
                                      else Violation.Violation("role", "自分の役割より高い役割（${Role.text(role)}）の鍵は作れません") :: Nil)
                case Actor.ApiKey(_, _) => ()
                case Actor.Anonymous    => ()
                case Actor.Preview(_)   => ()
                case Actor.System       => ()
            }
        case ApiKeyScope.Read      => ()
        case ApiKeyScope.ReadDraft => ()
    }

    ///
    /// 失効する。行は残す。
    ///
    pub def revoke(_proof: Granted[ManageApiKeys], publicId: String): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let changed = AuthQueries.revokeApiKey({ publicId = publicId, projectId = Tenant.currentId() });
        if (changed == 0) CmsErr.notFound(Entity.ApiKey, publicId) else ();
        Audit.record(AuditChange.ApiKeyRevoked(publicId))

    ///
    /// 今のプロジェクトの鍵の一覧。
    ///
    pub def list(_proof: Granted[ManageApiKeys]): List[ApiKey] \ DbRead + Tenant =
        AuthQueries.listApiKeys(Tenant.currentId()) |> List.map(AuthRows.toApiKey)

    ///
    /// 生の鍵からこのプロジェクトの範囲を引く。hash で引いた後にプロジェクトが一致するかを確かめる（鍵がプロジェクトを決めない）。
    /// 失効した物は Revoked、期限の切れた物は Expired、他のプロジェクトの物と知らない物は Unknown。
    ///
    /// WhyNot: 証明を取らないのは、認証（Authentication.resolve）が認証済みユーザーを決める前に呼ぶ物で、まだ判定する主体が無いため。
    ///
    /// WhyNot: 他のプロジェクトの鍵を Unknown と分けないのは、応答は匿名で同じで、ログで分けても鍵の持ち主にしか意味が無く、
    /// 総当たりと区別が要るのは「期限切れ・失効（正規の鍵が古い）」と「知らない」の 2 つだけのため。
    ///
    pub def resolve(pepper: SecretHash.Pepper, key: String, projectId: ProjectId, nowMillis: Int64): Result[ApiKeyRejection, ResolvedApiKey] \ DbRead =
        match AuthQueries.findApiKeyByHash(SecretHash.hash(pepper, key)) |> Option.filter(row -> row#projectId == ProjectId.toInt64(projectId)) {
            case None                                                               => Err(ApiKeyRejection.Unknown)
            case Some(row) if Option.nonEmpty(row#revokedAt)                        => Err(ApiKeyRejection.Revoked)
            case Some(row) if not SecretHash.isAlive({ expiresAt = row#expiresAt, revokedAt = None }, nowMillis) => Err(ApiKeyRejection.Expired)
            case Some(row) => ApiKeyScope.parse(row#scope, row#role) |> Option.map(scope -> { id = row#id, name = row#name, scope = scope }) |> Option.toOk(ApiKeyRejection.Unknown)
        }

    ///
    /// 最終使用時刻を書く。1 分に 1 回だけ（それより新しければ何もしない）。書いた行数を返す。
    ///
    /// WhyNot: 証明を取らないのは resolve と同じ（認証の Tx で、鍵が使われた事実を書くだけ）。
    ///
    pub def touch(id: Int64, projectId: ProjectId): Int32 \ DbWrite =
        AuthQueries.touchApiKey({ id = id, projectId = ProjectId.toInt64(projectId) })

}
