///
/// Personal Access Token（PAT）を実 PostgreSQL で見る。ログインの JWT で発行し、管理 API を本人の役割で叩け、Account API の me が返り、
/// READ の PAT では書けないが自分の物は読め、PAT からは PAT も API キーも作れず、他人の PAT は一覧に出ず失効も notFound（RLS）、
/// 失効と期限切れは「認証に失敗」として断る。
///
mod TestPersonalTokenPg {

    def pepper(): SecretHash.Pepper = { pepperId = "test", secret = "test-pepper" }

    def bearer(subject: String, email: String): Credential = Credential.Bearer("test", subject, email, subject)

    /// 管理 API と Account API の両方の Schema。同じプールと依存で組む。
    def schemas(pool: Pool): (Schema, Schema) \ IO =
        let deps = PgTestSupport.deps();
        (AdminSchema.make(deps, AdminRunner.make(pool, deps, ProjectId.default())), AccountSchema.make(deps, AccountRunner.make(pool, deps)))

    def ask(schema: Schema, credential: Credential): String -> (Value, Option[String]) \ IO =
        queryText -> GraphqlTestKit.askWith(schema, Context.withCredential(credential), queryText)

    /// Account API でこの名前と scope の PAT を発行し、生のトークンを返す。
    def issueVia(account: String -> (Value, Option[String]) \ IO, name: String, scope: String): String \ IO =
        GraphqlTestKit.stringAt(List#{"createPersonalAccessToken", "token"}, account("mutation { createPersonalAccessToken(name: \"${name}\", scope: ${scope}) { token } }"))

    /// personalAccessTokens の一覧を (name, scope, lastUsedAt が付いたか, revokedAt) にして name で並べる。
    def tokensUsed(response: (Value, Option[String])): List[(String, Value, Bool, Value)] =
        GraphqlTestKit.listAt(List#{"me", "personalAccessTokens"}, response)
            |> List.map(item -> (nameOf(item), Value.field("scope", item), Value.field("lastUsedAt", item) != Value.Null, Value.field("revokedAt", item)))
            |> List.sortBy(fst4)

    def fst4(item: (a, b, c, d)): a = { let (first, _, _, _) = item; first }

    /// 一覧の 1 件の name。無ければ空。
    def nameOf(item: Value): String = Value.field("name", item) |> Value.asStr |> Option.getWithDefault("")

    /// me.organizations の先頭の組織の id。無ければテストの前提が壊れている。
    def firstOrganizationId(response: (Value, Option[String])): String = match GraphqlTestKit.listAt(List#{"me", "organizations"}, response) {
        case first :: _ => Value.path(List#{"organization", "id"}, first) |> Value.asStr |> Option.getWithDefault("")
        case Nil        => bug!("組織が無い")
    }

    def me(email: String): (Value, Option[String]) = (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "email" => Value.Str(email) }) }), None)

    ///
    /// owner が WRITE と READ の PAT を発行する。
    ///   WRITE の PAT: 管理 API の me は OWNER、createContentType が通る。Account API の me が本人
    ///   READ の PAT: 管理 API の me は VIEWER、createContentType は forbidden。Account API の createOrganization は「read の PAT ではできません」
    /// 使った PAT には lastUsedAt が付く。
    ///
    @Test
    def testPgPersonalTokenActsAsUser(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> ());
            let (admin, account) = schemas(pool);
            let owner = ask(account, PgTestSupport.ownerCredential());
            let issued = owner("mutation { createPersonalAccessToken(name: \"cli\", scope: WRITE) { name scope token } }");
            let token = GraphqlTestKit.stringAt(List#{"createPersonalAccessToken", "token"}, issued);
            let readToken = issueVia(owner, "ro", "READ");
            let viaPat = ask(admin, Credential.PersonalToken(token));
            let viaReadPat = ask(admin, Credential.PersonalToken(readToken));
            let accountViaPat = ask(account, Credential.PersonalToken(token));
            let accountViaReadPat = ask(account, Credential.PersonalToken(readToken));
            let adminMe = viaPat("{ me { email roles } }");
            let createdType = viaPat("mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { apiId } }");
            let readMe = viaReadPat("{ me { email roles } }");
            let readCreates = viaReadPat("mutation { createContentType(input: { apiId: \"tags\", name: \"タグ\" }) { apiId } }") |> snd;
            let accountMe = accountViaPat("{ me { email } }");
            let readAccountMe = accountViaReadPat("{ me { email } }");
            let readCreatesOrg = accountViaReadPat("mutation { createOrganization(name: \"Acme\") { id } }") |> snd;
            (String.startsWith(prefix = "cmspat_", token), GraphqlTestKit.valueAt(List#{"createPersonalAccessToken", "scope"}, issued),
             adminMe, createdType, readMe, readCreates, accountMe, readAccountMe, readCreatesOrg,
             owner("{ me { personalAccessTokens { name scope lastUsedAt revokedAt } } }") |> tokensUsed)
        });
        Assert.assertEq(
            expected = (
                true, Value.Str("WRITE"),
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "email" => Value.Str("owner@test"), "roles" => Value.List(Value.Str("OWNER") :: Nil) }) }), None),
                (Value.Obj(Map#{ "createContentType" => Value.Obj(Map#{ "apiId" => Value.Str("blogs") }) }), None),
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "email" => Value.Str("owner@test"), "roles" => Value.List(Value.Str("VIEWER") :: Nil) }) }), None),
                Some("この操作（manageTypes）の権限がありません"),
                me("owner@test"),
                me("owner@test"),
                Some("この操作は read の PAT ではできません。write の PAT かログインした本人で行ってください"),
                List#{ ("cli", Value.Str("WRITE"), true, Value.Null), ("ro", Value.Str("READ"), true, Value.Null) }),
            outcome)

    ///
    /// READ の PAT でも自分の物は読める。既定の組織（owner）を organization(id) で引くと name / members / projects が返り、自分の PAT の一覧も見える。
    ///
    @Test
    def testPgReadPatReadsOwnAccount(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> ());
            let (_, account) = schemas(pool);
            let owner = ask(account, PgTestSupport.ownerCredential());
            let orgId = firstOrganizationId(owner("{ me { organizations { organization { id } } } }"));
            let readToken = issueVia(owner, "ro", "READ");
            let viaReadPat = ask(account, Credential.PersonalToken(readToken));
            (viaReadPat("{ organization(id: \"${orgId}\") { name members { email } projects { slug } } }"),
             viaReadPat("{ me { personalAccessTokens { name } } }"))
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "organization" => Value.Obj(Map#{
                    "name" => Value.Str("default"),
                    "members" => Value.List(Value.Obj(Map#{ "email" => Value.Str("owner@test") }) :: Nil),
                    "projects" => Value.List(Value.Obj(Map#{ "slug" => Value.Str("default") }) :: Nil) }) }), None),
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "personalAccessTokens" => Value.List(Value.Obj(Map#{ "name" => Value.Str("ro") }) :: Nil) }) }), None)),
            outcome)

    ///
    /// 鍵で鍵を作る道は無い。WRITE の PAT（owner）で createPersonalAccessToken も createApiKey も「ログインした本人だけ」で拒まれ、
    /// 同じ PAT で inviteMember（メンバー管理）は通る。
    ///
    @Test
    def testPgPatCannotIssueSecrets(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> ());
            let (admin, account) = schemas(pool);
            let token = issueVia(ask(account, PgTestSupport.ownerCredential()), "cli", "WRITE");
            let accountViaPat = ask(account, Credential.PersonalToken(token));
            let adminViaPat = ask(admin, Credential.PersonalToken(token));
            (accountViaPat("mutation { createPersonalAccessToken(name: \"again\", scope: READ) { token } }") |> snd,
             adminViaPat("mutation { createApiKey(name: \"ci\", scope: WRITE, role: OWNER) { key } }") |> snd,
             adminViaPat("mutation { inviteMember(email: \"a@example.com\", role: VIEWER) { email } }"))
        });
        let onlyInteractive = Some("この操作はログインした本人だけができます（PAT や API キーではできません）");
        Assert.assertEq(
            expected = (onlyInteractive, onlyInteractive,
                        (Value.Obj(Map#{ "inviteMember" => Value.Obj(Map#{ "email" => Value.Str("a@example.com") }) }), None)),
            outcome)

    ///
    /// 有効期間。既定は 90 日（expiresAt が now + 90 日 ± 1 日）、365 は通り、0 と 366 は invalid。
    ///
    @Test
    def testPgPersonalTokenTtl(): Unit \ {IO, Assert} =
        let now = Time.Clock.runWithIO(Time.Clock.now);
        let day = 86_400_000i64;
        let outcome = PgTestSupport.withAccountApi(() -> (), (account, _) -> {
            let owner = ask(account, PgTestSupport.ownerCredential());
            let expiresAt = response -> GraphqlTestKit.stringAt(List#{"createPersonalAccessToken", "expiresAt"}, response) |> Timestamp.fromIso8601 |> Option.map(Timestamp.toEpochMillis);
            let byDefault = owner("mutation { createPersonalAccessToken(name: \"d\", scope: READ) { expiresAt } }") |> expiresAt;
            (byDefault |> Option.map(deadline -> Int64.abs(deadline - (now + 90i64 * day)) < day),
             owner("mutation { createPersonalAccessToken(name: \"y\", scope: READ, ttlDays: 365) { expiresAt } }") |> snd,
             owner("mutation { createPersonalAccessToken(name: \"z\", scope: READ, ttlDays: 0) { expiresAt } }") |> snd,
             owner("mutation { createPersonalAccessToken(name: \"long\", scope: READ, ttlDays: 366) { token } }") |> snd)
        });
        Assert.assertEq(
            expected = (Some(true), None, Some("ttlDays: 1 〜 365 日にしてください"), Some("ttlDays: 1 〜 365 日にしてください")),
            outcome)

    ///
    /// RLS と失効。alice の PAT は bob の一覧に出ず、bob が失効しようとすると notFound。alice が失効すると、その PAT で管理 API を叩くと「失効しています」。
    /// 期限切れ（2 日前に 1 日で発行）の PAT は「期限切れ」、知らない PAT は「見つかりません」。どれもリゾルバの SQL は走らない。
    ///
    @Test
    def testPgPersonalTokenIsPrivateAndRevocable(): Unit \ {IO, Assert} =
        let twoDaysAgo = 1_700_000_000_000i64;
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> ());
            let (admin, account) = schemas(pool);
            let alice = ask(account, bearer("alice", "alice@example.com"));
            let bob = ask(account, bearer("bob", "bob@example.com"));
            let issued = alice("mutation { createPersonalAccessToken(name: \"cli\", scope: WRITE) { id token } }");
            let tokenId = GraphqlTestKit.stringAt(List#{"createPersonalAccessToken", "id"}, issued);
            let token = GraphqlTestKit.stringAt(List#{"createPersonalAccessToken", "token"}, issued);
            let bobSees = bob("{ me { personalAccessTokens { name } } }");
            let withoutId = message -> message |> Option.map(String.replace(src = tokenId, dst = "<id>"));
            let bobRevokes = bob("mutation { revokePersonalAccessToken(id: \"${tokenId}\") }") |> snd |> withoutId;
            let beforeRevoke = ask(admin, Credential.PersonalToken(token))("{ me { email } }");
            let aliceRevokes = alice("mutation { revokePersonalAccessToken(id: \"${tokenId}\") }");
            let afterRevoke = ask(admin, Credential.PersonalToken(token))("{ me { email } }") |> snd;
            let revokedTwice = alice("mutation { revokePersonalAccessToken(id: \"${tokenId}\") }") |> snd |> withoutId;
            let expired = PgTestSupport.mutate(pool, () -> {
                let user = Accounts.resolveUser({ ownerEmail = None }, { issuer = "test", subject = "alice", email = "alice@example.com", name = "alice" });
                Session.runWith(Accounts.actorWithoutProject(user, Login.Interactive), () -> PersonalTokens.issue(pepper(), { name = "old", scope = PatScope.Write, ttlDays = Some(1) }, twoDaysAgo))
            }) |> PgTestSupport.seededOrBug;
            let viaExpired = ask(admin, Credential.PersonalToken(expired#token))("{ me { email } }") |> snd;
            let viaUnknown = ask(admin, Credential.PersonalToken("cmspat_nope"))("{ me { email } }") |> snd;
            (bobSees, bobRevokes, beforeRevoke, fst(aliceRevokes), afterRevoke, revokedTwice, viaExpired, viaUnknown)
        });
        let notFound = Some("personal access token '<id>' が見つかりません");
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "personalAccessTokens" => Value.List(Nil) }) }), None),
                notFound,
                me("alice@example.com"),
                Value.Obj(Map#{ "revokePersonalAccessToken" => Value.Bool(true) }),
                Some("認証に失敗しました: PAT は失効しています"),
                notFound,
                Some("認証に失敗しました: PAT が期限切れです"),
                Some("認証に失敗しました: PAT が見つかりません")),
            outcome)

}
