///
/// サーバの設定。
///
/// - cors: 許すオリジン
/// - graphqlPath: GraphQL を受けるパス（"/graphql" か "/admin/graphql"）
///
pub type alias ServerConfig = { cors = CorsConfig, graphqlPath = String }

///
/// HTTP リクエストを GraphQL の実行と死活監視に橋渡しするルーティング。
/// ソケットも graphql-java も JDBC も触らず、`Graphql` と `Health` の effect だけに依存する。
///
mod Server {

    ///
    /// CORS 無しの設定。テストと、同一オリジンだけで使うとき。
    ///
    pub def defaultConfig(): ServerConfig = { cors = Cors.none(), graphqlPath = "/graphql" }

    ///
    /// リクエストを 1 つ処理する。
    /// - POST <graphqlPath>: ボディ {"query": "...", "variables": {...}, "operationName": "..."} を実行して {"data": ..., "errors": [...]} を返す
    /// - GET /health: DB に届けば 200、届かなければ 503
    /// - OPTIONS: CORS の preflight
    /// パスのクエリ文字列は無視する。許したオリジンからのリクエストには CORS ヘッダを足す。
    /// リクエストヘッダは Origin 以外まだ見ない。
    ///
    pub def handle(config: ServerConfig, request: HttpRequest): HttpResponse \ {Graphql, Health} =
        route(config, request) |> Cors.withHeaders(config#cors, request)

    ///
    /// メソッドとパスで振り分ける。
    ///
    def route(config: ServerConfig, request: HttpRequest): HttpResponse \ {Graphql, Health} =
        match (request#method, pathOf(request#path)) {
            case ("OPTIONS", path) if path == config#graphqlPath or path == "/health" => Cors.preflight(config#cors, request)
            case ("POST", path) if path == config#graphqlPath => executeBody(request#body)
            case (_, path) if path == config#graphqlPath      => errorResponse(405, ("Allow", "POST") :: Nil, "POST only")
            case ("GET", "/health")   => health()
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
    /// パスからクエリ文字列を落とす（"/health?probe=1" → "/health"）。
    ///
    def pathOf(path: String): String =
        String.splitOn(substr = "?", path) |> List.head |> Option.getWithDefault(path)

    ///
    /// GET /health。DB に届けば {"status": "ok"}、届かなければ 503 で理由を付ける。
    ///
    def health(): HttpResponse \ Health =
        match Health.checkDb() {
            case Ok(())       => { status = 200, headers = Nil, body = JsonValue.toJsonString(Value.Obj(Map#{ "status" => Value.Str("ok") })) }
            case Err(message) => { status = 503, headers = Nil, body = JsonValue.toJsonString(Value.Obj(Map#{ "status" => Value.Str("error"), "db" => Value.Str(message) })) }
        }

    ///
    /// JSON ボディを GraphqlRequest に読んで実行する。壊れた JSON・形の違うボディは 400。
    ///
    def executeBody(body: String): HttpResponse \ Graphql =
        match JsonValue.parse(body) |> Result.mapErr(message -> "invalid JSON: ${message}") |> Result.flatMap(toRequest) {
            case Ok(request)  => { status = 200, headers = Nil, body = JsonValue.toJsonString(toValue(Graphql.execute(request, Context.anonymous()))) }
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
