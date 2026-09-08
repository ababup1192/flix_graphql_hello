///
/// CMS の値をログの属性（Log.Fields）に写す。キーは docs/logging.md の一覧（scripts/check-log-keys.sh が見張る）。
/// 生の鍵・トークン・email・URL のクエリは写さない。
///
/// WhyNot: trait（Loggable）にしないのは、Flix の instance は型の隣にしか置けず、ドメインの型に Log を知らせる事になるため。
/// 写す型が 3 つを超えたら trait にして instance は型の隣に置く。
///
mod LogFields {

    use Log.Fields
    use Log.Severity
    use CmsErr.CmsFailure
    use DbError.DbErrorKind
    use DbError.Failure
    use DbError.TransientKind

    // ---- リクエスト ----

    ///
    /// リクエストの span。全行に付く。url.path はクエリと制御文字を落とした物、cf.ray は Cloudflare を通った時だけ。
    ///
    pub def request(requestId: String, request: HttpRequest): Fields =
        Fields.empty()
            |> Fields.str("request.id", requestId)
            |> Fields.opt("cf.ray", Http.findHeader("CF-Ray", request#headers) |> Option.flatMap(RequestId.accept))
            |> Fields.str("http.request.method", request#method)
            |> Fields.str("url.path", HttpServer.sanitizePath(request#path))

    ///
    /// 身元の種類。生の値は出さない。
    ///
    pub def credentialKind(credential: Credential): String = match credential {
        case Credential.Bearer(_, _, _, _) => "jwt"
        case Credential.ApiKey(_)          => "api-key"
        case Credential.PersonalToken(_)   => "pat"
        case Credential.Preview(_)         => "preview"
        case Credential.Missing            => "anonymous"
        case Credential.Invalid(_)         => "invalid"
    }

    ///
    /// 本人の印。user.id は public_id（email は出さない）。
    ///
    pub def user(found: User, fields: Fields): Fields =
        fields |> Fields.str("user.id", found#publicId)

    ///
    /// API キーの印。鍵の名前だけ。
    ///
    pub def apiKey(name: String, fields: Fields): Fields =
        fields |> Fields.str("api_key.name", name)

    ///
    /// 付いていた鍵・トークンが検証に落ちた印。Runner が決めた後の身元の種類で、ヘッダから読んだ種類を上書きする。
    ///
    pub def rejectedCredential(fields: Fields): Fields =
        fields |> Fields.str("credential.kind", "invalid")

    ///
    /// 応答の行。ステータス・所要時間・ボディの大きさ。
    ///
    pub def response(status: Int32, elapsedMs: Int64, requestBytes: Int64, responseBytes: Int64, fields: Fields): Fields =
        fields
            |> Fields.int("http.response.status_code", Int32.toInt64(status))
            |> Fields.int("duration_ms", elapsedMs)
            |> Fields.int("http.request.body.size", requestBytes)
            |> Fields.int("http.response.body.size", responseBytes)

    ///
    /// リクエストの行の重さ。5xx か例外は Error、401 / 403 / 503 は Warn、/health の 2xx は Debug、それ以外は Info。
    /// 認証に落ちた物（`credential.kind` が invalid、`graphql.error_codes` に UNAUTHENTICATED）は HTTP が 200 でも Warn。
    ///
    pub def responseSeverity(path: String, status: Int32, failed: Bool, fields: Fields): Severity =
        if (failed or status >= 500 and status != 503) Severity.Error
        else if (status == 401 or status == 403 or status == 503) Severity.Warn
        else if (authenticationFailed(fields)) Severity.Warn
        else if (status < 300 and String.endsWith(suffix = "/health", path)) Severity.Debug
        else Severity.Info

    def authenticationFailed(fields: Fields): Bool =
        Map.get("credential.kind", fields) |> Option.flatMap(Value.asStr) == Some("invalid")
            or (Map.get("graphql.error_codes", fields) |> Option.map(codes -> hasCode("UNAUTHENTICATED", codes)) |> Option.getWithDefault(false))

    def hasCode(code: String, codes: Value): Bool = match codes {
        case Value.List(items) => List.exists(item -> Value.asStr(item) == Some(code), items)
        case _                 => false
    }

    // ---- 4xx の理由 ----

    ///
    /// 4xx を返す理由。error.code は短い固定の語（集計用）、error.message は応答本文に入れた文。
    ///
    pub def rejection(code: String, message: String, fields: Fields): Fields =
        fields |> Fields.str("error.code", code) |> Fields.str("error.message", message)

    ///
    /// 断った Origin。scheme + host だけ（パスやクエリは無い。制御文字は落とす）。
    ///
    pub def origin(value: String, fields: Fields): Fields =
        fields |> Fields.str("origin", originHost(value))

    /// "https://admin.example.com/x?y" → "https://admin.example.com"。
    def originHost(value: String): String =
        let cleaned = String.replaceMatches(regex = "\\p{Cntrl}", to = "", value);
        let (scheme, rest) = match String.indexOf(substr = "://", cleaned) {
            case Some(index) => (String.takeLeft(index + 3, cleaned), String.dropLeft(index + 3, cleaned))
            case None        => ("", cleaned)
        };
        scheme + String.takeWhile(ch -> ch != '/' and ch != '?' and ch != '#', rest)

    // ---- MCP ----

    ///
    /// tools/call の属性。ツール名・結果・entry の id（引数か結果の物）、isError なら content の code を error.code に。引数は残さない。
    ///
    pub def mcp(summary: McpServer.CallSummary, fields: Fields): Fields =
        fields
            |> Fields.str("mcp.tool", summary#tool)
            |> Fields.str("mcp.outcome", if (summary#isError) "error" else "ok")
            |> Fields.opt("id", summary#id)
            |> Fields.opt("error.code", summary#errorCode)

    // ---- GraphQL ----

    ///
    /// GraphQL の境界の属性。操作の種類と名前、errors[].extensions.code の一覧（無ければ付けない）。
    ///
    pub def graphql(request: GraphqlRequest, response: GraphqlResponse, fields: Fields): Fields =
        let (operationType, operationName) = Server.operationOf(request#queryText, request#operationName);
        let codes = response#errors |> List.filterMap(errorCodeOf) |> List.distinct;
        fields
            |> Fields.str("graphql.operation.type", operationType)
            |> Fields.opt("graphql.operation.name", operationName)
            |> (found -> if (List.isEmpty(codes)) found else Fields.strs("graphql.error_codes", codes, found))

    ///
    /// errors[] の 1 つの分類。業務エラーは extensions.code、graphql-java の検証エラーは extensions.classification。どちらも無ければ None。
    ///
    def errorCodeOf(error: Value): Option[String] =
        Value.path(List#{"extensions", "code"}, error) |> Value.asStr
            |> Option.withDefault(default = Value.path(List#{"extensions", "classification"}, error) |> Value.asStr)

    // ---- 業務エラー ----

    ///
    /// 業務エラーの属性。error.code は GraphQL の extensions.code と同じ文字列、notFound / conflict は entity と id も。
    ///
    pub def failure(found: CmsFailure, fields: Fields): Fields =
        let withCode = fields |> Fields.str("error.code", ErrorCode.text(GraphqlErrors.codeOf(found)));
        match found {
            case CmsFailure.NotFound(entity, id)       => withCode |> Fields.str("entity", GraphqlErrors.entityName(entity)) |> Fields.str("id", id)
            case CmsFailure.Conflict(entity, id, _, _) => withCode |> Fields.str("entity", GraphqlErrors.entityName(entity)) |> Fields.str("id", id)
            case CmsFailure.Invalid(_)                 => withCode
            case CmsFailure.Forbidden(_)               => withCode
            case CmsFailure.RequiresLogin(_)           => withCode
        }

    // ---- DB の失敗 ----

    ///
    /// DB の失敗の種類。sqlfx の TransientDbErr の名前（`deadlock` / `timeout` / `connectionLost`）だけを返し、
    /// それ以外（制約違反・schemaMismatch など）は None。再試行で枯渇した物は最後の失敗の種類を返す。
    /// 「DB が落ちた（connectionLost）」と「DB が遅い（timeout）」をログで読み分けるためのキー。
    ///
    /// WhyNot: `DbError.describe` の文言を読まないのは、sqlfx が文言を変えた時にキーの値が黙って消えるため。
    /// 値の綴りはここで決める（docs/logging.md の一覧と同じ）。
    ///
    pub def dbErrorKind(failure: Failure): Option[String] = match failure {
        case Failure.Transient(transient)                              => Some(transientName(transient))
        case Failure.Permanent(DbErrorKind.Transient(transient))       => Some(transientName(transient))
        case Failure.Permanent(DbErrorKind.RetryExhausted(last, _))    => Some(transientName(last))
        case Failure.Permanent(_)                                      => None
    }

    /// 一時的な失敗の種類の名前。
    def transientName(transient: TransientKind): String = match transient {
        case TransientKind.Deadlock          => "deadlock"
        case TransientKind.Timeout(_)        => "timeout"
        case TransientKind.ConnectionLost(_) => "connectionLost"
    }

    ///
    /// span から request.id を読む（INTERNAL の extensions.requestId に）。
    ///
    pub def requestIdOf(fields: Fields): Option[String] =
        Map.get("request.id", fields) |> Option.flatMap(Value.asStr)

}
