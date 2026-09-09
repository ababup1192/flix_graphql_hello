///
/// Server: HTTP リクエストを Graphql effect に橋渡しするルーティング。
/// エンジンは使わず、GraphqlFake の偽ハンドラで確かめる。ボディは Value に読み戻して比べる。
///
///
/// CORS 無しの設定で、DB が届く前提の Server.handle。
///
mod TestServer {

    def handle(request: HttpRequest): HttpResponse \ Graphql =
        serve(Server.defaultConfig(), HealthFake.ok(), Credential.Missing, request)

    ///
    /// Server.handle をログ無し・属性無し・匿名で呼ぶ（Route は Log と Observe を持つ）。
    ///
    def serve(config: ServerConfig, health: Health[{}], credential: Credential, request: HttpRequest): HttpResponse \ Graphql =
        ServerTestKit.quietly(() -> Server.handle(config, health, credential, Ok(Authentication.anonymous()), request))

    ///
    /// Server.handle を呼び、(ステータス, リクエストの行に積んだ error.code) を返す。
    ///
    def rejectionOf(config: ServerConfig, request: HttpRequest): (Int32, Option[String]) \ Graphql =
        let (response, fields) = fst(Log.runWithList(() -> Observe.collect(() -> Server.handle(config, HealthFake.ok(), Credential.Missing, Ok(Authentication.anonymous()), request))));
        (response#status, Map.get("error.code", fields) |> Option.flatMap(Value.asStr))

    /// メソッドとパスとヘッダだけのリクエスト。
    def requestOf(method: String, path: String, headers: List[(String, String)], body: String): HttpRequest =
        { version = "HTTP/1.1", method = method, path = path, headers = headers, body = body }

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
    def adminConfig(): ServerConfig = { cors = { allowedOrigins = "https://admin.example.com" :: Nil } | Server.defaultConfig() }

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

    /// 4xx はリクエストの行に error.code（短い固定の語）を積む。200 は積まない。
    @Test
    def testServerRejectionCodeTable(): Unit \ Assert =
        let json = ("Content-Type", "application/json") :: Nil;
        let opened = { jobsToken = Some("secret") | Server.defaultConfig() };
        let cases = List#{
            ((Server.defaultConfig(), requestOf("PUT", "/graphql", Nil, "")),                                      (405, Some("method_not_allowed"))),
            ((Server.defaultConfig(), requestOf("POST", "/", Nil, "")),                                            (404, Some("no_route"))),
            ((Server.defaultConfig(), requestOf("POST", "/graphql", ("Content-Type", "text/plain") :: Nil, "{}")), (415, Some("unsupported_media_type"))),
            ((Server.defaultConfig(), requestOf("POST", "/graphql", json, "{")),                                   (400, Some("bad_json"))),
            ((Server.defaultConfig(), requestOf("POST", "/graphql", json, "{\"q\": 1}")),                          (400, Some("bad_request"))),
            ((Server.defaultConfig(), requestOf("GET", "/graphql", Nil, "")),                                      (400, Some("bad_request"))),
            ((Server.defaultConfig(), requestOf("GET", "/graphql?query=mutation%20%7B%20x%20%7D", Nil, "")),     (405, Some("method_not_allowed"))),
            ((Server.defaultConfig(), requestOf("POST", "/jobs/tick", ("X-Jobs-Token", "x") :: Nil, "")),          (404, Some("no_route"))),
            ((opened, requestOf("POST", "/jobs/tick", ("X-Jobs-Token", "wrong") :: Nil, "")),                      (403, Some("jobs_token"))),
            ((Server.defaultConfig(), requestOf("POST", "/graphql", json, "{\"query\": \"{ x }\"}")),              (200, None))
        };
        Assert.assertEq(expected = cases |> List.map(snd),
            GraphqlFake.runWithEcho(() -> cases |> List.map(match ((config, request), _) -> rejectionOf(config, request))))

    /// MCP の本文を読む前の検査: 415 / 403 / 400 / 401 と error.code。403 は Origin（scheme + host）も積む。通る物は認証済みユーザー。
    @Test
    def testServerMcpPrecheckTable(): Unit \ Assert =
        let json = ("Content-Type", "application/json") :: Nil;
        let key = Actor.ApiKey("ci", ApiKeyScope.Read);
        let routeRequest = (headers, credential, auth) -> { request = requestOf("POST", "/mcp", headers, "{}"), params = Map.empty(), credential = credential, auth = auth, contentVersion = None };
        let summarize = outcome -> match outcome {
            case Ok(actor)               => Ok(actor)
            case Err((response, fields)) => Err((response#status, Map.get("error.code", fields) |> Option.flatMap(Value.asStr), Map.get("origin", fields) |> Option.flatMap(Value.asStr)))
        };
        let cases = List#{
            ((Nil, Credential.Missing, Ok(Authentication.anonymous())),                                                                Err((415, Some("unsupported_media_type"), None))),
            ((("Origin", "https://evil.example.com/path?q=1") :: json, Credential.ApiKey("cms_x"), Ok({ actor = key, log = Map.empty() })), Err((403, Some("origin"), Some("https://evil.example.com")))),
            ((("MCP-Protocol-Version", "2099-01-01") :: json, Credential.ApiKey("cms_x"), Ok({ actor = key, log = Map.empty() })),      Err((400, Some("protocol_version"), None))),
            ((json, Credential.Preview("pv_x"), Ok(Authentication.anonymous())),                                                       Err((400, Some("preview_token"), None))),
            ((json, Credential.PersonalToken("cmspat_x"), Err(Rejection.DeadToken(PatRejection.Revoked))),                              Err((401, Some("UNAUTHENTICATED"), None))),
            ((json, Credential.Invalid("JWT は無し"), Err(Rejection.Invalid("JWT は無し"))),                                             Err((401, Some("UNAUTHENTICATED"), None))),
            ((("Origin", "https://admin.example.com") :: json, Credential.ApiKey("cms_x"), Ok({ actor = key, log = Map.empty() })),     Ok(key)),
            ((json, Credential.Missing, Ok(Authentication.anonymous())),                                                               Ok(Actor.Anonymous))
        };
        Assert.assertEq(expected = cases |> List.map(snd),
            cases |> List.map(match ((headers, credential, auth), _) -> Server.mcpPrecheck(adminConfig(), routeRequest(headers, credential, auth)) |> summarize))

    /// parse に落ちた MCP の本文の理由: 壊れた JSON は bad_json、形の違う物は bad_request。message は応答の物。
    @Test
    def testServerMcpParseRejectionTable(): Unit \ Assert =
        let cases = List#{
            ("{",                          Some("bad_json")),
            ("[]",                         Some("bad_request")),
            ("{\"jsonrpc\":\"2.0\"}",      Some("bad_request"))
        };
        Assert.assertEq(expected = cases |> List.map(snd),
            cases |> List.map(match (body, _) -> match McpServer.parse(body) {
                case Err(errorBody) => Server.mcpParseRejection(errorBody) |> Map.get("error.code") |> Option.flatMap(Value.asStr)
                case Ok(_)          => None
            }))

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

    /// 身元無しで秒数の設定があれば public のキャッシュ、鍵付きや設定無しなら no-store。Vary は常に付く。
    @Test
    def testServerGetCacheControl(): Unit \ Assert =
        let cached = { cache = Some(CacheHeaders.defaultPolicy()) | Server.defaultConfig() };
        let headerOf = (config, credential) -> GraphqlFake.runWithEcho(() ->
            serve(config, HealthFake.ok(), credential, { version = "HTTP/1.1", method = "GET", path = "/graphql?query=%7B%20x%20%7D", headers = Nil, body = "" }))#headers
            |> Http.findHeader("Cache-Control");
        Assert.assertEq(
            expected = (Some("public, s-maxage=10, max-age=0, stale-while-revalidate=60"), Some("private, no-store"), Some("private, no-store")),
            (headerOf(cached, Credential.Missing), headerOf(cached, Credential.ApiKey("cms_x")), headerOf(Server.defaultConfig(), Credential.Missing)))

    ///
    /// GET /graphql に版を渡した時の (status, ETag, cache.status, 本文が空か):
    ///   匿名・版あり・If-None-Match 無し          → 200、ETag 付き、miss
    ///   匿名・版あり・If-None-Match が合う        → 304、同じ ETag、hit、本文無し
    ///   匿名・版あり・If-None-Match が古い版      → 200、新しい ETag、miss
    ///   匿名・版あり・If-None-Match が * → 304
    ///   鍵付き・版あり                            → 200、ETag 無し、bypass
    ///   匿名・版無し                              → 200、ETag 無し、miss
    ///
    @Test
    def testServerGetEtagTable(): Unit \ Assert =
        let etag7 = CacheHeaders.etagOf(7i64, { queryText = "{ x }", variables = Map.empty(), operationName = None });
        let etag6 = CacheHeaders.etagOf(6i64, { queryText = "{ x }", variables = Map.empty(), operationName = None });
        let get = headers -> { version = "HTTP/1.1", method = "GET", path = "/graphql?query=%7B%20x%20%7D", headers = headers, body = "" };
        let call = (credential, version, headers) -> {
            let (response, fields) = fst(Log.runWithList(() -> Observe.collect(() ->
                Server.handleWithVersion(Server.defaultConfig(), HealthFake.ok(), credential, Ok(Authentication.anonymous()), version, get(headers)))));
            (response#status, Http.findHeader("ETag", response#headers), Map.get("cache.status", fields) |> Option.flatMap(Value.asStr), String.isEmpty(response#body))
        };
        let cases = List#{
            ((Credential.Missing, Some(7i64), Nil),                              (200, Some(etag7), Some("miss"), false)),
            ((Credential.Missing, Some(7i64), ("If-None-Match", etag7) :: Nil),  (304, Some(etag7), Some("hit"), true)),
            ((Credential.Missing, Some(7i64), ("If-None-Match", etag6) :: Nil),  (200, Some(etag7), Some("miss"), false)),
            ((Credential.Missing, Some(7i64), ("If-None-Match", "*") :: Nil),    (304, Some(etag7), Some("hit"), true)),
            ((Credential.ApiKey("cms_x"), Some(7i64), Nil),                      (200, None, Some("bypass"), false)),
            ((Credential.Missing, None, Nil),                                    (200, None, Some("miss"), false))
        };
        Assert.assertEq(expected = cases |> List.map(snd),
            GraphqlFake.runWithEcho(() -> cases |> List.map(match ((credential, version, headers), _) -> call(credential, version, headers))))

    /// errors のある応答は no-store で ETag も付けない（失敗を CDN に溜めない）。
    @Test
    def testServerGetErrorsNotCached(): Unit \ Assert =
        let error = Value.Obj(Map#{ "message" => Value.Str("boom") });
        let response = GraphqlFake.runWithFixedResponse({ data = Value.Null, errors = error :: Nil }, () ->
            ServerTestKit.quietly(() -> Server.handleWithVersion({ cache = Some(CacheHeaders.defaultPolicy()) | Server.defaultConfig() }, HealthFake.ok(), Credential.Missing, Ok(Authentication.anonymous()), Some(7i64),
                { version = "HTTP/1.1", method = "GET", path = "/graphql?query=%7B%20x%20%7D", headers = Nil, body = "" })));
        Assert.assertEq(expected = (200, Some("private, no-store"), None),
            (response#status, Http.findHeader("Cache-Control", response#headers), Http.findHeader("ETag", response#headers)))

    /// 版が要るのはコンテンツ API の GET で鍵もトークンも無い時だけ。
    @Test
    def testServerWantsContentVersionTable(): Unit \ Assert =
        let routeRequest = (method, credential) -> { request = requestOf(method, "/graphql", Nil, ""), params = Map.empty(), credential = credential, auth = Ok(Authentication.anonymous()), contentVersion = None };
        let cases = List#{
            ((Engine.Content, "GET",  Credential.Missing),         true),
            ((Engine.Content, "POST", Credential.Missing),         false),
            ((Engine.Content, "GET",  Credential.ApiKey("cms_x")), false),
            ((Engine.Admin,   "GET",  Credential.Missing),         false)
        };
        Assert.assertEq(expected = cases |> List.map(snd),
            cases |> List.map(match ((engine, method, credential), _) -> Server.wantsContentVersion(engine, routeRequest(method, credential))))

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
        Assert.assertEq(expected = ((200, Ok(Value.Obj(Map#{ "status" => Value.Str("ok"), "version" => Value.Str("dev"), "jobs" => Value.Obj(Map#{ "lastTickAt" => Value.Null, "pendingSchedules" => Value.Int(0), "failedSchedules" => Value.Int(0), "pendingDeliveries" => Value.Int(0), "failedDeliveries" => Value.Int(0) }), "connections" => Value.Obj(Map#{ "active" => Value.Int(1), "max" => Value.Int(256) }), "pool" => Value.Obj(Map#{ "active" => Value.Int(1), "idle" => Value.Int(2), "waiting" => Value.Int(0), "total" => Value.Int(3), "max" => Value.Int(10) }) }))), 200),
            GraphqlFake.runWithEcho(() -> {
                let response = handle({ version = "HTTP/1.1", method = "GET", path = "/health", headers = Nil, body = "" });
                ((response#status, JsonValue.parse(response#body)),
                 handle({ version = "HTTP/1.1", method = "GET", path = "/health?probe=1", headers = Nil, body = "" })#status)
            }))

    /// DB に届かなければ 503 で、理由を db に入れる。件数は数えない（-1）ので、jobsSummary には checkDb の結果がそのまま渡る。
    @Test
    def testServerHealthFailure(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() ->
            serve(Server.defaultConfig(), HealthFake.failing("connection refused"), Credential.Missing, { version = "HTTP/1.1", method = "GET", path = "/health", headers = Nil, body = "" }));
        Assert.assertEq(expected = (503, Ok(Value.Obj(Map#{ "status" => Value.Str("error"), "version" => Value.Str("dev"), "db" => Value.Str("connection refused"), "jobs" => Value.Obj(Map#{ "lastTickAt" => Value.Null, "pendingSchedules" => Value.Int(-1), "failedSchedules" => Value.Int(-1), "pendingDeliveries" => Value.Int(-1), "failedDeliveries" => Value.Int(-1) }), "connections" => Value.Obj(Map#{ "active" => Value.Int(1), "max" => Value.Int(256) }), "pool" => Value.Obj(Map#{ "active" => Value.Int(1), "idle" => Value.Int(2), "waiting" => Value.Int(0), "total" => Value.Int(3), "max" => Value.Int(10) }) }))),
            (response#status, JsonValue.parse(response#body)))

    /// DB に届いても仕事の tick が止まっていれば 503 で、reason に止まった tick を入れる。
    @Test
    def testServerHealthStalled(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() ->
            serve(Server.defaultConfig(), HealthFake.stalled(), Credential.Missing, { version = "HTTP/1.1", method = "GET", path = "/health", headers = Nil, body = "" }));
        Assert.assertEq(expected = (503, Ok(Value.Str("jobs stalled"))),
            (response#status, JsonValue.parse(response#body) |> Result.map(body -> match body { case Value.Obj(fields) => Map.get("reason", fields) |> Option.getWithDefault(Value.Null) case _ => Value.Null })))

    /// DB に届き tick も動いていて、接続が漏れてプールだけが張り付いていれば、200 のまま status が degraded で reason が付く。
    @Test
    def testServerHealthSaturated(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() ->
            serve(Server.defaultConfig(), HealthFake.saturated(), Credential.Missing, { version = "HTTP/1.1", method = "GET", path = "/health", headers = Nil, body = "" }));
        Assert.assertEq(expected = (200, Ok((Value.Str("degraded"), Value.Str("pool saturated (90%)")))),
            (response#status, JsonValue.parse(response#body) |> Result.map(body -> match body {
                case Value.Obj(fields) => (Map.get("status", fields) |> Option.getWithDefault(Value.Null), Map.get("reason", fields) |> Option.getWithDefault(Value.Null))
                case _ => (Value.Null, Value.Null)
            })))

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
            GraphqlFake.runWithEcho(() -> serve(adminConfig(), HealthFake.ok(), Credential.Missing, fromAdmin("POST", "/graphql")))#headers)

    /// preflight は 204 で、Graphql を呼ばずに返る（偽ハンドラの応答がボディに現れない）。
    /// Allow-Origin は 1 回だけ付く（preflight と withHeaders で二重にならない）。
    @Test
    def testServerPreflight(): Unit \ Assert =
        let response = GraphqlFake.runWithEcho(() -> serve(adminConfig(), HealthFake.ok(), Credential.Missing, fromAdmin("OPTIONS", "/graphql")));
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
            GraphqlFake.runWithEcho(() -> serve(adminConfig(), HealthFake.ok(), Credential.Missing, fromAdmin("OPTIONS", path))));
        Assert.assertEq(expected = (List#{204, 204, 204, 404}, List#{true, true, true, true}),
            (responses |> List.map(response -> response#status),
             responses |> List.map(response -> List.memberOf(("Access-Control-Allow-Origin", "https://admin.example.com"), response#headers))))

    // ---- ルート表 ----

    /// 表の全行（/p/{projectSlug} 付きの複製込み）。行を足したらここにも足す。
    @Test
    def testServerRoutesDescribe(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                "POST /graphql", "GET /graphql", "POST /admin/graphql", "GET /admin/graphql", "POST /account/graphql", "GET /health", "POST /jobs/tick", "POST /mcp",
                "POST /p/{projectSlug}/graphql", "GET /p/{projectSlug}/graphql", "POST /p/{projectSlug}/admin/graphql", "GET /p/{projectSlug}/admin/graphql",
                "GET /p/{projectSlug}/health", "POST /p/{projectSlug}/jobs/tick", "POST /p/{projectSlug}/mcp" },
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
        let slugOf = (baseDomain, path, host) -> Observe.ignore(() ->
            Server.wrapProjectFromHost(baseDomain, Server.dispatch(table, (_, routeRequest) ->
                { status = 200, headers = Nil, body = Map.get(Router.projectSlugParam(), routeRequest#params) |> Option.getWithDefault("") }))
                ({ request = { version = "HTTP/1.1", method = "GET", path = path, headers = ("Host", host) :: Nil, body = "" }, params = Map.empty(), credential = Credential.Missing, auth = Ok(Authentication.anonymous()), contentVersion = None })#body);
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
        let call = (config, token) -> GraphqlFake.runWithEcho(() -> serve(config, HealthFake.ok(), Credential.Missing, request(token)));
        Assert.assertEq(expected = (404, 403, 200, "{\"failures\":[],\"status\":\"ok\"}"),
            (call(closed, "secret")#status, call(opened, "wrong")#status, call(opened, "secret")#status, call(opened, "secret")#body))

}
