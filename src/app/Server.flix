///
/// サーバの設定。
///
/// - cors: 許すオリジン
/// - graphqlPath: GraphQL を受けるパス（"/graphql" か "/admin/graphql"）
/// - version: /health に出す版（イメージの git の sha など）
///
pub type alias ServerConfig = { cors = CorsConfig, graphqlPath = String, version = String }

///
/// HTTP リクエストを GraphQL の実行と死活監視に橋渡しするルーティング。
/// ソケットも graphql-java も JDBC も触らず、`Graphql` と `Health` の effect だけに依存する。
///
mod Server {

    ///
    /// CORS 無しの設定。テストと、同一オリジンだけで使うとき。
    ///
    pub def defaultConfig(): ServerConfig = { cors = Cors.none(), graphqlPath = "/graphql", version = "dev" }

    ///
    /// リクエストを 1 つ処理する。
    /// - POST <graphqlPath>: ボディ {"query": "...", "variables": {...}, "operationName": "..."} を実行して {"data": ..., "errors": [...]} を返す
    /// - GET /health: DB に届けば 200、届かなければ 503
    /// - OPTIONS: CORS の preflight
    /// パスのクエリ文字列は無視する。許したオリジンからのリクエストには CORS ヘッダを足す。
    /// リクエストヘッダは Origin 以外まだ見ない。
    ///
    pub def handle(config: ServerConfig, credential: Credential, request: HttpRequest): HttpResponse \ {Graphql, Health} =
        route(config, credential, request) |> Cors.withHeaders(config#cors, request)

    ///
    /// メソッドとパスで振り分ける。
    ///
    def route(config: ServerConfig, credential: Credential, request: HttpRequest): HttpResponse \ {Graphql, Health} =
        match (request#method, pathOf(request#path)) {
            case ("OPTIONS", path) if path == config#graphqlPath or path == "/health" => Cors.preflight(config#cors, request)
            case ("POST", path) if path == config#graphqlPath =>
                if (isJson(request)) executeBody(credential, request#body) else errorResponse(415, Nil, "Content-Type: application/json で送ってください")
            case (_, path) if path == config#graphqlPath      => errorResponse(405, ("Allow", "POST") :: Nil, "POST only")
            case ("GET", "/health")   => health(config#version)
            case (_, "/health")       => errorResponse(405, ("Allow", "GET") :: Nil, "GET only")
            case _                    => errorResponse(404, Nil, "not found")
        }

    ///
    /// このリクエストが config の GraphQL を実行するか（POST でそのパス宛。クエリ文字列は無視）。
    /// どのエンジンで受けるかの振り分けに使う。preflight や GET はエンジンを要らない（405 / 204 を返すだけ）。
    ///
    pub def needsGraphqlEngine(config: ServerConfig, request: HttpRequest): Bool =
        request#method == "POST" and pathOf(request#path) == config#graphqlPath

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
    /// パスの先頭の /p/{slug} を切り出す。"/p/shop/graphql" → (Some("shop"), "/graphql")。無ければ (None, そのまま)。
    /// slug の無い "/p" や "/p/" は切り出さない（404 に落ちる）。
    ///
    pub def splitProject(path: String): (Option[String], String) =
        match String.splitOn(substr = "/", path) {
            case "" :: "p" :: slug :: rest if slug != "" => (Some(slug), "/" + List.join("/", rest))
            case _                                       => (None, path)
        }

    ///
    /// Content-Type が application/json か（大文字小文字と charset は問わない）。
    ///
    /// WhyNot: Content-Type を見ずに本文を実行しないのは、Cookie で認証する時に他サイトの form から text/plain で
    /// POST されると preflight 無しで届き、被害者の Cookie 付きで mutation が通る（CSRF）ため。JSON を要求すれば必ず preflight が走る。
    ///
    pub def isJson(request: HttpRequest): Bool =
        request#headers
            |> List.find(match (name, _) -> String.toLowerCase(name) == "content-type")
            |> Option.map(match (_, value) -> String.startsWith(prefix = "application/json", String.toLowerCase(String.trim(value))))
            |> Option.getWithDefault(false)

    ///
    /// Host ヘッダから slug を取る。`{slug}.{baseDomain}` の形の時だけ Some。ポートは無視する。
    /// baseDomain が無い（CMS_BASE_DOMAIN 未設定）なら常に None で、/p/{slug}/ だけが効く。
    ///
    pub def slugFromHost(baseDomain: Option[String], headers: List[(String, String)]): Option[String] =
        let host = headers
            |> List.find(match (name, _) -> String.toLowerCase(name) == "host")
            |> Option.map(match (_, value) -> value |> String.trim |> String.toLowerCase |> String.splitOn(substr = ":") |> List.head |> Option.getWithDefault(""));
        match (baseDomain |> Option.map(String.toLowerCase), host) {
            case (Some(base), Some(found)) if String.endsWith(suffix = ".${base}", found) =>
                let label = String.dropRight(String.length(base) + 1, found);
                if (String.isMatch(regex = "^[a-z0-9][a-z0-9-]{0,63}$", label)) Some(label) else None
            case _ => None
        }

    ///
    /// リクエストのプロジェクトの slug と、プロジェクトを除いたパス。/p/{slug}/ があればそれを優先し、無ければ Host から。
    ///
    pub def projectOf(baseDomain: Option[String], request: HttpRequest): (Option[String], String) =
        match splitProject(request#path) {
            case (Some(slug), rest) => (Some(slug), rest)
            case (None, rest)       => (slugFromHost(baseDomain, request#headers), rest)
        }

    ///
    /// パスからクエリ文字列を落とす（"/health?probe=1" → "/health"）。
    ///
    pub def pathOf(path: String): String =
        String.splitOn(substr = "?", path) |> List.head |> Option.getWithDefault(path)

    ///
    /// GET /health。DB に届けば {"status": "ok", "version": "..."}、届かなければ 503 で理由を付ける。
    ///
    def health(version: String): HttpResponse \ Health =
        match Health.checkDb() {
            case Ok(())       => { status = 200, headers = Nil, body = JsonValue.toJsonString(Value.Obj(Map#{ "status" => Value.Str("ok"), "version" => Value.Str(version) })) }
            case Err(message) => { status = 503, headers = Nil, body = JsonValue.toJsonString(Value.Obj(Map#{ "status" => Value.Str("error"), "version" => Value.Str(version), "db" => Value.Str(message) })) }
        }

    ///
    /// JSON ボディを GraphqlRequest に読んで実行する。壊れた JSON・形の違うボディは 400。
    ///
    def executeBody(credential: Credential, body: String): HttpResponse \ Graphql =
        match JsonValue.parse(body) |> Result.mapErr(message -> "invalid JSON: ${message}") |> Result.flatMap(toRequest) {
            case Ok(request)  => { status = 200, headers = Nil, body = JsonValue.toJsonString(toValue(Graphql.execute(request, Context.withCredential(credential)))) }
            case Err(message) => errorResponse(400, Nil, message)
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
