///
/// MCP サーバ（legacy。MCP 2025-06-18 の形: initialize の握手、セッション無し、tools だけ）。
/// JSON-RPC の parse と dispatch、initialize / ping / tools/list / tools/call、エラーの形。全部純粋で、GraphQL は execute を受けて呼ぶ。
/// HTTP との繋ぎ（ステータス、Origin、認証）は Server.flix の handler。
///
/// WhyNot: modern（2026-07-28。server/discover、ヘッダ照合）を喋らないのは、実機の `claude mcp add` が legacy に落ちて来る事が v1 の合否条件で、
/// modern は v2 で足すため。-32022 のような modern の code も返さない。
///
mod McpServer {

    ///
    /// JSON-RPC の 1 メッセージ。
    ///
    /// - Request(id, method, params): 応答が要る
    /// - Notification(method, params): 応答が要らない（HTTP 202）
    ///
    pub enum Message with Eq, ToString {
        case Request(Value, String, Value)
        case Notification(String, Value)
    }

    ///
    /// dispatch の答え。
    ///
    /// - Body: JSON-RPC の応答（HTTP 200）
    /// - Accepted: 通知を受けた（HTTP 202、body 無し）
    /// - Unauthenticated: 身元の検証に落ちた（HTTP 401）。body は id 付きの error
    ///
    pub enum Reply with Eq, ToString {
        case Body(Value)
        case Accepted
        case Unauthenticated(Value)
    }

    /// JSON-RPC の error code。
    pub def parseErrorCode(): Int32 = -32700
    pub def invalidRequestCode(): Int32 = -32600
    pub def methodNotFoundCode(): Int32 = -32601
    pub def invalidParamsCode(): Int32 = -32602

    ///
    /// このサーバが喋れる MCP のバージョン。
    ///
    pub def supportedProtocolVersions(): List[String] = "2024-11-05" :: "2025-03-26" :: "2025-06-18" :: Nil

    /// 支持できない値を求められた時に返すバージョン。
    def latestProtocolVersion(): String = "2025-06-18"

    /// MCP-Protocol-Version ヘッダが無い時のバージョン（initialize より前の形）。
    def defaultProtocolVersion(): String = "2025-03-26"

    ///
    /// MCP-Protocol-Version ヘッダ。無ければ 2025-03-26、知っている値はそれ、知らない値は Err にその値（HTTP 400）。
    ///
    pub def protocolVersionOf(headers: List[(String, String)]): Result[String, String] =
        match Http.findHeader("MCP-Protocol-Version", headers) {
            case None        => Ok(defaultProtocolVersion())
            case Some(found) => if (List.memberOf(found, supportedProtocolVersions())) Ok(found) else Err(found)
        }

    ///
    /// Origin。無ければ通す（curl や CLI）。あれば CORS で許したオリジンだけ通す。
    ///
    /// WhyNot: 無い時に通すのは、`claude mcp add` のような CLI は Origin を付けず、付けるのはブラウザだけのため。
    /// ブラウザからは許した管理画面のオリジンだけが叩ける（DNS rebinding で localhost のサーバを別サイトから叩かれない）。
    ///
    pub def isOriginAllowed(config: CorsConfig, headers: List[(String, String)]): Bool =
        Http.findHeader("Origin", headers) |> Option.forAll(origin -> Cors.isAllowed(config, origin))

    // ---- JSON-RPC ----

    ///
    /// JSON-RPC の error の応答。id が無い時は null。
    ///
    pub def errorBody(id: Value, code: Int32, message: String): Value =
        Value.Obj(Map#{ "jsonrpc" => Value.Str("2.0"), "id" => id, "error" => Value.Obj(Map#{ "code" => Value.Int(code), "message" => Value.Str(message) }) })

    /// JSON-RPC の result の応答。
    def resultBody(id: Value, result: Value): Value =
        Value.Obj(Map#{ "jsonrpc" => Value.Str("2.0"), "id" => id, "result" => result })

    ///
    /// 本文を 1 メッセージに読む。壊れた JSON は -32700、配列（バッチ）とオブジェクトでない物と method 無しは -32600。Err は error の応答そのもの。
    ///
    pub def parse(body: String): Result[Value, Message] = match JsonValue.parse(body) {
        case Err(message)      => Err(errorBody(Value.Null, parseErrorCode(), "parse error: ${message}"))
        case Ok(Value.List(_)) => Err(errorBody(Value.Null, invalidRequestCode(), "バッチは受け付けません（1 リクエストずつ送ってください）"))
        case Ok(Value.Obj(fields)) =>
            let params = Map.getWithDefault("params", Value.Null, fields);
            match (Map.get("method", fields) |> Option.flatMap(Value.asStr), Map.get("id", fields)) {
                case (None, id)           => Err(errorBody(id |> Option.getWithDefault(Value.Null), invalidRequestCode(), "method が要ります"))
                case (Some(method), None) => Ok(Message.Notification(method, params))
                case (Some(method), Some(id)) => Ok(Message.Request(id, method, params))
            }
        case Ok(_)             => Err(errorBody(Value.Null, invalidRequestCode(), "JSON-RPC のオブジェクトで送ってください"))
    }

    ///
    /// 1 メッセージを処理する。serverVersion は serverInfo.version（/health と同じ）。execute は admin engine への GraphQL。
    ///
    pub def dispatch(serverVersion: String, message: Message, execute: GraphqlRequest -> GraphqlResponse \ ef): Reply \ ef = match message {
        case Message.Notification(_, _)              => Reply.Accepted
        case Message.Request(id, "initialize", params) => Reply.Body(resultBody(id, initializeResult(serverVersion, params)))
        case Message.Request(id, "ping", _)          => Reply.Body(resultBody(id, Value.Obj(Map.empty())))
        case Message.Request(id, "tools/list", _)    => Reply.Body(resultBody(id, Value.Obj(Map#{ "tools" => Value.List(McpTools.toolListValue()) })))
        case Message.Request(id, "tools/call", params) => callTool(id, params, execute)
        case Message.Request(id, method, _)          => Reply.Body(errorBody(id, methodNotFoundCode(), "method not found: ${method}"))
    }

    ///
    /// initialize の result。protocolVersion はクライアントの値を支持できればそれ、無理なら 2025-06-18。capabilities は tools だけ。
    ///
    def initializeResult(serverVersion: String, params: Value): Value =
        let requested = Value.field("protocolVersion", params) |> Value.asStr |> Option.getWithDefault("");
        let negotiated = if (List.memberOf(requested, supportedProtocolVersions())) requested else latestProtocolVersion();
        Value.Obj(Map#{
            "protocolVersion" => Value.Str(negotiated),
            "capabilities"    => Value.Obj(Map#{ "tools" => Value.Obj(Map.empty()) }),
            "serverInfo"      => Value.Obj(Map#{ "name" => Value.Str("cms"), "version" => Value.Str(serverVersion) }) })

    ///
    /// tools/call。name と arguments を定義で復号し（誤りは -32602）、ツールを呼ぶ。業務エラーは result の isError、UNAUTHENTICATED だけ 401。
    ///
    def callTool(id: Value, params: Value, execute: GraphqlRequest -> GraphqlResponse \ ef): Reply \ ef =
        let decoded = forM (
            name <- Value.field("name", params) |> Value.asStr |> Option.toOk("params.name が要ります");
            tool <- Tool.parse(name) |> Option.toOk("unknown tool: ${name}");
            args <- McpTools.decodeArgs(McpTools.definitionOf(tool)#args, Value.field("arguments", params))
        ) yield (tool, args);
        match decoded {
            case Err(message)     => Reply.Body(errorBody(id, invalidParamsCode(), message))
            case Ok((tool, args)) => match McpTools.call(tool, args, execute) {
                case Err(McpTools.Failure.Unauthenticated(message)) => Reply.Unauthenticated(errorBody(id, invalidRequestCode(), message))
                case outcome                                        => Reply.Body(resultBody(id, McpTools.callResult(outcome)))
            }
        }

    ///
    /// ログ用のまとめ。tools/call なら Some((ツール名, 引数の id（無ければ空）, isError))。引数そのものは残さない（本文に秘密が入りうる）。
    ///
    pub def callSummary(message: Message, reply: Reply): Option[(String, String, Bool)] = match (message, reply) {
        case (Message.Request(_, "tools/call", params), Reply.Body(body)) =>
            Some((Value.field("name", params) |> Value.asStr |> Option.getWithDefault(""),
                  Value.path(List#{"arguments", "id"}, params) |> Value.asStr |> Option.getWithDefault(""),
                  Value.path(List#{"result", "isError"}, body) == Value.Bool(true)))
        case (Message.Request(_, "tools/call", params), Reply.Unauthenticated(_)) =>
            Some((Value.field("name", params) |> Value.asStr |> Option.getWithDefault(""),
                  Value.path(List#{"arguments", "id"}, params) |> Value.asStr |> Option.getWithDefault(""),
                  true))
        case _ => None
    }

}
