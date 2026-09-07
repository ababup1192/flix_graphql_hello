///
/// HTTP のリクエスト（ヘッダ付き）を Server.handle から本物のエンジンと実 PostgreSQL に通す。
/// `Authorization: Bearer cmspat_...`（PAT）と `X-Api-Key`（WRITE の鍵）で管理 API の mutation が通る事を、ヘッダの読み取りから確かめる。
///
/// WhyNot: ソケットを開かないのは、HttpServer.listen が戻らず止める口も無いので、テストの region が終わらないため。
/// ヘッダ → Credential（Credentials）→ Runner → ユースケースの道は同じ。
///
mod TestServerAuthPg {

    /// ログインの JWT は無い（検証は必ず落ちる）設定でヘッダから身元を組む。
    def credentialOf(request: HttpRequest): Credential =
        Credentials.ofHeaders("Authorization", _ -> Err("JWT は無し"), request#headers)

    /// POST /admin/graphql。
    def post(headers: List[(String, String)], queryText: String): HttpRequest =
        { version = "HTTP/1.1", method = "POST", path = "/admin/graphql", headers = ("Content-Type", "application/json") :: headers,
          body = JsonValue.toJsonString(Value.Obj(Map#{ "query" => Value.Str(queryText) })) }

    /// 管理 API のエンジンでリクエストを処理し、(status, body の JSON) を返す。
    def handle(engine: Graphql.Engine, request: HttpRequest): (Int32, Value) \ IO =
        let config = { cors = Cors.none(), version = "test", jobsToken = None, cacheMaxAge = None };
        let response = Graphql.runWithEngine(engine, () -> Server.handle(config, HealthFake.ok(), credentialOf(request), request));
        (response#status, JsonValue.parse(response#body) |> Result.getWithDefault(Value.Null))

    ///
    /// owner が PAT と WRITE / EDITOR の鍵を発行し、HTTP のヘッダで
    ///   Authorization: Bearer cmspat_... → createContentType が通る
    ///   authorization: bearer cmspat_... → 小文字の scheme でも me が本人
    ///   X-Api-Key: cms_...              → createEntry が通る
    ///   ヘッダ無し                       → forbidden
    ///   壊れた Bearer（JWT でない）      → 認証に失敗
    ///
    @Test
    def testPgServerAcceptsPatAndWriteApiKey(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> ());
            let deps = PgTestSupport.deps();
            let admin = AdminSchema.make(deps, AdminRunner.make(pool, deps, ProjectId.default()));
            let account = AccountSchema.make(deps, AccountRunner.make(pool, deps));
            let owner = PgTestSupport.askOwner(admin);
            let accountOwner = PgTestSupport.askAs(account, PgTestSupport.ownerCredential());
            let token = GraphqlTestKit.stringAt(List#{"createPersonalAccessToken", "token"}, accountOwner("mutation { createPersonalAccessToken(name: \"cli\", scope: WRITE) { token } }"));
            let key = GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, owner("mutation { createApiKey(name: \"ci\", scope: WRITE, role: EDITOR) { key } }"));
            let engine = GraphqlTestKit.engineOrBug(admin);
            let viaPat = handle(engine, post(("Authorization", "Bearer ${token}") :: Nil, "mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id apiId } }"));
            let typeId = Value.path(List#{"data", "createContentType", "id"}, snd(viaPat)) |> Value.asStr |> Option.getWithDefault("");
            let viaLowercase = handle(engine, post(("authorization", "bearer ${token}") :: Nil, "{ me { email } }"));
            let viaKey = handle(engine, post(("X-Api-Key", key) :: Nil, "mutation { createEntry(typeId: \"${typeId}\", fields: {}) { stage } }"));
            let anonymous = handle(engine, post(Nil, "mutation { createContentType(input: { apiId: \"tags\", name: \"x\" }) { id } }"));
            let badBearer = handle(engine, post(("Authorization", "Bearer not-a-jwt") :: Nil, "{ me { email } }"));
            (fst(viaPat), Value.path(List#{"data", "createContentType", "apiId"}, snd(viaPat)),
             Value.path(List#{"data", "me", "email"}, snd(viaLowercase)),
             fst(viaKey), Value.path(List#{"data", "createEntry", "stage"}, snd(viaKey)),
             firstErrorMessage(snd(anonymous)),
             firstErrorMessage(snd(badBearer)))
        });
        Assert.assertEq(
            expected = (
                200, Value.Str("blogs"),
                Value.Str("owner@test"),
                200, Value.Str("DRAFT"),
                Some("この操作（manageTypes）の権限がありません"),
                Some("認証に失敗しました: JWT は無し")),
            outcome)

    /// HTTP の応答の body の errors[0].message。errors が無ければ None。
    def firstErrorMessage(body: Value): Option[String] = match Value.field("errors", body) {
        case Value.List(first :: _) => Value.field("message", first) |> Value.asStr
        case _                      => None
    }

}
