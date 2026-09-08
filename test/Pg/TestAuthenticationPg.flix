///
/// Authentication.resolve を実 PostgreSQL で直に呼び、Rejection の 5 腕（Invalid / DeadToken / NotForAccount / PrivateProject / NotMember）が
/// どの Credential × エンジン（Admin / Account / Content）× プロジェクトの公開範囲（public / private）で出るかを表で固定する。
/// 既に他のテストが GraphQL 越しに見ている組み合わせ（Admin の壊れた JWT・死んだ PAT・知らない鍵、Account の鍵、Content の匿名・壊れた JWT・
/// メンバー外の JWT・生きた鍵）は入れず、無い組み合わせだけを並べる。
///
mod TestAuthenticationPg {

    use Util.Json.Json

    /// seed が発行したトークン。
    type alias Issued = { preview = String, ownerPat = String, strangerPat = String, expiredPat = String }

    /// 2 日前に 1 日で発行すると期限切れ。
    def twoDaysAgo(): Int64 = 1_700_000_000_000i64

    /// 生きたトークンの発行時刻（2100 年。プレビューは 1 時間後、PAT は 90 日後に切れるので、本物の時計で検証しても切れない）。
    def farFuture(): Int64 = 4_102_444_800_000i64

    /// メンバーでない人の Bearer。
    def strangerBearer(): Credential = PgTestSupport.bearer("stranger", "stranger@example.com")

    /// このユーザーとして（プロジェクト無し）PAT を発行し、生のトークンを返す。
    def issuePatAs(user: User, ttlDays: Option[Int32], nowMillis: Int64): String \ DbWrite + CmsErr + IdGen =
        Session.runWith(Accounts.actorWithoutProject(user, Login.Interactive), () ->
            PersonalTokens.issue(Session.grantInteractive(), PgTestSupport.pepper(), { name = "cli", scope = PatScope.Write, ttlDays = ttlDays }, nowMillis))#token

    ///
    /// blogs 型と entry e1 を作り、e1 のプレビュートークン・owner の PAT・メンバーでない人（stranger）の PAT・owner の期限切れの PAT を発行する。
    ///
    def seed(): Issued \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        let entry = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("e1")), CmsTestKit.entryData(List#{("title", Json.JString("hi"))}));
        let now = farFuture();
        let owner = PgTestSupport.ownerUser();
        let stranger = Accounts.resolveUser({ ownerEmail = None }, { issuer = "test", subject = "stranger", email = "stranger@example.com", name = "stranger" });
        { preview =PreviewTokens.issue(Session.grant(), PgTestSupport.pepper(), entry#id, { ttlSeconds = 3600i64, nowMillis = farFuture() })#token,
          ownerPat = issuePatAs(owner, None, now),
          strangerPat = issuePatAs(stranger, None, now),
          expiredPat = issuePatAs(owner, Some(1), twoDaysAgo()) }

    ///
    /// 認証の結果を比べられる形に。通れば認証済みユーザー（人は id を 0 に揃え、email と役割とログインの種類で見る）、断られれば Rejection。
    ///
    def summarize(auth: Result[Rejection, Authenticated]): Result[Rejection, Actor] =
        auth |> Result.map(found -> match found#actor {
            case Actor.User(_, email, roles, login) => Actor.User(UserId.UserId(0i64), email, roles, login)
            case other                              => other
        })

    /// 人の認証済みユーザー（id は 0 に揃えた形）。
    def user(email: String, roles: List[Role], login: Login): Result[Rejection, Actor] =
        Ok(Actor.User(UserId.UserId(0i64), email, roles, login))

    ///
    /// 表: (公開範囲, エンジン, Credential) → 認証の結果。
    ///
    ///   Invalid        Account × 壊れた JWT（SQL を出さずに断る。Admin は TestServerAuthPg、Content は匿名に落ちる = TestAuthPg）
    ///   DeadToken      Account × 期限切れの PAT、Content × 期限切れ / 知らない PAT（public でも断る。死んだ PAT は可視性より先）
    ///   NotForAccount  Account × プレビュートークン（鍵は TestAccountPg）
    ///   PrivateProject Content × private × 知らない鍵 / 改ざんしたプレビュートークン（匿名に落ちてから可視性で断る）
    ///   NotMember      Content × private × メンバーでない人の PAT（JWT は TestAuthPg）
    ///   通る物          Admin × 匿名 / private でもメンバーでない JWT（Admin は可視性を見ない）、Content × プレビュートークン（private でも）、
    ///                  Content × public × メンバーでない人の PAT、Content × private × owner の PAT
    ///
    @Test
    def testPgResolveRejectionTable(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let issued = PgTestSupport.seed(seed);
            let table: List[(String, Engine, Credential, Result[Rejection, Actor])] = List#{
                // Invalid
                ("public",  Engine.Account, Credential.Invalid("JWT は無し"),                Err(Rejection.Invalid("JWT は無し"))),
                // DeadToken
                ("public",  Engine.Account, Credential.PersonalToken(issued#expiredPat),    Err(Rejection.DeadToken(PatRejection.Expired))),
                ("public",  Engine.Content, Credential.PersonalToken(issued#expiredPat),    Err(Rejection.DeadToken(PatRejection.Expired))),
                ("public",  Engine.Content, Credential.PersonalToken("cmspat_nope"),        Err(Rejection.DeadToken(PatRejection.Unknown))),
                ("private", Engine.Content, Credential.PersonalToken(issued#expiredPat),    Err(Rejection.DeadToken(PatRejection.Expired))),
                // NotForAccount
                ("public",  Engine.Account, Credential.Preview(issued#preview),             Err(Rejection.NotForAccount("プレビュートークン"))),
                // PrivateProject
                ("private", Engine.Content, Credential.ApiKey("cms_unknown"),               Err(Rejection.PrivateProject)),
                ("private", Engine.Content, Credential.Preview(issued#preview + "x"),       Err(Rejection.PrivateProject)),
                // NotMember
                ("private", Engine.Content, Credential.PersonalToken(issued#strangerPat),   Err(Rejection.NotMember)),
                // 通る物
                ("public",  Engine.Admin,   Credential.Missing,                             Ok(Actor.Anonymous)),
                ("private", Engine.Admin,   Credential.Missing,                             Ok(Actor.Anonymous)),
                ("private", Engine.Admin,   strangerBearer(),                               user("stranger@example.com", Nil, Login.Interactive)),
                ("public",  Engine.Content, Credential.Preview(issued#preview),             Ok(Actor.Preview(CmsTestKit.entryId("e1")))),
                ("private", Engine.Content, Credential.Preview(issued#preview),             Ok(Actor.Preview(CmsTestKit.entryId("e1")))),
                ("public",  Engine.Content, Credential.PersonalToken(issued#strangerPat),   user("stranger@example.com", Nil, Login.PersonalToken(PatScope.Write))),
                ("private", Engine.Content, Credential.PersonalToken(issued#ownerPat),      user("owner@test", Role.Owner :: Nil, Login.PersonalToken(PatScope.Write)))
            };
            let results = table |> List.map(match (visibility, engine, credential, _) -> {
                discard PgTestSupport.mutate(pool, () -> AuthQueries.updateProjectVisibility({ projectId = ProjectId.toInt64(ProjectId.default()), visibility = visibility }));
                PgTestSupport.authenticate(pool, engine, credential) |> summarize
            });
            (table |> List.map(match (_, _, _, expected) -> expected), results)
        });
        Assert.assertEq(expected = fst(outcome), snd(outcome))

}
