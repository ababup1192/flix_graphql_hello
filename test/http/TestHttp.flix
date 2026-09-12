///
/// Http: リクエスト行・ヘッダの解析と、レスポンスの組み立て。ソケットは使わない。
///

// ---- リクエスト行 ----

/// リクエスト行からメソッドとパスを取り出す。
@Test
def testHttpParseRequestLine(): Unit \ Assert =
    Assert.assertEq(expected = Some(("POST", "/graphql", "HTTP/1.1")), Http.parseRequestLine("POST /graphql HTTP/1.1"))

/// 壊れたリクエスト行は None。
@Test
def testHttpParseRequestLineBroken(): Unit \ Assert =
    Assert.assertEq(expected = None, Http.parseRequestLine("nonsense"))

/// HTTP バージョンが無いリクエスト行は None。
@Test
def testHttpParseRequestLineMissingVersion(): Unit \ Assert =
    Assert.assertEq(expected = None, Http.parseRequestLine("POST /graphql"))

// ---- ヘッダ ----

/// ヘッダ行は名前を小文字に、値を trim して返す。値の中の ":" は残す。":" が無い行は None。
@Test
def testHttpParseHeaderLine(): Unit \ Assert =
    Assert.assertEq(expected = (Some(("content-length", "42")), Some(("host", "localhost:8080")), None, None, None),
        (Http.parseHeaderLine("Content-Length:  42 "), Http.parseHeaderLine("Host: localhost:8080"), Http.parseHeaderLine("garbage"),
         Http.parseHeaderLine(" content-length: 5"), Http.parseHeaderLine("X Bad Name: v")))

/// ヘッダ行の一覧を解析し、解析できない行は捨てる。
@Test
def testHttpParseHeaders(): Unit \ Assert =
    Assert.assertEq(expected = ("host", "x") :: ("accept", "*/*") :: Nil,
        Http.parseHeaders("Host: x" :: "garbage" :: "Accept: */*" :: Nil))

/// Content-Length はヘッダ名の大小を区別せず読み、無ければ Ok(0)。
@Test
def testHttpContentLength(): Unit \ Assert =
    Assert.assertEq(expected = (Ok(42), Ok(0)),
        (Http.contentLength(Http.parseHeaders("Host: x" :: "content-length: 42" :: Nil)), Http.contentLength(Http.parseHeaders("Host: x" :: Nil))))

/// Content-Length の値が数字でなければ Malformed。
@Test
def testHttpContentLengthMalformed(): Unit \ Assert =
    Assert.assertEq(expected = Err(Http.HeaderError.Malformed("abc")), Http.contentLength(("content-length", "abc") :: Nil))

/// 負の Content-Length は Malformed。
@Test
def testHttpContentLengthNegative(): Unit \ Assert =
    Assert.assertEq(expected = Err(Http.HeaderError.Malformed("-1")), Http.contentLength(("content-length", "-1") :: Nil))

/// 上限（1 MiB）ちょうどは Ok、1 バイト超えると TooLarge。
@Test
def testHttpContentLengthTooLarge(): Unit \ Assert =
    Assert.assertEq(expected = (Ok(1048576), Err(Http.HeaderError.TooLarge(1048577)), Err(Http.HeaderError.TooLarge(Int32.maxValue()))),
        (Http.contentLength(("content-length", "1048576") :: Nil), Http.contentLength(("content-length", "1048577") :: Nil),
         Http.contentLength(("content-length", "99999999999") :: Nil)))

/// 同じ値の Content-Length が 2 つ並ぶのは 1 つとして読み、値が食い違えば Malformed。
@Test
def testHttpContentLengthDuplicate(): Unit \ Assert =
    Assert.assertEq(expected = (Ok(42), Err(Http.HeaderError.Malformed("42, 43"))),
        (Http.contentLength(("content-length", "42") :: ("content-length", "42") :: Nil),
         Http.contentLength(("content-length", "42") :: ("host", "x") :: ("content-length", "43") :: Nil)))

// ---- レスポンス ----

/// UTF-8 のバイト数を数える。ASCII は 1、日本語は 3、絵文字（サロゲートペア）は 4。
@Test
def testHttpUtf8Length(): Unit \ Assert =
    Assert.assertEq(expected = (3, 6, 4), (Http.utf8Length("abc"), Http.utf8Length("日本"), Http.utf8Length("😀")))

/// レスポンスはステータス行・Content-Length・空行・ボディの順で組む。
@Test
def testHttpRender(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
        Http.render(Http.Connection.Close, { status = 200, headers = Nil, body = "{}" }))

/// 追加ヘッダは Connection の後ろ、空行の前に届いた順で並ぶ。
@Test
def testHttpRenderExtraHeaders(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 2\r\nConnection: close\r\nX-A: 1\r\nX-B: 2\r\n\r\n{}",
        Http.render(Http.Connection.Close, { status = 200, headers = ("X-A", "1") :: ("X-B", "2") :: Nil, body = "{}" }))

/// 行が Content-Type を持っていれば既定の JSON は付けない（CSV のダウンロードが JSON 扱いにならない）。
@Test
def testHttpRenderKeepsRouteContentType(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\nContent-Type: text/csv; charset=utf-8\r\n\r\na,",
        Http.render(Http.Connection.Close, { status = 200, headers = ("Content-Type", "text/csv; charset=utf-8") :: Nil, body = "a," }))

/// 304 にも理由句が付く（`304 Unknown` だと curl やプロキシのログで何が起きたか読めない）。
@Test
def testHttpRender304HasReasonPhrase(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        Http.render(Http.Connection.Close, { status = 304, headers = Nil, body = "" }))

/// ヘッダ値の CR / LF は落とす（Origin をそのまま返す CORS でレスポンス分割にならない）。
@Test
def testHttpRenderStripsLineBreaksInHeaderValue(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 204 No Content\r\nConnection: close\r\nAccess-Control-Allow-Origin: http://aX: y\r\n\r\n",
        Http.render(Http.Connection.Close, { status = 204, headers = ("Access-Control-Allow-Origin", "http://a\rX: y\n") :: Nil, body = "" }))

/// 日本語ボディの Content-Length は文字数（4）ではなく UTF-8 のバイト数（8）。
@Test
def testHttpRenderNonAsciiBody(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 8\r\nConnection: close\r\n\r\n\"日本\"",
        Http.render(Http.Connection.Close, { status = 200, headers = Nil, body = "\"日本\"" }))

/// 413 には Payload Too Large の理由句が付き、ボディが空なので Content-Type は付かない。
@Test
def testHttpRenderPayloadTooLarge(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        Http.render(Http.Connection.Close, { status = 413, headers = Nil, body = "" }))

/// 431 には Request Header Fields Too Large の理由句が付く。
@Test
def testHttpRenderHeaderTooLarge(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        Http.render(Http.Connection.Close, { status = 431, headers = Nil, body = "" }))

/// 500 には Internal Server Error の理由句が付く。
@Test
def testHttpRenderInternalServerError(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        Http.render(Http.Connection.Close, { status = 500, headers = Nil, body = "" }))

/// ボディが空でも追加ヘッダは Connection の後ろに並ぶ。
@Test
def testHttpRenderEmptyBodyExtraHeaders(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\nX-A: 1\r\n\r\n",
        Http.render(Http.Connection.Close, { status = 400, headers = ("X-A", "1") :: Nil, body = "" }))

/// 204 には Content-Type も Content-Length も付けない。
@Test
def testHttpRenderNoContent(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 204 No Content\r\nConnection: close\r\nVary: Origin\r\n\r\n",
        Http.render(Http.Connection.Close, { status = 204, headers = ("Vary", "Origin") :: Nil, body = "" }))

// ---- keep-alive ----

/// 続ける応答は Connection: keep-alive になる（他は close と同じ並び）。
@Test
def testHttpRenderKeepAlive(): Unit \ Assert =
    Assert.assertEq(
        expected = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}",
        Http.render(Http.Connection.KeepAlive, { status = 200, headers = Nil, body = "{}" }))

/// HTTP/1.1 で Connection: close が無く、上限（100）未満で、応答が 4xx / 5xx でなければ続ける。
/// Connection: close（大文字小文字を問わない）、HTTP/1.0、100 回目、400、500 は閉じる。
@Test
def testHttpShouldKeepAlive(): Unit \ Assert =
    let request = (version, headers) -> { version = version, method = "GET", path = "/health", headers = headers, body = "" };
    Assert.assertEq(
        expected = (Http.Connection.KeepAlive, Http.Connection.Close, Http.Connection.Close, Http.Connection.Close, Http.Connection.Close, Http.Connection.Close, Http.Connection.KeepAlive),
        (Http.shouldKeepAlive(request("HTTP/1.1", Nil), 200, 1),
         Http.shouldKeepAlive(request("HTTP/1.1", ("connection", "Close") :: Nil), 200, 1),
         Http.shouldKeepAlive(request("HTTP/1.0", Nil), 200, 1),
         Http.shouldKeepAlive(request("HTTP/1.1", Nil), 200, Http.maxRequestsPerConnection()),
         Http.shouldKeepAlive(request("HTTP/1.1", Nil), 400, 1),
         Http.shouldKeepAlive(request("HTTP/1.1", Nil), 500, 1),
         Http.shouldKeepAlive(request("HTTP/1.1", ("connection", "keep-alive") :: Nil), 204, Http.maxRequestsPerConnection() - 1)))
