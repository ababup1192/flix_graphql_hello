///
/// Personal Access Token（PAT）を実 PostgreSQL で見る。Account API で発行し、管理 API を本人の役割で叩け、Account API の me が返り、
/// READ の PAT では書けず、他人の PAT は一覧に出ず失効も notFound（RLS）、失効と期限切れは匿名扱い。
///
mod TestPersonalTokenPg {

    /// 応答の data から文字列（id など）を取る。無ければ空。
    def strIn(path: List[String], response: (Value, Option[String])): String =
        Value.path(path, fst(response)) |> Value.asStr |> Option.getWithDefault("")

    /// 応答の data の一部。
    def dataIn(path: List[String], response: (Value, Option[String])): Value =
        Value.path(path, fst(response))

    def bearer(subject: String, email: String): Credential = Credential.Bearer("test", subject, email, subject)

    /// 管理 API と Account API の両方の Schema。同じプールと依存で組む。
    def schemas(pool: Pool): (Schema, Schema) \ IO =
        let deps = PgTestSupport.deps();
        (AdminSchema.make(deps, AdminRunner.make(pool, deps, ProjectId.default())), AccountSchema.make(deps, AccountRunner.make(pool, deps)))

    def ask(schema: Schema, credential: Credential): String -> (Value, Option[String]) \ IO =
        queryText -> GraphqlTestKit.askWith(schema, Context.withCredential(credential), queryText)

    ///
    /// owner が WRITE と READ の PAT を発行する。
    ///   WRITE の PAT: 管理 API の me は OWNER、createContentType が通る。Account API の me が本人
    ///   READ の PAT: 管理 API の me は VIEWER、createContentType は forbidden。Account API の createOrganization も forbidden
    ///   ttlDays が 366 は invalid
    /// 使った PAT には lastUsedAt が付く。
    ///
    @Test
    def testPgPersonalTokenActsAsUser(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> ());
            let (admin, account) = schemas(pool);
            let owner = ask(account, PgTestSupport.ownerCredential());
            let issued = owner("mutation { createPersonalAccessToken(name: \"cli\", scope: WRITE) { name scope token } }");
            let token = strIn(List#{"createPersonalAccessToken", "token"}, issued);
            let readToken = strIn(List#{"createPersonalAccessToken", "token"}, owner("mutation { createPersonalAccessToken(name: \"ro\", scope: READ, ttlDays: 7) { token } }"));
            let tooLong = owner("mutation { createPersonalAccessToken(name: \"long\", scope: READ, ttlDays: 366) { token } }") |> snd;
            let viaPat = ask(admin, Credential.PersonalToken(token));
            let viaReadPat = ask(admin, Credential.PersonalToken(readToken));
            let accountViaPat = ask(account, Credential.PersonalToken(token));
            let accountViaReadPat = ask(account, Credential.PersonalToken(readToken));
            let me = viaPat("{ me { email roles } }");
            let createdType = viaPat("mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { apiId } }");
            let readMe = viaReadPat("{ me { email roles } }");
            let readCreates = viaReadPat("mutation { createContentType(input: { apiId: \"tags\", name: \"タグ\" }) { apiId } }") |> snd;
            let accountMe = accountViaPat("{ me { email } }");
            let readAccountMe = accountViaReadPat("{ me { email } }");
            let readCreatesOrg = accountViaReadPat("mutation { createOrganization(name: \"Acme\") { id } }") |> snd;
            let listed = owner("{ me { personalAccessTokens { name scope lastUsedAt revokedAt } } }") |> fst |> Value.path(List#{"me", "personalAccessTokens"});
            let used = match listed {
                case Value.List(items) => items |> List.map(item -> (Value.field("name", item), Value.field("scope", item), Value.field("lastUsedAt", item) != Value.Null, Value.field("revokedAt", item)))
                case _                 => Nil
            };
            (String.startsWith(prefix = "cmspat_", token), dataIn(List#{"createPersonalAccessToken", "scope"}, issued), tooLong,
             me, createdType, readMe, readCreates, accountMe, readAccountMe, readCreatesOrg, used)
        });
        Assert.assertEq(
            expected = (
                true, Value.Str("WRITE"), Some("ttlDays: 1 〜 365 日にしてください"),
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "email" => Value.Str("owner@test"), "roles" => Value.List(Value.Str("OWNER") :: Nil) }) }), None),
                (Value.Obj(Map#{ "createContentType" => Value.Obj(Map#{ "apiId" => Value.Str("blogs") }) }), None),
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "email" => Value.Str("owner@test"), "roles" => Value.List(Value.Str("VIEWER") :: Nil) }) }), None),
                Some("この操作（manageTypes）の権限がありません"),
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "email" => Value.Str("owner@test") }) }), None),
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "email" => Value.Str("owner@test") }) }), None),
                Some("この操作（writeEntries）の権限がありません"),
                List#{ (Value.Str("cli"), Value.Str("WRITE"), true, Value.Null), (Value.Str("ro"), Value.Str("READ"), true, Value.Null) }),
            outcome)

    ///
    /// RLS と失効。alice の PAT は bob の一覧に出ず、bob が失効しようとすると notFound。alice が失効すると、その PAT で管理 API を叩いても匿名（me は null）。
    /// 期限切れ（2 日前に 1 日で発行）の PAT も匿名。
    ///
    @Test
    def testPgPersonalTokenIsPrivateAndRevocable(): Unit \ {IO, Assert} =
        let pepper = { pepperId = "test", secret = "test-pepper" };
        let twoDaysAgo = 1_700_000_000_000i64;
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> ());
            let (admin, account) = schemas(pool);
            let alice = ask(account, bearer("alice", "alice@example.com"));
            let bob = ask(account, bearer("bob", "bob@example.com"));
            let issued = alice("mutation { createPersonalAccessToken(name: \"cli\", scope: WRITE) { id token } }");
            let tokenId = strIn(List#{"createPersonalAccessToken", "id"}, issued);
            let token = strIn(List#{"createPersonalAccessToken", "token"}, issued);
            let bobSees = bob("{ me { personalAccessTokens { name } } }");
            let notFound = Some("personal access token '${tokenId}' が見つかりません");
            let bobRevokes = bob("mutation { revokePersonalAccessToken(id: \"${tokenId}\") }") |> snd;
            let beforeRevoke = ask(admin, Credential.PersonalToken(token))("{ me { email } }");
            let aliceRevokes = alice("mutation { revokePersonalAccessToken(id: \"${tokenId}\") }");
            let afterRevoke = ask(admin, Credential.PersonalToken(token))("{ me { email } }");
            let revokedTwice = alice("mutation { revokePersonalAccessToken(id: \"${tokenId}\") }") |> snd;
            let expired = PgTestSupport.mutate(pool, () -> {
                let user = Accounts.resolveUser({ ownerEmail = None }, { issuer = "test", subject = "alice", email = "alice@example.com", name = "alice" });
                Session.runWith(Accounts.actorWithoutProject(user), () -> PersonalTokens.issue(pepper, { name = "old", scope = PatScope.Write, ttlDays = Some(1) }, twoDaysAgo))
            }) |> PgTestSupport.seededOrBug;
            let viaExpired = ask(admin, Credential.PersonalToken(expired#token))("{ me { email } }");
            (bobSees, bobRevokes == notFound, beforeRevoke, fst(aliceRevokes), afterRevoke, revokedTwice == notFound, viaExpired)
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "personalAccessTokens" => Value.List(Nil) }) }), None),
                true,
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{ "email" => Value.Str("alice@example.com") }) }), None),
                Value.Obj(Map#{ "revokePersonalAccessToken" => Value.Bool(true) }),
                (Value.Obj(Map#{ "me" => Value.Null }), None),
                true,
                (Value.Obj(Map#{ "me" => Value.Null }), None)),
            outcome)

}
