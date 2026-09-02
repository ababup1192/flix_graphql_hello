///
/// HTTP リクエストを GraphQL の実行に橋渡しするルーティング。
/// ソケットも graphql-java も触らず、`Graphql` effect だけに依存する。
///
mod Server {

    ///
    /// リクエストを 1 つ処理する。
    /// POST /graphql にボディ {"query": "...", "variables": {...}, "operationName": "..."} を受け取り、
    /// {"data": ..., "errors": [...]} を返す。リクエストヘッダは今は見ない。
    ///
    pub def handle(request: HttpRequest): HttpResponse \ Graphql =
        match (request#method, request#path) {
            case ("POST", "/graphql") => executeBody(request#body)
            case (_, "/graphql")      => errorResponse(405, ("Allow", "POST") :: Nil, "POST only")
            case _                    => errorResponse(404, Nil, "not found")
        }

    ///
    /// JSON ボディを GraphqlRequest に読んで実行する。壊れた JSON・形の違うボディは 400。
    ///
    def executeBody(body: String): HttpResponse \ Graphql =
        match JsonValue.parse(body) |> Result.mapErr(message -> "invalid JSON: ${message}") |> Result.flatMap(toRequest) {
            case Ok(request)  => { status = 200, headers = Nil, body = JsonValue.toJsonString(toValue(Graphql.execute(request))) }
            case Err(message) => errorResponse(400, Nil, message)
        }

    ///
    /// ボディの Value を GraphqlRequest に組み立てる。
    /// query は必須の文字列。variables は省略可能なオブジェクト（省略時は空）。operationName は省略可能な文字列。
    ///
    pub def toRequest(body: Value): Result[String, GraphqlRequest] =
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
    pub def toValue(response: GraphqlResponse): Value =
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
