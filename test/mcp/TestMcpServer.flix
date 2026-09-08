///
/// McpServer: JSON-RPC の parse とエラーの表、initialize の応答の形、MCP-Protocol-Version の扱い、tools/list と tools/call の dispatch、
/// Origin の判定、ログ用のまとめ。GraphQL は偽の execute で、DB 無し。
///
mod TestMcpServer {

    def obj(pairs: List[(String, Value)]): Value = Value.Obj(List.toMap(pairs))

    /// id が 1 のリクエストの JSON。
    def requestJson(method: String, params: String): String =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}"

    /// 固定の data を返す execute。
    def fixed(data: Value): GraphqlRequest -> GraphqlResponse =
        _ -> { data = data, errors = Nil }

    /// parse して dispatch した応答の body。parse に落ちればその error body。
    def replyOf(body: String, execute: GraphqlRequest -> GraphqlResponse): McpServer.Reply =
        match McpServer.parse(body) {
            case Ok(message) => McpServer.dispatch("abc123", message, execute)
            case Err(errorBody) => McpServer.Reply.Body(errorBody)
        }

    /// Reply.Body の中身。それ以外はテストの前提が壊れている。
    def bodyOf(reply: McpServer.Reply): Value = match reply {
        case McpServer.Reply.Body(found) => found
        case other                       => bug!("Body ではありません: ${other}")
    }

    /// 配列の各要素の name。配列でなければテストの前提が壊れている。
    def namesOf(value: Value): Value = match value {
        case Value.List(items) => Value.List(items |> List.map(Value.field("name")))
        case other             => bug!("配列ではありません: ${other}")
    }

    /// content[0].text。content が 1 件の配列でなければテストの前提が壊れている。
    def contentText(result: Value): Value = match Value.field("content", result) {
        case Value.List(first :: Nil) => Value.field("text", first)
        case other                    => bug!("content が 1 件ではありません: ${other}")
    }

    /// error の code と message。
    def errorOf(reply: McpServer.Reply): (Value, Value) =
        let body = bodyOf(reply);
        (Value.path(List#{"error", "code"}, body), Value.path(List#{"error", "message"}, body))

    // ---- JSON-RPC の parse とエラーの表 ----

    /// 壊れた JSON は -32700、バッチ（配列）とオブジェクトでない物と method 無しは -32600、知らない method は -32601、
    /// params の形が壊れている（name 無し・知らないツール・引数の型違い）は -32602。id はリクエストの物を返し、parse に落ちた時は null。
    @Test
    def testProtocolErrors(): Unit \ Assert =
        let cases = List#{
            ("{", (Value.Int(-32700), Value.Null)),
            ("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]", (Value.Int(-32600), Value.Null)),
            ("\"ping\"", (Value.Int(-32600), Value.Null)),
            ("{\"jsonrpc\":\"2.0\",\"id\":7}", (Value.Int(-32600), Value.Int(7))),
            (requestJson("resources/list", "{}"), (Value.Int(-32601), Value.Int(1))),
            (requestJson("tools/call", "{}"), (Value.Int(-32602), Value.Int(1))),
            (requestJson("tools/call", "{\"name\":\"delete_everything\",\"arguments\":{}}"), (Value.Int(-32602), Value.Int(1))),
            (requestJson("tools/call", "{\"name\":\"get_entry\",\"arguments\":{}}"), (Value.Int(-32602), Value.Int(1))),
            (requestJson("tools/call", "{\"name\":\"get_entry\",\"arguments\":[]}"), (Value.Int(-32602), Value.Int(1))) };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (body, _) ->
                let reply = replyOf(body, fixed(Value.Null));
                (Value.path(List#{"error", "code"}, bodyOf(reply)), Value.field("id", bodyOf(reply)))))

    /// エラーの message は何が悪いかを言う（tools/call の params の誤りは引数の復号の文言をそのまま）。
    @Test
    def testProtocolErrorMessages(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                Value.Str("バッチは受け付けません（1 リクエストずつ送ってください）"),
                Value.Str("method not found: resources/list"),
                Value.Str("unknown tool: delete_everything"),
                Value.Str("引数 'id' が要ります") },
            List#{
                "[]",
                requestJson("resources/list", "{}"),
                requestJson("tools/call", "{\"name\":\"delete_everything\"}"),
                requestJson("tools/call", "{\"name\":\"get_entry\"}") }
                |> List.map(body -> replyOf(body, fixed(Value.Null)) |> errorOf |> snd))

    /// id は数でも文字列でも、そのまま応答に返る。
    @Test
    def testIdPassesThrough(): Unit \ Assert =
        Assert.assertEq(
            expected = (Value.Str("req-9"), Value.Str("2.0")),
            (Value.field("id", bodyOf(replyOf("{\"jsonrpc\":\"2.0\",\"id\":\"req-9\",\"method\":\"ping\"}", fixed(Value.Null)))),
             Value.field("jsonrpc", bodyOf(replyOf("{\"jsonrpc\":\"2.0\",\"id\":\"req-9\",\"method\":\"ping\"}", fixed(Value.Null))))))

    // ---- initialize / notifications / ping ----

    /// initialize は protocolVersion（クライアントの値を支持できればそれ、無理なら 2025-06-18）、capabilities.tools、serverInfo（name は cms、version は /health と同じ）を返す。
    @Test
    def testInitialize(): Unit \ Assert =
        let resultOf = requested -> Value.field("result", bodyOf(replyOf(requestJson("initialize", "{\"protocolVersion\":\"${requested}\",\"capabilities\":{},\"clientInfo\":{\"name\":\"x\",\"version\":\"0\"}}"), fixed(Value.Null))));
        Assert.assertEq(
            expected = List#{
                obj(List#{ ("protocolVersion", Value.Str("2025-03-26")), ("capabilities", obj(List#{ ("tools", obj(Nil)) })), ("serverInfo", obj(List#{ ("name", Value.Str("cms")), ("version", Value.Str("abc123")) })) }),
                obj(List#{ ("protocolVersion", Value.Str("2025-06-18")), ("capabilities", obj(List#{ ("tools", obj(Nil)) })), ("serverInfo", obj(List#{ ("name", Value.Str("cms")), ("version", Value.Str("abc123")) })) }) },
            List#{ resultOf("2025-03-26"), resultOf("2099-01-01") })

    /// 通知（id 無し）は Accepted（HTTP 202、body 無し）。method が何でも同じ。ping は空の result。
    @Test
    def testNotificationAndPing(): Unit \ Assert =
        let bodies = List#{
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{}}",
            requestJson("ping", "{}") };
        Assert.assertEq(
            expected = List#{
                McpServer.Reply.Accepted,
                McpServer.Reply.Accepted,
                McpServer.Reply.Body(obj(List#{ ("jsonrpc", Value.Str("2.0")), ("id", Value.Int(1)), ("result", obj(Nil)) })) },
            bodies |> List.map(body -> replyOf(body, fixed(Value.Null))))

    /// MCP-Protocol-Version: 無ければ 2025-03-26、知っている値はそれ、知らない値は Err（HTTP 400）。名前の大文字小文字は問わない。
    @Test
    def testProtocolVersionHeader(): Unit \ Assert =
        let cases = List#{
            (Nil, Ok("2025-03-26")),
            (("mcp-protocol-version", "2025-06-18") :: Nil, Ok("2025-06-18")),
            (("MCP-Protocol-Version", "2024-11-05") :: Nil, Ok("2024-11-05")),
            (("mcp-protocol-version", "2099-01-01") :: Nil, Err("2099-01-01")) };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (headers, _) -> McpServer.protocolVersionOf(headers)))

    // ---- tools/list と tools/call ----

    /// tools/list は McpTools の表をそのまま出す（名前の並びが同じ）。
    @Test
    def testToolsList(): Unit \ Assert =
        Assert.assertEq(
            expected = Value.List(Tool.all() |> List.map(tool -> Value.Str(Tool.name(tool)))),
            Value.path(List#{"result", "tools"}, bodyOf(replyOf(requestJson("tools/list", "{}"), fixed(Value.Null)))) |> namesOf)

    /// tools/call は復号した引数でツールを呼び、result に content と isError を返す。arguments を省いても引数の無いツールは通る。
    @Test
    def testToolsCall(): Unit \ Assert =
        let types = Value.List(obj(List#{ ("apiId", Value.Str("posts")) }) :: Nil);
        let reply = replyOf(requestJson("tools/call", "{\"name\":\"list_types\"}"), fixed(obj(List#{ ("contentTypes", types) })));
        let result = Value.field("result", bodyOf(reply));
        Assert.assertEq(
            expected = (Value.Str("[{\"apiId\":\"posts\"}]"), Value.Bool(false)),
            (contentText(result), Value.field("isError", result)))

    /// GraphQL が UNAUTHENTICATED を返したら Reply.Unauthenticated（HTTP 401 にする）で、body は id 付きの error。
    @Test
    def testUnauthenticatedReply(): Unit \ Assert =
        let dead = _ -> { data = Value.Null, errors = obj(List#{ ("message", Value.Str("認証に失敗しました: PAT は失効しています")), ("extensions", obj(List#{ ("code", Value.Str("UNAUTHENTICATED")) })) }) :: Nil };
        Assert.assertEq(
            expected = McpServer.Reply.Unauthenticated(McpServer.errorBody(Value.Int(1), -32600, "認証に失敗しました: PAT は失効しています")),
            replyOf(requestJson("tools/call", "{\"name\":\"list_types\"}"), dead))

    // ---- Origin とログ ----

    /// Origin: 無ければ通す、許した物は通す、それ以外は通さない。許可の一覧が空でも Origin 付きは通さない。
    @Test
    def testOrigin(): Unit \ Assert =
        let admin = { allowedOrigins = "https://admin.example.com" :: Nil };
        let cases = List#{
            (admin, Nil, true),
            (admin, ("origin", "https://admin.example.com") :: Nil, true),
            (admin, ("origin", "https://evil.example.com") :: Nil, false),
            (Cors.none(), ("Origin", "https://admin.example.com") :: Nil, false),
            (Cors.none(), Nil, true) };
        Assert.assertEq(
            expected = cases |> List.map(match (_, _, allowed) -> allowed),
            cases |> List.map(match (config, headers, _) -> McpServer.isOriginAllowed(config, headers)))

    /// ログ用のまとめ: tools/call だけ Some((ツール名, 引数の id, isError))。他の method は None。引数そのものは残さない。
    @Test
    def testCallSummary(): Unit \ Assert =
        let call = McpServer.Message.Request(Value.Int(1), "tools/call", obj(List#{ ("name", Value.Str("publish")), ("arguments", obj(List#{ ("id", Value.Str("e1")), ("withDependencies", Value.Bool(true)) })) }));
        let ping = McpServer.Message.Request(Value.Int(1), "ping", Value.Null);
        let failed = McpServer.Reply.Body(obj(List#{ ("result", obj(List#{ ("isError", Value.Bool(true)) })) }));
        Assert.assertEq(
            expected = (Some(("publish", "e1", true)), None),
            (McpServer.callSummary(call, failed), McpServer.callSummary(ping, failed)))

    /// ログに出す身元の種類。生の鍵やトークンは出さない。
    @Test
    def testCredentialKind(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "bearer", "api-key", "pat", "preview", "anonymous", "invalid" },
            List#{ Credential.Bearer("i", "s", "e", "n"), Credential.ApiKey("cms_x"), Credential.PersonalToken("cmspat_x"), Credential.Preview("pv_x"), Credential.Missing, Credential.Invalid("x") }
                |> List.map(McpServer.credentialKind))

}
