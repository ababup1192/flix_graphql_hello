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
/// ソケットも graphql-java も JDBC も触らず、`Graphql` と `Health` の effect だけに依存する。
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
    ///
    pub def routes(config: ServerConfig): List[Route[{Graphql, Health}]] =
        Router.route(Method.Post, "/graphql",         Some(Engine.Content), widen(executeBody)) ::
        Router.route(Method.Get,  "/graphql",         Some(Engine.Content), widen(executeQueryString(config#cacheMaxAge))) ::
        Router.route(Method.Post, "/admin/graphql",   Some(Engine.Admin),   widen(executeBody)) ::
        Router.route(Method.Get,  "/admin/graphql",   Some(Engine.Admin),   widen(executeQueryString(None))) ::
        Router.route(Method.Post, "/account/graphql", Some(Engine.Account), widen(executeBody)) ::
        Router.route(Method.Get,  "/health",          None,                 widen(health(config#version))) ::
        Router.route(Method.Post, "/jobs/tick",       None,                 widen(jobsTick(config#jobsToken))) :: Nil

    ///
    /// 行の handler を表全体の effect に広げる。行ごとの handler は自分の effect（Graphql だけ、Health だけ）を宣言したままにする。
    ///
    def widen(handle: RouteRequest -> HttpResponse \ ef1): RouteRequest -> HttpResponse \ ef1 + ef2 =
        routeRequest -> checked_ecast(handle(routeRequest))

    ///
    /// リクエストを 1 つ処理する。エンジンは呼ぶ側が入れておく（表の engine は見ない）。
    /// 表に無いパスは 404、パスはあるがメソッドが違えば 405 と Allow、OPTIONS は preflight。許したオリジンからのリクエストには CORS ヘッダを足す。
    ///
    pub def handle(config: ServerConfig, credential: Credential, request: HttpRequest): HttpResponse \ {Graphql, Health} =
        let table = routes(config) |> Router.withProjectPrefix;
        let pipeline = Cors.wrap(config#cors, Router.allowedMethods(table), dispatch(table, (found, routeRequest) -> (found#handle)(routeRequest)));
        pipeline({ request = request, params = Map.empty(), credential = credential })

    ///
    /// 表で振り分ける handler。一致した行は found に渡す（Main はここで engine を見てエンジンを入れる）。
    /// 404 と 405 はここで返す。
    ///
    pub def dispatch(routes: List[Route[ef1]], found: (Route[ef1], RouteRequest) -> HttpResponse \ ef2): Handler[ef2] =
        routeRequest -> match Router.matchRequest(routes, routeRequest#request) {
            case Match.Found(matched, params)   => found(matched, Router.withParams(params, routeRequest))
            case Match.MethodNotAllowed(allowed) => errorResponse(405, ("Allow", Method.join(allowed)) :: Nil, "${Method.join(allowed)} only")
            case Match.NotFound                  => errorResponse(404, Nil, "not found")
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
    /// GET /health。DB に届けば {"status": "ok", "version": "...", "jobs": {"lastTickAt": ...}, "connections": {"active": 1, "max": 256}}、届かなければ 503 で理由を付ける。
    ///
    def health(version: String, _routeRequest: RouteRequest): HttpResponse \ Health =
        let summary = Health.jobsSummary();
        let connected = Health.connections();
        let connections = Value.Obj(Map#{ "active" => Value.Int(connected#active), "max" => Value.Int(connected#max) });
        let jobs = Value.Obj(Map#{
            "lastTickAt" => summary#lastTickAt |> Option.map(Value.Str) |> Option.getWithDefault(Value.Null),
            "pendingSchedules" => Value.Int(Int64.clampToInt32(min = -1, max = 2147483647, summary#pendingSchedules)),
            "failedSchedules" => Value.Int(Int64.clampToInt32(min = -1, max = 2147483647, summary#failedSchedules)),
            "pendingDeliveries" => Value.Int(Int64.clampToInt32(min = -1, max = 2147483647, summary#pendingDeliveries)),
            "failedDeliveries" => Value.Int(Int64.clampToInt32(min = -1, max = 2147483647, summary#failedDeliveries)) });
        match Health.checkDb() {
            case Ok(())       => { status = 200, headers = Nil, body = JsonValue.toJsonString(Value.Obj(Map#{ "status" => Value.Str("ok"), "version" => Value.Str(version), "jobs" => jobs, "connections" => connections })) }
            case Err(message) => { status = 503, headers = Nil, body = JsonValue.toJsonString(Value.Obj(Map#{ "status" => Value.Str("error"), "version" => Value.Str(version), "db" => Value.Str(message), "jobs" => jobs, "connections" => connections })) }
        }

    ///
    /// POST /jobs/tick。トークンが設定されていなければ 404（存在を見せない）、違えば 403、合えば 1 周回して失敗の説明を返す。
    ///
    def jobsTick(jobsToken: Option[String], routeRequest: RouteRequest): HttpResponse \ Health =
        let given = Http.findHeader("X-Jobs-Token", routeRequest#request#headers);
        match jobsToken {
            case None => errorResponse(404, Nil, "not found")
            case Some(expected) =>
                if (given != Some(expected)) errorResponse(403, Nil, "X-Jobs-Token が違います")
                else {
                    let failures = Health.runJobs();
                    { status = if (List.isEmpty(failures)) 200 else 500, headers = Nil,
                      body = JsonValue.toJsonString(Value.Obj(Map#{ "status" => Value.Str(if (List.isEmpty(failures)) "ok" else "error"), "failures" => Value.List(failures |> List.map(Value.Str)) })) }
                }
        }

    ///
    /// POST の JSON ボディを GraphqlRequest に読んで実行する。Content-Type が JSON でなければ 415、壊れた JSON・形の違うボディは 400。
    ///
    def executeBody(routeRequest: RouteRequest): HttpResponse \ Graphql =
        if (not isJson(routeRequest#request)) errorResponse(415, Nil, "Content-Type: application/json で送ってください")
        else match JsonValue.parse(routeRequest#request#body) |> Result.mapErr(message -> "invalid JSON: ${message}") |> Result.flatMap(toRequest) {
            case Ok(request)  => { status = 200, headers = Nil, body = JsonValue.toJsonString(toValue(Graphql.execute(request, Context.withCredential(routeRequest#credential)))) }
            case Err(message) => errorResponse(400, Nil, message)
        }

    ///
    /// GET のクエリ文字列を実行する。query が無ければ 400、mutation / subscription なら 405（GET は読むだけ）。
    /// 身元無し（鍵もトークンも無い）で errors が無ければ Cache-Control を public にして CDN に乗せ、それ以外は no-store。
    ///
    /// WhyNot: 身元付きの応答をキャッシュしないのは、鍵ごとに違う中身（下書き、非公開プロジェクト）が共有キャッシュから他人に出るため。
    /// Vary で鍵のヘッダを指しても、鍵の値ごとに溜まる事自体を避ける。
    ///
    def executeQueryString(cacheMaxAge: Option[Int32], routeRequest: RouteRequest): HttpResponse \ Graphql =
        let credential = routeRequest#credential;
        let params = Http.parseQueryString(routeRequest#request#path);
        let parsed = forM (
            queryText <- Map.get("query", params) |> Option.filter(text -> not String.isEmpty(text)) |> Option.toOk("query パラメータが要ります（?query=...）");
            variables <- Map.get("variables", params) |> Option.filter(text -> not String.isEmpty(text))
                |> Option.map(text -> JsonValue.parse(text) |> Result.mapErr(message -> "variables が JSON ではありません: ${message}") |> Result.flatMap(toVariables))
                |> Option.getWithDefault(Ok(Map.empty()))
        ) yield { queryText = queryText, variables = variables, operationName = Map.get("operationName", params) |> Option.filter(text -> not String.isEmpty(text)) };
        match parsed {
            case Err(message) => errorResponse(400, Nil, message)
            case Ok(graphqlRequest) =>
                if (not isReadOnly(graphqlRequest#queryText)) errorResponse(405, ("Allow", "POST") :: Nil, "GET は query だけです。mutation は POST で送ってください")
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
