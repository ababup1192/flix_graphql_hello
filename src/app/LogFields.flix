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
    ///
    pub def responseSeverity(path: String, status: Int32, failed: Bool): Severity =
        if (failed or status >= 500 and status != 503) Severity.Error
        else if (status == 401 or status == 403 or status == 503) Severity.Warn
        else if (status < 300 and String.endsWith(suffix = "/health", path)) Severity.Debug
        else Severity.Info

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

    ///
    /// span から request.id を読む（INTERNAL の extensions.requestId に）。
    ///
    pub def requestIdOf(fields: Fields): Option[String] =
        Map.get("request.id", fields) |> Option.flatMap(Value.asStr)

}
