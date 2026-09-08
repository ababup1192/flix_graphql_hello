///
/// サーバの設定。
///
/// - cors: 許すオリジン
/// - version: /health に出す版（イメージの git の sha など）
/// - jobsToken: POST /jobs/tick（外部トリガー）を許す X-Jobs-Token の値。None なら閉じる
/// - cacheMaxAge: コンテンツ API の GET で身元無しの応答に付ける Cache-Control の秒数（CDN 用）。None なら no-store
///
pub type alias ServerConfig = { cors = CorsConfig, version = String, jobsToken = Option[String], cacheMaxAge = Option[Int32] }

///
/// HTTP リクエストを GraphQL の実行と死活監視に橋渡しするルーティング。ルートは `routes` の表で持つ。
/// ソケットも graphql-java も JDBC も触らず、`Graphql` effect と、渡された `Health`（死活の値を読む関数の束）だけに依存する。
///
mod Server {

    ///
    /// CORS 無しの設定。テストと、同一オリジンだけで使うとき。
    ///
    pub def defaultConfig(): ServerConfig = { cors = Cors.none(), version = "dev", jobsToken = None, cacheMaxAge = None }

    ///
    /// ルート表。行を足す時はここに 1 行と、TestServer の `describe` の一覧に 1 行。
    /// `/p/{projectSlug}/...` は書かず、`Router.withProjectPrefix` が Account 以外を複製する。
    ///
    /// - POST /graphql, /admin/graphql, /account/graphql: ボディ {"query": "...", "variables": {...}, "operationName": "..."} を実行して {"data": ..., "errors": [...]} を返す
    /// - GET /graphql, /admin/graphql ?query=...&variables=...&operationName=...: query だけ（mutation は 405）。コンテンツ API は身元無しなら Cache-Control で CDN に乗せられる
    /// - GET /health: DB に届けば 200、届かなければ 503。jobs にワーカーの最終実行時刻と待ち・失敗の件数（数えられなければ -1）
    /// - POST /jobs/tick: 外部トリガー。X-Jobs-Token が設定と一致すればワーカーを 1 周回す（無ければ 404）
    /// - POST /mcp: MCP サーバ（JSON-RPC。tools だけ）。管理 API のエンジンへの GraphQL クライアントとして動く
    ///
    pub def routes(config: ServerConfig, health: Health[ef]): List[Route[{Graphql, Log, Observe, ef}]] =
        Router.route(Method.Post, "/graphql",         Some(Engine.Content), widen(executeBody)) ::
        Router.route(Method.Get,  "/graphql",         Some(Engine.Content), widen(executeQueryString(config#cacheMaxAge))) ::
        Router.route(Method.Post, "/admin/graphql",   Some(Engine.Admin),   widen(executeBody)) ::
        Router.route(Method.Get,  "/admin/graphql",   Some(Engine.Admin),   widen(executeQueryString(None))) ::
        Router.route(Method.Post, "/account/graphql", Some(Engine.Account), widen(executeBody)) ::
        Router.route(Method.Get,  "/health",          None,                 widen(healthRoute(config#version, health))) ::
        Router.route(Method.Post, "/jobs/tick",       None,                 widen(jobsTick(config#jobsToken, health))) ::
        Router.route(Method.Post, "/mcp",             Some(Engine.Admin),   widen(mcpRoute(config))) :: Nil

    ///
    /// 行の handler を表全体の effect に広げる。行ごとの handler は自分の effect（Graphql だけ、Health の ef だけ）を宣言したままにする。
    ///
    def widen(handle: RouteRequest -> HttpResponse \ ef1): RouteRequest -> HttpResponse \ ef1 + ef2 =
        routeRequest -> checked_ecast(handle(routeRequest))

    ///
    /// リクエストを 1 つ処理する。エンジンは呼ぶ側が入れておく（表の engine は見ない）。health は /health と /jobs/tick が読む値。
    /// 表に無いパスは 404、パスはあるがメソッドが違えば 405 と Allow、OPTIONS は preflight。許したオリジンからのリクエストには CORS ヘッダを足す。
    /// 4xx の理由（error.code / error.message）は Observe に積む。
    ///
    pub def handle(config: ServerConfig, health: Health[ef], credential: Credential, request: HttpRequest): HttpResponse \ {Graphql, Log, Observe, ef} =
        let table = routes(config, health) |> Router.withProjectPrefix;
        let pipeline = Cors.wrap(config#cors, Router.allowedMethods(table), dispatch(table, (found, routeRequest) -> (found#handle)(routeRequest)));
        pipeline({ request = request, params = Map.empty(), credential = credential })

    ///
    /// 表で振り分ける handler。一致した行は found に渡す（Main はここで engine を見てエンジンを入れる）。
    /// 404 と 405 はここで返す（理由は Observe に積む）。
    ///
    pub def dispatch(routes: List[Route[ef1]], found: (Route[ef1], RouteRequest) -> HttpResponse \ ef2): Handler[ef2 + Observe] =
        routeRequest -> match Router.matchRequest(routes, routeRequest#request) {
            case Match.Found(matched, params)   => found(matched, Router.withParams(params, routeRequest))
            case Match.MethodNotAllowed(allowed) => reject(405, ("Allow", Method.join(allowed)) :: Nil, "method_not_allowed", "${Method.join(allowed)} only")
            case Match.NotFound                  => reject(404, Nil, "no_route", "not found")
        }

    ///
    /// Host からプロジェクトを選ぶ middleware。`{プロジェクト slug}.{baseDomain}` なら params に projectSlug を入れる。
    /// パスの /p/{projectSlug} は後で（dispatch が）上書きするので、パスが勝つ。
    ///
    pub def wrapProjectFromHost(baseDomain: Option[String], next: Handler[ef]): Handler[ef] =
        routeRequest -> match projectSlugFromHost(baseDomain, routeRequest#request#headers) {
            case Some(projectSlug) => next({ params = Map.insert(Router.projectSlugParam(), projectSlug, routeRequest#params) | routeRequest })
            case None              => next(routeRequest)
        }

    ///
    /// 503。コンテンツ API のスキーマを組めなかった時など、サーバ側の一時的な失敗。
    ///
    pub def unavailable(message: String): HttpResponse =
        errorResponse(503, Nil, message)

    ///
    /// 404。無いプロジェクトなど。
    ///
    pub def notFound(message: String): HttpResponse =
        errorResponse(404, Nil, message)

    ///
    /// Content-Type が application/json か（大文字小文字と charset は問わない）。
    ///
    /// WhyNot: Content-Type を見ずに本文を実行しないのは、Cookie で認証する時に他サイトの form から text/plain で
    /// POST されると preflight 無しで届き、被害者の Cookie 付きで mutation が通る（CSRF）ため。JSON を要求すれば必ず preflight が走る。
    ///
    pub def isJson(request: HttpRequest): Bool =
        Http.findHeader("Content-Type", request#headers)
            |> Option.map(value -> String.startsWith(prefix = "application/json", String.toLowerCase(value)))
            |> Option.getWithDefault(false)

    ///
    /// Host ヘッダからプロジェクト slug を取る。`{プロジェクト slug}.{baseDomain}` の形の時だけ Some。ポートは無視する。
    /// baseDomain が無い（CMS_BASE_DOMAIN 未設定）なら常に None で、/p/{プロジェクト slug}/ だけが効く。
    ///
    pub def projectSlugFromHost(baseDomain: Option[String], headers: List[(String, String)]): Option[String] =
        let host = Http.findHeader("Host", headers)
            |> Option.map(value -> value |> String.toLowerCase |> String.splitOn(substr = ":") |> List.head |> Option.getWithDefault(""));
        match (baseDomain |> Option.map(String.toLowerCase), host) {
            case (Some(base), Some(found)) if String.endsWith(suffix = ".${base}", found) =>
                let label = String.dropRight(String.length(base) + 1, found);
                ProjectSlug.parse(label) |> Option.map(ProjectSlug.text)
            case _ => None
        }

    ///
    /// GET /health。DB に届けば {"status": "ok", "version": "...", "jobs": {"lastTickAt": ...}, "connections": {"active": 1, "max": 256}, "pool": {"active": 1, ...}}、届かなければ 503 で理由を付ける。
    /// DB に届いても、仕事の周か見張りの周が止まっていれば 503 で reason（`jobs stalled` / `watch stalled`）を付ける。
    /// connections は HTTP の接続、pool は DB の接続プール（別の物）。
    /// 先に自己回復の判断を 1 回進める（プールが壊れたまま戻らないと決まれば、この中でプロセスが終わる）。
    ///
    /// WhyNot: 判断を見張りのスレッドだけに任せないのは、そのスレッドが OOM で死ぬと自己回復が永久に無効になるため。
    /// リクエストのスレッドは OOM の後も生きている側で、Docker の HEALTHCHECK が叩く限りここで判断が進む。
    ///
    def healthRoute(version: String, health: Health[ef], _routeRequest: RouteRequest): HttpResponse \ {Observe, ef} =
        (health#heal)();
        let stall = (health#stall)();
        Option.forEach(found -> Observe.note(Log.Fields.empty() |> Log.Fields.int(Health.stallKey(found), Health.stallMs(found))), stall);
        let summary = (health#jobsSummary)();
        let connected = (health#connections)();
        let stats = (health#poolStats)();
        let connections = Value.Obj(Map#{ "active" => Value.Int(connected#active), "max" => Value.Int(connected#max) });
        let pool = Value.Obj(Map#{
            "active" => Value.Int(stats#active), "idle" => Value.Int(stats#idle), "waiting" => Value.Int(stats#waiting),
            "total" => Value.Int(stats#total), "max" => Value.Int(stats#max) });
        let jobs = Value.Obj(Map#{
            "lastTickAt" => summary#lastTickAt |> Option.map(Value.Str) |> Option.getWithDefault(Value.Null),
            "pendingSchedules" => Value.Int(Int64.clampToInt32(min = -1, max = 2147483647, summary#pendingSchedules)),
            "failedSchedules" => Value.Int(Int64.clampToInt32(min = -1, max = 2147483647, summary#failedSchedules)),
            "pendingDeliveries" => Value.Int(Int64.clampToInt32(min = -1, max = 2147483647, summary#pendingDeliveries)),
            "failedDeliveries" => Value.Int(Int64.clampToInt32(min = -1, max = 2147483647, summary#failedDeliveries)) });
        let base = Map#{ "version" => Value.Str(version), "jobs" => jobs, "connections" => connections, "pool" => pool };
        match ((health#checkDb)(), stall) {
            case (Ok(()), None)          => { status = 200, headers = Nil, body = JsonValue.toJsonString(Value.Obj(Map.insert("status", Value.Str("ok"), base))) }
            case (Ok(()), Some(found))   => { status = 503, headers = Nil, body = JsonValue.toJsonString(Value.Obj(base |> Map.insert("status", Value.Str("error")) |> Map.insert("reason", Value.Str(Health.stallReason(found))))) }
            case (Err(message), _)       => { status = 503, headers = Nil, body = JsonValue.toJsonString(Value.Obj(base |> Map.insert("status", Value.Str("error")) |> Map.insert("db", Value.Str(message)))) }
        }

    ///
    /// POST /jobs/tick。トークンが設定されていなければ 404（存在を見せない）、違えば 403、合えば 1 周回して失敗の説明を返す。
    ///
    def jobsTick(jobsToken: Option[String], health: Health[ef], routeRequest: RouteRequest): HttpResponse \ {Observe, ef} =
        let given = Http.findHeader("X-Jobs-Token", routeRequest#request#headers);
        match jobsToken {
            case None => reject(404, Nil, "no_route", "not found")
            case Some(expected) =>
                if (given != Some(expected)) reject(403, Nil, "jobs_token", "X-Jobs-Token が違います")
                else {
                    let failures = (health#runJobs)();
                    { status = if (List.isEmpty(failures)) 200 else 500, headers = Nil,
                      body = JsonValue.toJsonString(Value.Obj(Map#{ "status" => Value.Str(if (List.isEmpty(failures)) "ok" else "error"), "failures" => Value.List(failures |> List.map(Value.Str)) })) }
                }
        }

    ///
    /// POST /mcp。Content-Type が JSON でなければ 415、Origin が許可外なら 403、知らない MCP-Protocol-Version は 400、
    /// プレビュートークンは 400（この経路では受けない）、壊れたログインの JWT と死んだ PAT は 401 + WWW-Authenticate。
    /// parse に落ちた本文は 400、通知は 202、それ以外は 200 で JSON-RPC の応答。tools/call の属性（mcp.tool / mcp.outcome / id / error.code）は
    /// Observe に積んでリクエストの行に乗せる。
    ///
    def mcpRoute(config: ServerConfig, routeRequest: RouteRequest): HttpResponse \ {Graphql, Observe} =
        match mcpPrecheck(config, routeRequest) {
            case Err((response, fields)) => { Observe.note(fields); response }
            case Ok(())                  => match McpServer.parse(routeRequest#request#body) {
                case Err(errorBody) => { Observe.note(mcpParseRejection(errorBody)); jsonResponse(400, Nil, errorBody) }
                case Ok(message)    =>
                    let reply = McpServer.dispatch(config#version, message, executeAs(routeRequest#credential));
                    noteMcpCall(message, reply);
                    toMcpResponse(reply)
            }
        }

    /// tools/call の属性を積む。他の method は何も積まない。
    def noteMcpCall(message: McpServer.Message, reply: McpServer.Reply): Unit \ Observe =
        match McpServer.callSummary(message, reply) {
            case None          => ()
            case Some(summary) => Observe.note(Log.Fields.empty() |> LogFields.mcp(summary))
        }

    ///
    /// parse に落ちた本文の理由。-32700（壊れた JSON）は bad_json、それ以外（バッチ・method 無し）は bad_request。
    ///
    pub def mcpParseRejection(errorBody: Value): Log.Fields =
        let code = if (Value.path(List#{"error", "code"}, errorBody) == Value.Int(McpServer.parseErrorCode())) "bad_json" else "bad_request";
        Log.Fields.empty() |> LogFields.rejection(code, Value.path(List#{"error", "message"}, errorBody) |> Value.asStr |> Option.getWithDefault(""))

    ///
    /// 身元付きで Graphql effect を呼ぶ。McpServer.dispatch の execute。
    ///
    /// WhyNot: mcpRoute の中のラムダにしないのは、effect を使う式をラムダに直に書くと JVM の VerifyError が出る事があるため。
    ///
    def executeAs(credential: Credential, request: GraphqlRequest): GraphqlResponse \ Graphql =
        Graphql.execute(request, Context.withCredential(credential))

    ///
    /// MCP の本文を読む前の検査。Err はそのまま返す応答と、リクエストの行に積む理由（error.code / error.message。403 は origin も）。
    ///
    pub def mcpPrecheck(config: ServerConfig, routeRequest: RouteRequest): Result[(HttpResponse, Log.Fields), Unit] =
        let request = routeRequest#request;
        let rejected = (status, headers, code, message) -> (jsonResponse(status, headers, McpServer.errorBody(Value.Null, McpServer.invalidRequestCode(), message)), Log.Fields.empty() |> LogFields.rejection(code, message));
        if (not isJson(request)) {
            let message = "Content-Type: application/json で送ってください";
            Err((errorResponse(415, Nil, message), Log.Fields.empty() |> LogFields.rejection("unsupported_media_type", message)))
        }
        else if (not McpServer.isOriginAllowed(config#cors, request#headers)) {
            let (response, fields) = rejected(403, Nil, "origin", "この Origin からは受け付けません");
            Err((response, fields |> LogFields.origin(Http.findHeader("Origin", request#headers) |> Option.getWithDefault(""))))
        }
        else match (McpServer.protocolVersionOf(request#headers), routeRequest#credential) {
            case (Err(version), _)                   => Err(rejected(400, Nil, "protocol_version", "MCP-Protocol-Version '${version}' には対応していません（${List.join(" / ", McpServer.supportedProtocolVersions())}）"))
            case (Ok(_), Credential.Preview(_))      => Err(rejected(400, Nil, "preview_token", "プレビュートークンはこの経路では受け付けません（API キーか PAT で）"))
            case (Ok(_), Credential.Invalid(reason)) => Err(rejected(401, ("WWW-Authenticate", "Bearer error=\"invalid_token\"") :: Nil, "unauthenticated", "認証に失敗しました: ${reason}"))
            case (Ok(_), _)                          => Ok(())
        }

    ///
    /// dispatch の答えを HTTP に。
    ///
    def toMcpResponse(reply: McpServer.Reply): HttpResponse = match reply {
        case McpServer.Reply.Body(body)            => jsonResponse(200, Nil, body)
        case McpServer.Reply.Accepted              => { status = 202, headers = Nil, body = "" }
        case McpServer.Reply.Unauthenticated(body) => jsonResponse(401, ("WWW-Authenticate", "Bearer error=\"invalid_token\"") :: Nil, body)
    }

    ///
    /// JSON の応答。
    ///
    def jsonResponse(status: Int32, headers: List[(String, String)], body: Value): HttpResponse =
        { status = status, headers = headers, body = JsonValue.toJsonString(body) }

    ///
    /// POST の JSON ボディを GraphqlRequest に読んで実行する。Content-Type が JSON でなければ 415、壊れた JSON・形の違うボディは 400。
    ///
    def executeBody(routeRequest: RouteRequest): HttpResponse \ {Graphql, Observe} =
        if (not isJson(routeRequest#request)) reject(415, Nil, "unsupported_media_type", "Content-Type: application/json で送ってください")
        else {
            let parsed = JsonValue.parse(routeRequest#request#body)
                |> Result.mapErr(message -> ("bad_json", "invalid JSON: ${message}"))
                |> Result.flatMap(body -> toRequest(body) |> Result.mapErr(message -> ("bad_request", message)));
            match parsed {
                case Ok(request)            => { status = 200, headers = Nil, body = JsonValue.toJsonString(toValue(Graphql.execute(request, Context.withCredential(routeRequest#credential)))) }
                case Err((code, message))   => reject(400, Nil, code, message)
            }
        }

    ///
    /// GET のクエリ文字列を実行する。query が無ければ 400、mutation / subscription なら 405（GET は読むだけ）。
    /// 身元無し（鍵もトークンも無い）で errors が無ければ Cache-Control を public にして CDN に乗せ、それ以外は no-store。
    ///
    /// WhyNot: 身元付きの応答をキャッシュしないのは、鍵ごとに違う中身（下書き、非公開プロジェクト）が共有キャッシュから他人に出るため。
    /// Vary で鍵のヘッダを指しても、鍵の値ごとに溜まる事自体を避ける。
    ///
    def executeQueryString(cacheMaxAge: Option[Int32], routeRequest: RouteRequest): HttpResponse \ {Graphql, Observe} =
        let credential = routeRequest#credential;
        let params = Http.parseQueryString(routeRequest#request#path);
        let parsed = forM (
            queryText <- Map.get("query", params) |> Option.filter(text -> not String.isEmpty(text)) |> Option.toOk("query パラメータが要ります（?query=...）");
            variables <- Map.get("variables", params) |> Option.filter(text -> not String.isEmpty(text))
                |> Option.map(text -> JsonValue.parse(text) |> Result.mapErr(message -> "variables が JSON ではありません: ${message}") |> Result.flatMap(toVariables))
                |> Option.getWithDefault(Ok(Map.empty()))
        ) yield { queryText = queryText, variables = variables, operationName = Map.get("operationName", params) |> Option.filter(text -> not String.isEmpty(text)) };
        match parsed {
            case Err(message) => reject(400, Nil, "bad_request", message)
            case Ok(graphqlRequest) =>
                if (not isReadOnly(graphqlRequest#queryText)) reject(405, ("Allow", "POST") :: Nil, "method_not_allowed", "GET は query だけです。mutation は POST で送ってください")
                else {
                    let response = Graphql.execute(graphqlRequest, Context.withCredential(credential));
                    let cacheable = cacheMaxAge |> Option.filter(_ -> credential == Credential.Missing and List.isEmpty(response#errors));
                    let cacheControl = match cacheable {
                        case Some(seconds) => "public, max-age=${seconds}, s-maxage=${seconds}, stale-while-revalidate=${seconds}"
                        case None          => "private, no-store"
                    };
                    { status = 200, headers = ("Cache-Control", cacheControl) :: ("Vary", "X-Api-Key, X-Preview-Token, Authorization") :: Nil, body = JsonValue.toJsonString(toValue(response)) }
                }
        }

    ///
    /// GraphQL の文書が読むだけか。括弧の深さ 0 に mutation / subscription の語が無ければ読むだけ（無名の { ... } と query は読む）。
    /// # のコメントと文字列の中は見ない。
    ///
    pub def isReadOnly(queryText: String): Bool =
        topLevelWords(String.toList(queryText), 0, false, false, Nil)
            |> List.forAll(word -> word != "mutation" and word != "subscription")

    ///
    /// ログに出す操作の種類と名前。深さ 0 の query / mutation / subscription が種類（無名の { ... } は query）、
    /// その次の語が名前（`query Q($a: Int!)` の Q。無ければ None）。operationName があればその名前の操作、無ければ最初の操作。fragment だけの文書は query。
    ///
    pub def operationOf(queryText: String, operationName: Option[String]): (String, Option[String]) =
        let words = topLevelWords(String.toList(queryText), 0, false, false, Nil);
        let operations = operationsOf(words, Nil);
        match operationName {
            case Some(name) => List.find(match (_, found) -> found == Some(name), operations) |> Option.getWithDefault(("query", Some(name)))
            case None       => List.head(operations) |> Option.getWithDefault(("query", None))
        }

    /// 深さ 0 の語から (種類, 名前) の並び。種類の語の直後の語が名前（次も種類の語なら無名）。
    def operationsOf(words: List[String], acc: List[(String, Option[String])]): List[(String, Option[String])] = match words {
        case keyword :: name :: rest if isOperationKeyword(keyword) and not isOperationKeyword(name) => operationsOf(rest, (keyword, Some(name)) :: acc)
        case keyword :: rest if isOperationKeyword(keyword) => operationsOf(rest, (keyword, None) :: acc)
        case _ :: rest => operationsOf(rest, acc)
        case Nil       => List.reverse(acc)
    }

    /// 操作の種類の語か。
    def isOperationKeyword(word: String): Bool =
        word == "query" or word == "mutation" or word == "subscription"

    /// 深さ 0 の語を集める。inString は文字列の中、inComment は # から行末。
    def topLevelWords(chars: List[Char], depth: Int32, inString: Bool, inComment: Bool, acc: List[String]): List[String] = match chars {
        case Nil => List.reverse(acc)
        case '\n' :: rest if inComment => topLevelWords(rest, depth, false, false, acc)
        case _ :: rest if inComment    => topLevelWords(rest, depth, false, true, acc)
        case '\\' :: _ :: rest if inString => topLevelWords(rest, depth, true, false, acc)
        case '"' :: rest if inString   => topLevelWords(rest, depth, false, false, acc)
        case _ :: rest if inString     => topLevelWords(rest, depth, true, false, acc)
        case '"' :: rest               => topLevelWords(rest, depth, true, false, acc)
        case '#' :: rest               => topLevelWords(rest, depth, false, true, acc)
        case '{' :: rest               => topLevelWords(rest, depth + 1, false, false, acc)
        case '(' :: rest               => topLevelWords(rest, depth + 1, false, false, acc)
        case '}' :: rest               => topLevelWords(rest, depth - 1, false, false, acc)
        case ')' :: rest               => topLevelWords(rest, depth - 1, false, false, acc)
        case ch :: _ if depth == 0 and Char.isLetter(ch) =>
            let word = List.takeWhile(c -> Char.isLetterOrDigit(c) or c == '_', chars);
            topLevelWords(List.drop(List.length(word), chars), depth, false, false, (word |> List.map(Char.toString) |> List.join("")) :: acc)
        case _ :: rest                 => topLevelWords(rest, depth, false, false, acc)
    }

    ///
    /// ボディの Value を GraphqlRequest に組み立てる。
    /// query は必須の文字列。variables は省略可能なオブジェクト（省略時は空）。operationName は省略可能な文字列。
    ///
    def toRequest(body: Value): Result[String, GraphqlRequest] =
        forM (
            queryText <- Value.field("query", body) |> Value.asStr |> Option.toOk("body must be {\"query\": \"...\"}");
            variables <- toVariables(Value.field("variables", body))
        ) yield { queryText = queryText, variables = variables, operationName = Value.field("operationName", body) |> Value.asStr }

    ///
    /// variables フィールドを Map に読む。無ければ空、オブジェクトでなければ Err。
    ///
    def toVariables(value: Value): Result[String, Map[String, Value]] = match value {
        case Value.Null        => Ok(Map.empty())
        case Value.Obj(fields) => Ok(fields)
        case _                 => Err("variables must be an object")
    }

    ///
    /// GraphqlResponse を GraphQL over HTTP の形（data と errors）に並べる。
    /// errors の各要素は graphql-java のエラーオブジェクトをそのまま出す。
    /// errors が無いときはキー自体を出さない。
    ///
    def toValue(response: GraphqlResponse): Value =
        let fields = Map#{ "data" => response#data };
        Value.Obj(if (List.isEmpty(response#errors)) fields else Map.insert("errors", Value.List(response#errors), fields))

    ///
    /// 4xx を返し、理由（error.code / error.message）をリクエストの行に積む。
    ///
    def reject(status: Int32, headers: List[(String, String)], code: String, message: String): HttpResponse \ Observe =
        Observe.note(Log.Fields.empty() |> LogFields.rejection(code, message));
        errorResponse(status, headers, message)

    ///
    /// エラーを GraphQL と同じ errors[].message の形で返す。headers は 405 の Allow のように
    /// ステータスに付ける追加のレスポンスヘッダ。
    ///
    def errorResponse(status: Int32, headers: List[(String, String)], message: String): HttpResponse =
        { status = status, headers = headers, body = errorBody(message) }

    ///
    /// errors[].message だけを持つ JSON ボディ。
    ///
    def errorBody(message: String): String =
        let error = Value.Obj(Map#{ "message" => Value.Str(message) });
        JsonValue.toJsonString(toValue({ data = Value.Null, errors = error :: Nil }))

}
