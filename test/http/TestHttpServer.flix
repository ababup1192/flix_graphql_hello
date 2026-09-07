///
/// HttpServer: ソケットを開かずに、InputStream からリクエスト行・ヘッダ・ボディを読む部分だけを確かめる。
///
mod TestHttpServer {
    import java.io.ByteArrayInputStream
    import java.io.InputStream
    import java.nio.charset.StandardCharsets

    ///
    /// 文字列を UTF-8 のバイト列として読む InputStream を作る。
    ///
    def inputOf(text: String): InputStream \ IO =
        checked_cast(new ByteArrayInputStream(text.getBytes(StandardCharsets.UTF_8)))

    ///
    /// count 行のヘッダ行と空行を "\r\n" 区切りで並べたテキスト。
    ///
    def headerText(count: Int32): String =
        List.range(0, count) |> List.map(index -> "X-${index}: v\r\n") |> List.join("") |> text -> text + "\r\n"

    ///
    /// "a" を count 個並べた文字列。
    ///
    def repeatA(count: Int32): String =
        List.repeat(count, "a") |> List.join("")

    ///
    /// HttpRequest を比較できるタプル (method, path, headers, body) にする。
    ///
    def toTuple(request: HttpRequest): (String, String, List[(String, String)], String) =
        (request#method, request#path, request#headers, request#body)

    // ---- readLine ----

    /// 1 行は "\n" まで読み、末尾の "\r" は落とす。次の行は続きから読める。
    @Test
    def testReadLine(): Unit \ {Assert, IO} =
        let input = inputOf("Host: x\r\nnext\n");
        Assert.assertEq(expected = (Ok("Host: x"), Ok("next"), Ok("")),
            (HttpServer.readLine(input), HttpServer.readLine(input), HttpServer.readLine(input)))

    /// 上限（8192 バイト）ちょうどの行は読めるが、1 バイト超えると Err(431)。
    @Test
    def testReadLineCap(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (Ok(8192), Err(431)),
            (HttpServer.readLine(inputOf(repeatA(8192) + "\n")) |> Result.map(String.length),
             HttpServer.readLine(inputOf(repeatA(8193) + "\n")) |> Result.map(String.length)))

    // ---- readHeaderLines ----

    /// ヘッダ行は空行で止まり、空行より後ろ（ボディ）は読まない。
    @Test
    def testReadHeaderLinesStopsAtBlank(): Unit \ {Assert, IO} =
        let input = inputOf("Host: x\r\nContent-Length: 2\r\n\r\n{}");
        Assert.assertEq(expected = (Ok("Host: x" :: "Content-Length: 2" :: Nil), "{}"),
            (HttpServer.readHeaderLines(input), HttpServer.readBody(input, 2)))

    /// 空行が来ないまま EOF になったら、そこまでの行を返す。
    @Test
    def testReadHeaderLinesStopsAtEof(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok("Host: x" :: Nil), HttpServer.readHeaderLines(inputOf("Host: x")))

    /// 上限（100 行）ちょうどは読めるが、101 行目が来たら Err(431)。
    @Test
    def testReadHeaderLinesCap(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (Ok(100), Err(431)),
            (HttpServer.readHeaderLines(inputOf(headerText(100))) |> Result.map(List.length),
             HttpServer.readHeaderLines(inputOf(headerText(101))) |> Result.map(List.length)))

    /// 長すぎるヘッダ行があれば Err(431)。
    @Test
    def testReadHeaderLinesTooLongLine(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err(431),
            HttpServer.readHeaderLines(inputOf("Host: x\r\nX-Long: " + repeatA(8192) + "\r\n\r\n")))

    // ---- readBody ----

    /// 日本語（1 文字 3 バイト）を 6 バイトぶん読むと 2 文字で止まる。
    @Test
    def testReadBodyCountsUtf8Bytes(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "日本", HttpServer.readBody(inputOf("日本語"), 6))

    /// ASCII と日本語が混ざっても、バイト数で数えて止まる（"a" 1 + "日" 3 = 4）。
    @Test
    def testReadBodyMixed(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "a日", HttpServer.readBody(inputOf("a日b"), 4))

    /// 絵文字（サロゲートペア、4 バイト）は Content-Length 4 でちょうど読み切る。
    @Test
    def testReadBodyEmoji(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "😀", HttpServer.readBody(inputOf("😀"), 4))

    /// ASCII・日本語・絵文字が混ざっても、バイト数で数えて止まる（1 + 3 + 4 = 8）。
    @Test
    def testReadBodyMixedEmoji(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "a日😀", HttpServer.readBody(inputOf("a日😀b"), 8))

    /// 指定バイト数より先に EOF が来たら、読めたぶんだけ返す。
    @Test
    def testReadBodyStopsAtEof(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "ab", HttpServer.readBody(inputOf("ab"), 10))

    /// 0 バイトなら何も読まない。
    @Test
    def testReadBodyZero(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = "", HttpServer.readBody(inputOf("ab"), 0))

    /// 読み取りバッファ（8192 バイト）より大きいボディも全部読む。
    @Test
    def testReadBodyLargerThanBuffer(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 20000, HttpServer.readBody(inputOf(repeatA(20000)), 20000) |> String.length)

    // ---- readRequest ----

    /// 普通の POST は、ヘッダ（小文字化）とボディがそろった HttpRequest になる。
    @Test
    def testReadRequestPost(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Ok(("POST", "/graphql", ("host", "x") :: ("content-length", "2") :: Nil, "{}")),
            HttpServer.readRequest(inputOf("POST /graphql HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}")) |> Result.map(toTuple))

    /// 壊れたリクエスト行は Err(400)。
    @Test
    def testReadRequestBadRequestLine(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err(400),
            HttpServer.readRequest(inputOf("nonsense\r\n\r\n")) |> Result.map(toTuple))

    /// Content-Length が上限（1 MiB）を超えていれば Err(413)。
    @Test
    def testReadRequestTooLarge(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err(413),
            HttpServer.readRequest(inputOf("POST /graphql HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n")) |> Result.map(toTuple))

    /// Content-Length が数字でなければ Err(400)。
    @Test
    def testReadRequestMalformedContentLength(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err(400),
            HttpServer.readRequest(inputOf("POST /graphql HTTP/1.1\r\nContent-Length: abc\r\n\r\n")) |> Result.map(toTuple))

    /// ヘッダが 101 行あれば Err(431)。
    @Test
    def testReadRequestTooManyHeaderLines(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err(431),
            HttpServer.readRequest(inputOf("POST /graphql HTTP/1.1\r\n" + headerText(101))) |> Result.map(toTuple))

    /// リクエスト行が長すぎれば、解析より先に Err(431)。
    @Test
    def testReadRequestTooLongRequestLine(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err(431),
            HttpServer.readRequest(inputOf(repeatA(8193) + " /graphql HTTP/1.1\r\n\r\n")) |> Result.map(toTuple))

    /// ヘッダ 1 行が長すぎれば Err(431)。
    @Test
    def testReadRequestTooLongHeaderLine(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err(431),
            HttpServer.readRequest(inputOf("POST /graphql HTTP/1.1\r\nX-Long: " + repeatA(8192) + "\r\n\r\n")) |> Result.map(toTuple))


    /// リクエストのログは 1 行 1 JSON。パスの制御文字（改行など）は落ち、time は ISO 8601 の UTC。
    @Test
    def testHttpServerLogLineIsJson(): Unit \ {IO, Assert} =
        let line = HttpServer.logLine("GET", "/health\n{\"fake\":1}\u001b[31m", 200, 12i64);
        let parsed = JsonValue.parse(line) |> Result.map(value -> match value {
            case Value.Obj(fields) => (Map.get("method", fields), Map.get("path", fields), Map.get("status", fields), Map.get("ms", fields),
                                       Map.get("time", fields) |> Option.map(time -> match time { case Value.Str(text) => String.endsWith(suffix = "Z", text) case _ => false }))
            case _ => (None, None, None, None, None)
        });
        Assert.assertEq(
            expected = Ok((Some(Value.Str("GET")), Some(Value.Str("/health{\"fake\":1}[31m")), Some(Value.Int(200)), Some(Value.Int(12)), Some(true))),
            parsed)

}
