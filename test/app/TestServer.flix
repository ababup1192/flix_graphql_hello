///
/// Server: HTTP リクエストを Graphql effect に橋渡しするルーティング。
/// エンジンは使わず、GraphqlFake の偽ハンドラで確かめる。ボディは Value に読み戻して比べる。
///
///
/// CORS 無しの設定で、DB が届く前提の Server.handle。
///
mod TestServer {

    def handle(request: HttpRequest): HttpResponse \ Graphql =
        Server.handle(Server.defaultConfig(), HealthFake.ok(), Credential.Missing, request)

    ///
    /// POST /graphql に JSON ボディを載せたリクエスト。
    ///
    def postGraphql(body: String): HttpRequest =
        { version = "HTTP/1.1", method = "POST", path = "/graphql", headers = ("Content-Type", "application/json; charset=utf-8") :: Nil, body = body }

    ///
    /// 管理画面のオリジンから来たリクエスト。
    ///
    def fromAdmin(method: String, path: String): HttpRequest =
        { version = "HTTP/1.1", method = method, path = path, headers = ("origin", "https://admin.example.com") :: Nil, body = "{\"query\": \"{ x }\"}" }

    ///
    /// 管理画面のオリジンだけ許す設定。
    ///
    def adminConfig(): ServerConfig = { cors = { allowedOrigins = "https://admin.example.com" :: Nil }, version = "dev", jobsToken = None, cacheMaxAge = None }

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

    /// /graphql への PUT は 405、それ以外のパスは 404。
    @Test
    def testServerRouting(): Unit \ Assert =
        Assert.assertEq(expected = (405, 404),
            GraphqlFake.runWithEcho(() -> (
                handle({ version = "HTTP/1.1", method = "PUT", path = "/graphql", headers = Nil, body = "" })#status,
                handle({ version = "HTTP/1.1", method = "POST", path = "/", headers = Nil, body = "" })#status)))

    /// 405 のレスポンスは Allow ヘッダを持つ。
    @Test
    def testServerMethodNotAllowedHasAllowHeader(): Unit \ Assert =
        Assert.assertEq(expected = ("Allow", "POST, GET") :: Nil,
            GraphqlFake.runWithEcho(() -> handle({ version = "HTTP/1.1", method = "PUT", path = "/graphql", headers = Nil, body = "" }))#headers)

    // ---- GET /graphql ----

    /// GET は query パラメータ（パーセント符号化）を実行し、variables と operationName も受ける。query が無ければ 400、mutation なら 405。
    @Test
    def testServerGetQuery(): Unit \ Assert =
        let get = path -> GraphqlFake.runWithEcho(() -> handle({ version = "HTTP/1.1", method = "GET", path = path, headers = Nil, body = "" }));
        let echoed = get("/graphql?query=%7B%20blogs%20%7B%20id%20%7D%20%7D&variables=%7B%22first%22%3A2%7D&operationName=Q");
        Assert.assertEq(
            expected = (200, Ok(Value.Obj(Map#{ "query" => Value.Str("{ blogs { id } }"), "variables" => Value.Obj(Map#{ "first" => Value.Int(2) }), "operationName" => Value.Str("Q") })), 400, 405),
            (echoed#status, echoed#body |> JsonValue.parse |> Result.map(Value.field("data")),
             get("/graphql")#status,
             get("/graphql?query=mutation%20%7B%20x%20%7D")#status))

    /// 身元無しで cacheMaxAge があれば public のキャッシュ、鍵付きや cacheMaxAge 無しなら no-store。Vary は常に付く。
    @Test
    def testServerGetCacheControl(): Unit \ Assert =
        let cached = { cacheMaxAge = Some(60) | Server.defaultConfig() };
        let headerOf = (config, credential) -> GraphqlFake.runWithEcho(() ->
            Server.handle(config, HealthFake.ok(), credential, { version = "HTTP/1.1", method = "GET", path = "/graphql?query=%7B%20x%20%7D", headers = Nil, body = "" }))#headers
            |> Http.findHeader("Cache-Control");
        Assert.assertEq(
            expected = (Some("public, max-age=60, s-maxage=60, stale-while-revalidate=60"), Some("private, no-store"), Some("private, no-store")),
            (headerOf(cached, Credential.Missing), headerOf(cached, Credential.ApiKey("cms_x")), headerOf(Server.defaultConfig(), Credential.Missing)))

    /// 読むだけかの判定: 無名・query・fragment 付きは読む、mutation / subscription は書く。文字列とコメントの中の語は見ない。
    @Test
    def testServerIsReadOnly(): Unit \ Assert =
        Assert.assertEq(expected = (true, true, true, false, false, true),
            (Server.isReadOnly("{ blogs { id } }"),
             Server.isReadOnly("query Q($f: Int) { blogs(first: $f) { id } }"),
             Server.isReadOnly("fragment F on Blog { id } query { blogs { ...F } }"),
             Server.isReadOnly("mutation { publishEntry(id: \"e1\") { id } }"),
             Server.isReadOnly("query { a } mutation { b }"),
             Server.isReadOnly("# mutation\n{ blogs(where: { title_eq: \"mutation\" }) { id } }")))

    /// クエリ文字列の解読: + と %XX（UTF-8 の多バイトも）、値の無い名前、壊れた % はそのまま。
    @Test
    def testHttpParseQueryString(): Unit \ Assert =
        Assert.assertEq(
            expected = Map#{ "q" => "a b", "name" => "日本", "flag" => "", "bad" => "%zz", "eq" => "a=b" },
            Http.parseQueryString("/graphql?q=a+b&name=%E6%97%A5%E6%9C%AC&flag&bad=%zz&eq=a%3Db"))

    /// ルーティングのエラーも errors[].message の形の JSON ボディで返す。
    @Test
    def testServerErrorBodyShape(): Unit \ Assert =
        Assert.assertEq(
            expected = Ok(Value.Obj(Map#{ "data" => Value.Null, "errors" => Value.List(Value.Obj(Map#{ "message" => Value.Str("not found") }) :: Nil) })),
            GraphqlFake.runWithEcho(() -> handle({ version = "HTTP/1.1", method = "POST", path = "/", headers = Nil, body = "" }))#body |> JsonValue.parse)

    // ---- GET /health ----

    /// Content-Type が application/json でない POST は 415（form の text/plain で届く CSRF を preflight に倒す）。無くても 415。
    @Test
    def testServerRejectsNonJsonContentType(): Unit \ Assert =
        let statusOf = request -> GraphqlFake.runWithEcho(() -> handle(request))#status;
        Assert.assertEq(expected = (415, 415, 200),
            (statusOf({ version = "HTTP/1.1", method = "POST", path = "/graphql", headers = ("Content-Type", "text/plain") :: Nil, body = "{\"query\":\"{ x }\"}" }),
             statusOf({ version = "HTTP/1.1", method = "POST", path = "/graphql", headers = Nil, body = "{\"query\":\"{ x }\"}" }),
             statusOf({ version = "HTTP/1.1", method = "POST", path = "/graphql", headers = ("content-type", "APPLICATION/JSON") :: Nil, body = "{\"query\":\"{ x }\"}" })))

    /// DB に届けば 200 と {"status": "ok"}。クエリ文字列が付いていても同じ。
    @Test
    def testServerHealthOk(): Unit \ Assert =
        Assert.assertEq(expected = ((200, Ok(Value.Obj(Map#{ "status" => Value.Str("ok"), "version" => Value.Str("dev"), "jobs" => Value.Obj(Map#{ "lastTickAt" => Value.Null, "pendingSchedules" => Value.Int(0), "failedSchedules" => Value.Int(0), "pendingDeliveries" => Value.Int(0), "failedDeliveries" => Value.Int(0) }), "connections" => Value.Obj(Map#{ "active" => Value.Int(1), "max" => Value.Int(256) }) }))), 200),
            GraphqlFake.runWithEcho(() -> {
                let response = handle({ version = "HTTP/1.1", method = "GET", path = "/health", headers = Nil, body = "" });
                ((response#status, JsonValue.parse(response#body)),
                 handle({ version = "HTTP/1.1", method = "GET", path = "/health?probe=1", headers = Nil, body = "" })#status)
            }))

    /// DB に届かなければ 503 で、理由を db に入れる。
    @Test
    def testServerHealthFailure(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() ->
            Server.handle(Server.defaultConfig(), HealthFake.failing("connection refused"), Credential.Missing, { version = "HTTP/1.1", method = "GET", path = "/health", headers = Nil, body = "" }));
        Assert.assertEq(expected = (503, Ok(Value.Obj(Map#{ "status" => Value.Str("error"), "version" => Value.Str("dev"), "db" => Value.Str("connection refused"), "jobs" => Value.Obj(Map#{ "lastTickAt" => Value.Null, "pendingSchedules" => Value.Int(0), "failedSchedules" => Value.Int(0), "pendingDeliveries" => Value.Int(0), "failedDeliveries" => Value.Int(0) }), "connections" => Value.Obj(Map#{ "active" => Value.Int(1), "max" => Value.Int(256) }) }))),
            (response#status, JsonValue.parse(response#body)))

    /// /health への POST は 405 で Allow: GET。
    @Test
    def testServerHealthPostNotAllowed(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() -> handle({ version = "HTTP/1.1", method = "POST", path = "/health", headers = Nil, body = "" }));
        Assert.assertEq(expected = (405, ("Allow", "GET") :: Nil), (response#status, response#headers))

    // ---- CORS ----

    /// 許したオリジンからの POST /graphql には Allow-Origin と Vary が付く。
    @Test
    def testServerCorsHeadersOnGraphql(): Unit \ Assert =
        Assert.assertEq(expected = ("Access-Control-Allow-Origin", "https://admin.example.com") :: ("Vary", "Origin") :: Nil,
            GraphqlFake.runWithEcho(() -> Server.handle(adminConfig(), HealthFake.ok(), Credential.Missing, fromAdmin("POST", "/graphql")))#headers)

    /// preflight は 204 で、Graphql を呼ばずに返る（偽ハンドラの応答がボディに現れない）。
    /// Allow-Origin は 1 回だけ付く（preflight と withHeaders で二重にならない）。
    @Test
    def testServerPreflight(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() -> Server.handle(adminConfig(), HealthFake.ok(), Credential.Missing, fromAdmin("OPTIONS", "/graphql")));
        Assert.assertEq(expected = (204, "", true, 1),
            (response#status, response#body,
             List.memberOf(("Access-Control-Allow-Methods", "POST, GET, OPTIONS"), response#headers),
             response#headers |> List.count(match (name, _) -> name == "Access-Control-Allow-Origin")))

    /// CORS 無しの設定では、Origin が付いていてもヘッダを足さない。
    @Test
    def testServerNoCorsByDefault(): Unit \ Assert =
        Assert.assertEq(expected = Nil,
            GraphqlFake.runWithEcho(() -> handle(fromAdmin("POST", "/graphql")))#headers)

    /// OPTIONS は表にあるパス（/p/ 付きも）だけ 204 で、無いパスは 404。404 にも CORS ヘッダが付く。
    @Test
    def testServerPreflightOnlyOnKnownPaths(): Unit \ Assert =
        let responses = List#{"/graphql", "/health", "/p/shop/admin/graphql", "/nope"} |> List.map(path ->
            GraphqlFake.runWithEcho(() -> Server.handle(adminConfig(), HealthFake.ok(), Credential.Missing, fromAdmin("OPTIONS", path))));
        Assert.assertEq(expected = (List#{204, 204, 204, 404}, List#{true, true, true, true}),
            (responses |> List.map(response -> response#status),
             responses |> List.map(response -> List.memberOf(("Access-Control-Allow-Origin", "https://admin.example.com"), response#headers))))

    // ---- ルート表 ----

    /// 表の全行（/p/{projectSlug} 付きの複製込み）。行を足したらここにも足す。
    @Test
    def testServerRoutesDescribe(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                "POST /graphql", "GET /graphql", "POST /admin/graphql", "GET /admin/graphql", "POST /account/graphql", "GET /health", "POST /jobs/tick",
                "POST /p/{projectSlug}/graphql", "GET /p/{projectSlug}/graphql", "POST /p/{projectSlug}/admin/graphql", "GET /p/{projectSlug}/admin/graphql",
                "GET /p/{projectSlug}/health", "POST /p/{projectSlug}/jobs/tick" },
            Server.routes(Server.defaultConfig(), HealthFake.ok()) |> Router.withProjectPrefix |> Router.describeAll)

    /// /p/{プロジェクト slug} 付きのパスも同じ handler に届く。空のプロジェクト slug（/p//graphql）や /p/ だけは 404。
    @Test
    def testServerProjectPrefixedPaths(): Unit \ Assert =
        let statusOf = path -> GraphqlFake.runWithEcho(() -> handle({ version = "HTTP/1.1", method = "GET", path = path, headers = Nil, body = "" }))#status;
        Assert.assertEq(expected = (200, 200, 404, 404, 404),
            (statusOf("/p/shop/health"), statusOf("/p/shop/graphql?query=%7B%20x%20%7D"), statusOf("/p//graphql"), statusOf("/p/"), statusOf("/p/shop/account/graphql")))

    /// Host の先頭ラベルをプロジェクト slug にする。ポートは無視、base が違えば None、base 未設定なら Host は見ない。
    @Test
    def testServerSlugFromHost(): Unit \ Assert =
        let base = Some("example.com");
        let hostOf = host -> ("Host", host) :: Nil;
        Assert.assertEq(
            expected = (Some("consumer"), Some("consumer"), None, None, None),
            (Server.projectSlugFromHost(base, hostOf("consumer.example.com")),
             Server.projectSlugFromHost(base, hostOf("Consumer.Example.com:8080")),
             Server.projectSlugFromHost(base, hostOf("example.com")),
             Server.projectSlugFromHost(base, hostOf("consumer.other.com")),
             Server.projectSlugFromHost(None, hostOf("consumer.example.com"))))

    /// projectSlug の params: /p/ があればそちらが勝ち、無ければ Host から、base 未設定なら空。
    @Test
    def testServerProjectSlugParam(): Unit \ Assert =
        let table = Server.routes(Server.defaultConfig(), HealthFake.ok()) |> Router.withProjectPrefix;
        let slugOf = (baseDomain, path, host) ->
            Server.wrapProjectFromHost(baseDomain, Server.dispatch(table, (_, routeRequest) ->
                { status = 200, headers = Nil, body = Map.get(Router.projectSlugParam(), routeRequest#params) |> Option.getWithDefault("") }))
                ({ request = { version = "HTTP/1.1", method = "GET", path = path, headers = ("Host", host) :: Nil, body = "" }, params = Map.empty(), credential = Credential.Missing })#body;
        Assert.assertEq(expected = ("shop", "business", ""),
            (slugOf(Some("example.com"), "/p/shop/graphql", "consumer.example.com"),
             slugOf(Some("example.com"), "/admin/graphql", "business.example.com"),
             slugOf(None, "/graphql", "business.example.com")))


    /// POST /jobs/tick は、トークンが設定されていなければ 404、違えば 403、合えば 200 で失敗の一覧（空）を返す。
    @Test
    def testServerJobsTick(): Unit \ Assert =
        let request = token -> { version = "HTTP/1.1", method = "POST", path = "/jobs/tick", headers = ("X-Jobs-Token", token) :: Nil, body = "" };
        let closed = Server.defaultConfig();
        let opened = { jobsToken = Some("secret") | Server.defaultConfig() };
        let call = (config, token) -> GraphqlFake.runWithEcho(() -> Server.handle(config, HealthFake.ok(), Credential.Missing, request(token)));
        Assert.assertEq(expected = (404, 403, 200, "{\"failures\":[],\"status\":\"ok\"}"),
            (call(closed, "secret")#status, call(opened, "wrong")#status, call(opened, "secret")#status, call(opened, "secret")#body))

}
