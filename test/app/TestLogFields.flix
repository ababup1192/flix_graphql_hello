///
/// LogFields: CMS の値をログの属性に写す規則。リクエストの span、身元の種類、応答の重さ、GraphQL の境界、業務エラー。
///
mod TestLogFields {

    use Log.Fields
    use Log.Severity
    use CmsErr.CmsFailure
    use DbError.DbErrorKind
    use DbError.Failure
    use DbError.TransientKind

    /// ヘッダ付きの GET。
    def get(path: String, headers: List[(String, String)]): HttpRequest =
        { version = "HTTP/1.1", method = "GET", path = path, headers = headers, body = "" }

    /// GraphQL のリクエスト。
    def graphqlRequest(queryText: String, operationName: Option[String]): GraphqlRequest =
        { queryText = queryText, variables = Map.empty(), operationName = operationName }

    /// extensions 付きのエラー。
    def errorWith(extensions: Map[String, Value]): Value =
        Value.Obj(Map#{ "message" => Value.Str("x"), "extensions" => Value.Obj(extensions) })

    // ---- リクエストの span ----

    /// request.id と method と、クエリと制御文字を落としたパス。CF-Ray はあれば cf.ray（形が合わなければ無し）。
    @Test
    def testRequestSpanTable(): Unit \ Assert =
        let cases = List#{
            (get("/graphql?token=secret", Nil),
             List#{("http.request.method", Value.Str("GET")), ("request.id", Value.Str("rid")), ("url.path", Value.Str("/graphql"))}),
            (get("/health\n{\"fake\":1}", ("CF-Ray", "7d4b3c2a1f0e9d8c-NRT") :: Nil),
             List#{("cf.ray", Value.Str("7d4b3c2a1f0e9d8c-NRT")), ("http.request.method", Value.Str("GET")), ("request.id", Value.Str("rid")), ("url.path", Value.Str("/health{\"fake\":1}"))}),
            (get("/", ("cf-ray", "a b") :: Nil),
             List#{("http.request.method", Value.Str("GET")), ("request.id", Value.Str("rid")), ("url.path", Value.Str("/"))})
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (request, _) -> LogFields.request("rid", request) |> Map.toList))

    /// 身元の種類。生の値（トークン・鍵・email）は入らない。
    @Test
    def testCredentialKindTable(): Unit \ Assert =
        let cases = List#{
            (Credential.Bearer("iss", "sub", "a@example.com", "A"), "jwt"),
            (Credential.ApiKey("cms_secret"),                       "api-key"),
            (Credential.PersonalToken("cmspat_secret"),             "pat"),
            (Credential.Preview("pv_secret"),                       "preview"),
            (Credential.Missing,                                    "anonymous"),
            (Credential.Invalid("expired"),                         "invalid")
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (credential, _) -> LogFields.credentialKind(credential)))

    /// 本人は public_id だけ（email は出ない）、鍵は名前だけ。
    @Test
    def testUserAndApiKeyFields(): Unit \ Assert =
        let user = { id = UserId.UserId(1i64), publicId = "pub-1", issuer = "iss", subject = "sub", email = "a@example.com", name = "A" };
        Assert.assertEq(
            expected = List#{("api_key.name", Value.Str("ci")), ("user.id", Value.Str("pub-1"))},
            Fields.empty() |> LogFields.user(user) |> LogFields.apiKey("ci") |> Map.toList)

    // ---- 応答の行 ----

    /// ステータス・所要時間・ボディの大きさが OTel の名前で付く。
    @Test
    def testResponseFields(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{("duration_ms", Value.Int(12)), ("http.request.body.size", Value.Int(3)), ("http.response.body.size", Value.Int(34)), ("http.response.status_code", Value.Int(200))},
            Fields.empty() |> LogFields.response(200, 12i64, 3i64, 34i64) |> Map.toList)

    /// 重さ: 2xx / 4xx は Info、401 / 403 / 503 は Warn、5xx と例外は Error、/health の 2xx だけ Debug（/p/x/health も）。
    /// 200 でも credential.kind が invalid か graphql.error_codes に UNAUTHENTICATED があれば Warn（FORBIDDEN だけ・生きた鍵は Info）。
    @Test
    def testResponseSeverityTable(): Unit \ Assert =
        let none = Fields.empty();
        let cases = List#{
            (("/graphql", 200, false, none),      Severity.Info),
            (("/graphql", 404, false, none),      Severity.Info),
            (("/graphql", 400, false, none),      Severity.Info),
            (("/admin/graphql", 401, false, none), Severity.Warn),
            (("/admin/graphql", 403, false, none), Severity.Warn),
            (("/graphql", 503, false, none),      Severity.Warn),
            (("/graphql", 500, false, none),      Severity.Error),
            (("/graphql", 200, true, none),       Severity.Error),
            (("/health", 200, false, none),       Severity.Debug),
            (("/p/shop/health", 200, false, none), Severity.Debug),
            (("/health", 503, false, none),       Severity.Warn),
            (("-", 400, false, none),             Severity.Info),
            (("/admin/graphql", 200, false, none |> Fields.str("credential.kind", "invalid")),                        Severity.Warn),
            (("/admin/graphql", 200, false, none |> Fields.strs("graphql.error_codes", List#{"UNAUTHENTICATED"})),     Severity.Warn),
            (("/admin/graphql", 200, false, none |> Fields.strs("graphql.error_codes", List#{"FORBIDDEN"})),           Severity.Info),
            (("/admin/graphql", 200, false, none |> Fields.str("credential.kind", "api-key")),                        Severity.Info)
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match ((path, status, failed, fields), _) -> LogFields.responseSeverity(path, status, failed, fields)))

    /// 検証に落ちた印は credential.kind を invalid にする（ヘッダから読んだ種類を上書き）。
    @Test
    def testRejectedCredential(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{("credential.kind", Value.Str("invalid"))},
            Fields.empty() |> Fields.str("credential.kind", "api-key") |> LogFields.rejectedCredential |> Map.toList)

    /// 認証に落ちた 401 の行の error.code は GraphQL の extensions.code と同じ綴り（小文字の unauthenticated ではない）。
    @Test
    def testRejectedAuthTable(): Unit \ Assert =
        let cases = List#{
            (Rejection.Invalid("JWT は無し"),                 ("UNAUTHENTICATED", "認証に失敗しました: JWT は無し")),
            (Rejection.DeadToken(PatRejection.Revoked),     ("UNAUTHENTICATED", "認証に失敗しました: PAT は失効しています")),
            (Rejection.NotForAccount("API キー"),           ("REQUIRES_LOGIN", "Account API は API キーでは使えません。ログインしてください")),
            (Rejection.PrivateProject,                      ("UNAUTHENTICATED", "このプロジェクトは非公開です。API キーを X-Api-Key で渡してください")),
            (Rejection.NotMember,                           ("FORBIDDEN", "このプロジェクトのメンバーではありません"))
        };
        Assert.assertEq(
            expected = cases |> List.map(match (_, (code, message)) -> List#{("error.code", Value.Str(code)), ("error.message", Value.Str(message))}),
            cases |> List.map(match (rejection, _) -> Fields.empty() |> LogFields.rejectedAuth(rejection) |> Map.toList))

    // ---- 4xx の理由と MCP ----

    /// 4xx の理由は error.code と error.message。
    @Test
    def testRejection(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{("error.code", Value.Str("no_route")), ("error.message", Value.Str("not found"))},
            Fields.empty() |> LogFields.rejection("no_route", "not found") |> Map.toList)

    /// 断った Origin は scheme + host だけ（パス・クエリ・fragment・制御文字は落ちる）。
    @Test
    def testOriginTable(): Unit \ Assert =
        let cases = List#{
            ("https://evil.example.com",             "https://evil.example.com"),
            ("https://evil.example.com/path?q=1#f",  "https://evil.example.com"),
            ("http://localhost:3000/",               "http://localhost:3000"),
            ("null",                                 "null"),
            ("https://a.example.com\n{\"fake\":1}",  "https://a.example.com{\"fake\":1}")
        };
        Assert.assertEq(expected = cases |> List.map(snd),
            cases |> List.map(match (value, _) -> Fields.empty() |> LogFields.origin(value) |> Map.get("origin") |> Option.flatMap(Value.asStr) |> Option.getWithDefault("")))

    /// tools/call の属性: mcp.tool / mcp.outcome、id と error.code はあれば。
    @Test
    def testMcpTable(): Unit \ Assert =
        let cases = List#{
            ({ tool = "whoami", id = None, isError = false, errorCode = None },
             List#{("mcp.outcome", Value.Str("ok")), ("mcp.tool", Value.Str("whoami"))}),
            ({ tool = "publish", id = Some("e1"), isError = true, errorCode = Some("INVALID") },
             List#{("error.code", Value.Str("INVALID")), ("id", Value.Str("e1")), ("mcp.outcome", Value.Str("error")), ("mcp.tool", Value.Str("publish"))})
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (summary, _) -> Fields.empty() |> LogFields.mcp(summary) |> Map.toList))

    // ---- GraphQL の境界 ----

    /// 操作の種類と名前。名前は operationName が勝ち、無ければ文書から、それも無ければ付かない。
    @Test
    def testGraphqlOperationTable(): Unit \ Assert =
        let noErrors: GraphqlResponse = { data = Value.Null, errors = Nil };
        let cases = List#{
            (graphqlRequest("{ x }", None),                                   List#{("graphql.operation.type", Value.Str("query"))}),
            (graphqlRequest("query Q($a: Int!) { x(a: $a) }", None),         List#{("graphql.operation.name", Value.Str("Q")), ("graphql.operation.type", Value.Str("query"))}),
            (graphqlRequest("mutation { publish }", None),                     List#{("graphql.operation.type", Value.Str("mutation"))}),
            (graphqlRequest("mutation M { publish } query Q { x }", Some("Q")), List#{("graphql.operation.name", Value.Str("Q")), ("graphql.operation.type", Value.Str("query"))}),
            (graphqlRequest("fragment F on T { a } { ...F }", None),          List#{("graphql.operation.type", Value.Str("query"))}),
            (graphqlRequest("subscription S { x }", None),                    List#{("graphql.operation.name", Value.Str("S")), ("graphql.operation.type", Value.Str("subscription"))})
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (request, _) -> Fields.empty() |> LogFields.graphql(request, noErrors) |> Map.toList))

    /// errors[] の extensions.code を重複無しで並べる。code の無い graphql-java の検証エラーは classification、どちらも無い物は数えない。
    @Test
    def testGraphqlErrorCodes(): Unit \ Assert =
        let response: GraphqlResponse = { data = Value.Null, errors = List#{
            errorWith(Map#{ "code" => Value.Str("NOT_FOUND") }),
            errorWith(Map#{ "code" => Value.Str("NOT_FOUND") }),
            errorWith(Map#{ "code" => Value.Str("FORBIDDEN"), "entity" => Value.Str("Entry") }),
            errorWith(Map#{ "classification" => Value.Str("ValidationError") }),
            Value.Obj(Map#{ "message" => Value.Str("no extensions") }) } };
        Assert.assertEq(
            expected = Some(Value.List(List#{Value.Str("NOT_FOUND"), Value.Str("FORBIDDEN"), Value.Str("ValidationError")})),
            Fields.empty() |> LogFields.graphql(graphqlRequest("{ x }", None), response) |> Map.get("graphql.error_codes"))

    // ---- 業務エラー ----

    /// error.code は GraphQL の extensions.code と同じ綴り。notFound / conflict は entity と id も付く。
    @Test
    def testFailureTable(): Unit \ Assert =
        let cases = List#{
            (CmsFailure.NotFound(Entity.Entry, "e1"),                        List#{("entity", Value.Str("Entry")), ("error.code", Value.Str("NOT_FOUND")), ("id", Value.Str("e1"))}),
            (CmsFailure.Conflict(Entity.Entry, "e1", 1, 3),                  List#{("entity", Value.Str("Entry")), ("error.code", Value.Str("CONFLICT")), ("id", Value.Str("e1"))}),
            (CmsFailure.Invalid(Violation.Violation("apiId", "x") :: Nil),   List#{("error.code", Value.Str("INVALID"))}),
            (CmsFailure.Forbidden(Permission.ManageTypes),                   List#{("error.code", Value.Str("FORBIDDEN"))}),
            (CmsFailure.RequiresLogin(LoginRequirement.Interactive),         List#{("error.code", Value.Str("REQUIRES_LOGIN"))})
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (failure, _) -> Fields.empty() |> LogFields.failure(failure) |> Map.toList))

    /// DB の失敗の種類。TransientDbErr の 3 つと COMMIT が弾かれた rollback に名前が付き、再試行で枯渇した物は最後の失敗の種類。制約違反などは None。
    @Test
    def testDbErrorKindTable(): Unit \ Assert =
        let cases = List#{
            (Failure.Transient(TransientKind.Deadlock),                                                       Some("deadlock")),
            (Failure.Transient(TransientKind.Timeout(0)),                                                     Some("timeout")),
            (Failure.Transient(TransientKind.ConnectionLost("no route")),                                     Some("connectionLost")),
            (Failure.Permanent(DbErrorKind.RetryExhausted(TransientKind.Timeout(0), 3)),                      Some("timeout")),
            (Failure.Permanent(DbErrorKind.RetryExhausted(TransientKind.ConnectionLost("x"), 3)),             Some("connectionLost")),
            (Failure.Permanent(DbErrorKind.Transient(TransientKind.Deadlock)),                                Some("deadlock")),
            (Failure.Permanent(DbErrorKind.UniqueViolation("entries_pkey")),                                  None),
            (Failure.Permanent(DbErrorKind.SchemaMismatch("no column")),                                      None),
            (Failure.Permanent(DbErrorKind.Rollback),                                                         Some("rollback")),
            (Failure.Permanent(DbErrorKind.Other("")),                                                        None)
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (failure, _) -> LogFields.dbErrorKind(failure)))

    /// span から request.id を読む。無ければ None。
    @Test
    def testRequestIdOf(): Unit \ Assert =
        Assert.assertEq(
            expected = (Some("rid"), None),
            (LogFields.requestIdOf(Fields.empty() |> Fields.str("request.id", "rid")), LogFields.requestIdOf(Fields.empty())))

    /// observe で戻った属性の合わせ方。数えるキー（db.statements / db.transactions / db.retries）は和、それ以外は後から来た物が勝つ。無かったキーはそのまま入る。
    @Test
    def testMergeCountsSumsCountedKeys(): Unit \ Assert =
        let existing = Fields.empty() |> Fields.int("db.statements", 7i64) |> Fields.int("db.transactions", 1i64) |> Fields.str("credential.kind", "jwt");
        let incoming = Fields.empty() |> Fields.int("db.statements", 3i64) |> Fields.int("db.transactions", 1i64) |> Fields.int("db.retries", 1i64) |> Fields.str("credential.kind", "invalid");
        Assert.assertEq(
            expected = Fields.empty() |> Fields.int("db.statements", 10i64) |> Fields.int("db.transactions", 2i64) |> Fields.int("db.retries", 1i64) |> Fields.str("credential.kind", "invalid"),
            LogFields.mergeCounts(incoming, existing))

}
