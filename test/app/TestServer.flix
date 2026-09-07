///
/// Server: HTTP リクエストを Graphql effect に橋渡しするルーティング。
/// エンジンは使わず、GraphqlFake の偽ハンドラで確かめる。ボディは Value に読み戻して比べる。
///
///
/// CORS 無しの設定で、DB が届く前提の Server.handle。
///
mod TestServer {

    def handle(request: HttpRequest): HttpResponse \ Graphql =
        HealthFake.runWithOk(() -> Server.handle(Server.defaultConfig(), Credential.Missing, request))

    ///
    /// POST /graphql に JSON ボディを載せたリクエスト。
    ///
    def postGraphql(body: String): HttpRequest =
        { method = "POST", path = "/graphql", headers = ("Content-Type", "application/json; charset=utf-8") :: Nil, body = body }

    ///
    /// 管理画面のオリジンから来たリクエスト。
    ///
    def fromAdmin(method: String, path: String): HttpRequest =
        { method = method, path = path, headers = ("origin", "https://admin.example.com") :: Nil, body = "{\"query\": \"{ x }\"}" }

    ///
    /// 管理画面のオリジンだけ許す設定。
    ///
    def adminConfig(): ServerConfig = { cors = { allowedOrigins = "https://admin.example.com" :: Nil }, graphqlPath = "/graphql", version = "dev" }

    ///
    /// runWithEcho が data に入れて返す形。variables が無いリクエストは空の Obj、operationName が無ければ Null。
    ///
    def echoed(queryText: String): Value =
        Value.Obj(Map#{ "query" => Value.Str(queryText), "variables" => Value.Obj(Map.empty()), "operationName" => Value.Null })

    // ---- POST /graphql の正常系 ----

    /// POST /graphql は JSON ボディの query を取り出して実行し、data を JSON で返す。
    @Test
    def testServerPostGraphql(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() -> handle(postGraphql("{\"query\": \"{ add(a: 1, b: 2) }\"}")));
        Assert.assertEq(
            expected = (200, Ok(Value.Obj(Map#{ "data" => echoed("{ add(a: 1, b: 2) }") }))),
            (response#status, JsonValue.parse(response#body)))

    /// ボディの variables と operationName はそのまま Graphql effect に渡る。
    @Test
    def testServerVariablesAndOperationNamePassThrough(): Unit \ Assert =
        let expectedData = Value.Obj(Map#{
            "query"         => Value.Str("query Q($a: Int!) { add(a: $a, b: 2) }"),
            "variables"     => Value.Obj(Map#{ "a" => Value.Int(1), "tag" => Value.Str("x") }),
            "operationName" => Value.Str("Q") });
        Assert.assertEq(
            expected = Ok(Value.Obj(Map#{ "data" => expectedData })),
            GraphqlFake.runWithEcho(() -> handle(postGraphql(
                "{\"query\": \"query Q($a: Int!) { add(a: $a, b: 2) }\", \"variables\": {\"a\": 1, \"tag\": \"x\"}, \"operationName\": \"Q\"}")))#body
                |> JsonValue.parse)

    /// 実行結果に errors があれば errors としてそのまま返す。
    @Test
    def testServerErrors(): Unit \ Assert =
        let error = Value.Obj(Map#{ "message" => Value.Str("boom") });
        Assert.assertEq(
            expected = Ok(Value.Obj(Map#{ "data" => Value.Null, "errors" => Value.List(error :: Nil) })),
            GraphqlFake.runWithFixedResponse({ data = Value.Null, errors = error :: Nil },
                () -> handle(postGraphql("{\"query\": \"{ x }\"}")))#body |> JsonValue.parse)

    /// エラーオブジェクトの message 以外のフィールド（path など）も削らずにボディへ通す。
    @Test
    def testServerErrorPathPassesThrough(): Unit \ Assert =
        let error = Value.Obj(Map#{ "message" => Value.Str("boom"), "path" => Value.List(Value.Str("x") :: Nil) });
        Assert.assertEq(
            expected = Ok(Value.Obj(Map#{ "data" => Value.Null, "errors" => Value.List(error :: Nil) })),
            GraphqlFake.runWithFixedResponse({ data = Value.Null, errors = error :: Nil },
                () -> handle(postGraphql("{\"query\": \"{ x }\"}")))#body |> JsonValue.parse)

    /// errors が空なら errors キー自体を出さない。
    @Test
    def testServerNoErrorsKey(): Unit \ Assert =
        Assert.assertEq(
            expected = Ok(Value.Obj(Map#{ "data" => Value.Int(1) })),
            GraphqlFake.runWithFixedResponse({ data = Value.Int(1), errors = Nil },
                () -> handle(postGraphql("{\"query\": \"{ x }\"}")))#body |> JsonValue.parse)

    // ---- ボディの検証 ----

    /// 壊れた JSON は 400。query が無いのも 400。
    @Test
    def testServerBadBody(): Unit \ Assert =
        Assert.assertEq(expected = (400, 400),
            GraphqlFake.runWithEcho(() -> (
                handle(postGraphql("{"))#status,
                handle(postGraphql("{\"q\": 1}"))#status)))

    /// variables がオブジェクトでなければ 400。
    @Test
    def testServerVariablesNotObject(): Unit \ Assert =
        Assert.assertEq(expected = 400,
            GraphqlFake.runWithEcho(() -> handle(postGraphql("{\"query\": \"{ x }\", \"variables\": [1]}"))#status))

    // ---- ルーティング ----

    /// /graphql への GET は 405、それ以外のパスは 404。
    @Test
    def testServerRouting(): Unit \ Assert =
        Assert.assertEq(expected = (405, 404),
            GraphqlFake.runWithEcho(() -> (
                handle({ method = "GET", path = "/graphql", headers = Nil, body = "" })#status,
                handle({ method = "POST", path = "/", headers = Nil, body = "" })#status)))

    /// 405 のレスポンスは Allow: POST ヘッダを持つ。
    @Test
    def testServerMethodNotAllowedHasAllowHeader(): Unit \ Assert =
        Assert.assertEq(expected = ("Allow", "POST") :: Nil,
            GraphqlFake.runWithEcho(() -> handle({ method = "GET", path = "/graphql", headers = Nil, body = "" }))#headers)

    /// ルーティングのエラーも errors[].message の形の JSON ボディで返す。
    @Test
    def testServerErrorBodyShape(): Unit \ Assert =
        Assert.assertEq(
            expected = Ok(Value.Obj(Map#{ "data" => Value.Null, "errors" => Value.List(Value.Obj(Map#{ "message" => Value.Str("not found") }) :: Nil) })),
            GraphqlFake.runWithEcho(() -> handle({ method = "POST", path = "/", headers = Nil, body = "" }))#body |> JsonValue.parse)

    // ---- GET /health ----

    /// Content-Type が application/json でない POST は 415（form の text/plain で届く CSRF を preflight に倒す）。無くても 415。
    @Test
    def testServerRejectsNonJsonContentType(): Unit \ Assert =
        let statusOf = request -> GraphqlFake.runWithEcho(() -> handle(request))#status;
        Assert.assertEq(expected = (415, 415, 200),
            (statusOf({ method = "POST", path = "/graphql", headers = ("Content-Type", "text/plain") :: Nil, body = "{\"query\":\"{ x }\"}" }),
             statusOf({ method = "POST", path = "/graphql", headers = Nil, body = "{\"query\":\"{ x }\"}" }),
             statusOf({ method = "POST", path = "/graphql", headers = ("content-type", "APPLICATION/JSON") :: Nil, body = "{\"query\":\"{ x }\"}" })))

    /// DB に届けば 200 と {"status": "ok"}。クエリ文字列が付いていても同じ。
    @Test
    def testServerHealthOk(): Unit \ Assert =
        Assert.assertEq(expected = ((200, Ok(Value.Obj(Map#{ "status" => Value.Str("ok"), "version" => Value.Str("dev") }))), 200),
            GraphqlFake.runWithEcho(() -> HealthFake.runWithOk(() -> {
                let response = Server.handle(Server.defaultConfig(), Credential.Missing, { method = "GET", path = "/health", headers = Nil, body = "" });
                ((response#status, JsonValue.parse(response#body)),
                 Server.handle(Server.defaultConfig(), Credential.Missing, { method = "GET", path = "/health?probe=1", headers = Nil, body = "" })#status)
            })))

    /// DB に届かなければ 503 で、理由を db に入れる。
    @Test
    def testServerHealthFailure(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() -> HealthFake.runWithFailure("connection refused", () ->
            Server.handle(Server.defaultConfig(), Credential.Missing, { method = "GET", path = "/health", headers = Nil, body = "" })));
        Assert.assertEq(expected = (503, Ok(Value.Obj(Map#{ "status" => Value.Str("error"), "version" => Value.Str("dev"), "db" => Value.Str("connection refused") }))),
            (response#status, JsonValue.parse(response#body)))

    /// /health への POST は 405 で Allow: GET。
    @Test
    def testServerHealthPostNotAllowed(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() -> handle({ method = "POST", path = "/health", headers = Nil, body = "" }));
        Assert.assertEq(expected = (405, ("Allow", "GET") :: Nil), (response#status, response#headers))

    // ---- CORS ----

    /// 許したオリジンからの POST /graphql には Allow-Origin と Vary が付く。
    @Test
    def testServerCorsHeadersOnGraphql(): Unit \ Assert =
        Assert.assertEq(expected = ("Access-Control-Allow-Origin", "https://admin.example.com") :: ("Vary", "Origin") :: Nil,
            GraphqlFake.runWithEcho(() -> HealthFake.runWithOk(() -> Server.handle(adminConfig(), Credential.Missing, fromAdmin("POST", "/graphql"))))#headers)

    /// preflight は 204 で、Graphql も Health も呼ばずに返る（偽ハンドラの応答がボディに現れない）。
    /// Allow-Origin は 1 回だけ付く（preflight と withHeaders で二重にならない）。
    @Test
    def testServerPreflight(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() -> HealthFake.runWithOk(() -> Server.handle(adminConfig(), Credential.Missing, fromAdmin("OPTIONS", "/graphql"))));
        Assert.assertEq(expected = (204, "", true, 1),
            (response#status, response#body,
             List.memberOf(("Access-Control-Allow-Methods", "GET, POST, OPTIONS"), response#headers),
             response#headers |> List.count(match (name, _) -> name == "Access-Control-Allow-Origin")))

    /// CORS 無しの設定では、Origin が付いていてもヘッダを足さない。
    @Test
    def testServerNoCorsByDefault(): Unit \ Assert =
        Assert.assertEq(expected = Nil,
            GraphqlFake.runWithEcho(() -> handle(fromAdmin("POST", "/graphql")))#headers)

    /// エンジンが要るのは POST でそのパス宛の時だけ。preflight / GET / 他のパスは要らない。
    @Test
    def testServerNeedsGraphqlEngineOnlyForPost(): Unit \ Assert =
        Assert.assertEq(expected = (true, true, false, false, false),
            (Server.needsGraphqlEngine(adminConfig(), fromAdmin("POST", "/graphql")),
             Server.needsGraphqlEngine(adminConfig(), fromAdmin("POST", "/graphql?x=1")),
             Server.needsGraphqlEngine(adminConfig(), fromAdmin("OPTIONS", "/graphql")),
             Server.needsGraphqlEngine(adminConfig(), fromAdmin("GET", "/graphql")),
             Server.needsGraphqlEngine(adminConfig(), fromAdmin("POST", "/health"))))

    /// OPTIONS は GraphQL のパスと /health だけ 204 で、無いパスは 404。
    @Test
    def testServerPreflightOnlyOnKnownPaths(): Unit \ Assert =
        let statuses = List#{"/graphql", "/health", "/nope"} |> List.map(path ->
            GraphqlFake.runWithEcho(() -> HealthFake.runWithOk(() -> Server.handle(adminConfig(), Credential.Missing, fromAdmin("OPTIONS", path))))#status);
        Assert.assertEq(expected = List#{204, 204, 404}, statuses)

    /// パスの先頭の /p/{slug} を切り出す。無ければそのまま。slug が空なら切り出さない。
    @Test
    def testServerSplitProject(): Unit \ Assert =
        Assert.assertEq(expected = ((Some("shop"), "/graphql"), (Some("shop"), "/admin/graphql?x=1"), (None, "/graphql"), (None, "/p/"), (None, "/health")),
            (Server.splitProject("/p/shop/graphql"), Server.splitProject("/p/shop/admin/graphql?x=1"), Server.splitProject("/graphql"), Server.splitProject("/p/"), Server.splitProject("/health")))

    /// Host の先頭ラベルを slug にする。ポートは無視、base が違えば None、/p/ があればそちらが勝つ、base 未設定なら Host は見ない。
    @Test
    def testServerSlugFromHost(): Unit \ Assert =
        let base = Some("example.com");
        let hostOf = host -> ("Host", host) :: Nil;
        Assert.assertEq(
            expected = (Some("consumer"), Some("consumer"), None, None, None, (Some("shop"), "/graphql"), (Some("business"), "/admin/graphql"), (None, "/graphql")),
            (Server.slugFromHost(base, hostOf("consumer.example.com")),
             Server.slugFromHost(base, hostOf("Consumer.Example.com:8080")),
             Server.slugFromHost(base, hostOf("example.com")),
             Server.slugFromHost(base, hostOf("consumer.other.com")),
             Server.slugFromHost(None, hostOf("consumer.example.com")),
             Server.projectOf(base, { method = "GET", path = "/p/shop/graphql", headers = hostOf("consumer.example.com"), body = "" }),
             Server.projectOf(base, { method = "GET", path = "/admin/graphql", headers = hostOf("business.example.com"), body = "" }),
             Server.projectOf(None, { method = "GET", path = "/graphql", headers = hostOf("business.example.com"), body = "" })))

}
