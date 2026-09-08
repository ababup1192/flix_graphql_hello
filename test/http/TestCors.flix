///
/// Cors: オリジンの許可判定と、レスポンスに足すヘッダ。純粋関数だけ。
///
///
/// 指定したオリジンからの GET /graphql。
///
mod TestCors {

    def requestFrom(origin: String): HttpRequest =
        { version = "HTTP/1.1", method = "GET", path = "/graphql", headers = ("origin", origin) :: ("host", "api") :: Nil, body = "" }

    ///
    /// 管理画面のオリジンだけ許す設定。
    ///
    def adminOnly(): CorsConfig = { allowedOrigins = "https://admin.example.com" :: Nil }

    // ---- 設定の読み取り ----

    /// カンマ区切りを一覧にする。空白は落とし、空の要素は捨てる。
    @Test
    def testCorsParseOrigins(): Unit \ Assert =
        Assert.assertEq(expected = "https://a.example" :: "https://b.example" :: Nil,
            Cors.parseOrigins(" https://a.example, https://b.example ,, "))

    /// 空文字列は許すオリジン無し。
    @Test
    def testCorsParseOriginsEmpty(): Unit \ Assert =
        Assert.assertEq(expected = Nil, Cors.parseOrigins(""))

    // ---- 許可判定 ----

    /// 一覧にあるオリジンだけ許す。"*" があれば何でも許す。
    @Test
    def testCorsIsAllowed(): Unit \ Assert =
        Assert.assertEq(expected = (true, false, true),
            (Cors.isAllowed(adminOnly(), "https://admin.example.com"),
             Cors.isAllowed(adminOnly(), "https://evil.example"),
             Cors.isAllowed({ allowedOrigins = "*" :: Nil }, "https://anything.example")))

    // ---- レスポンスヘッダ ----

    /// 許したオリジンには Allow-Origin と Vary を返す。
    @Test
    def testCorsResponseHeadersAllowed(): Unit \ Assert =
        Assert.assertEq(expected = ("Access-Control-Allow-Origin", "https://admin.example.com") :: ("Vary", "Origin") :: Nil,
            Cors.responseHeaders(adminOnly(), requestFrom("https://admin.example.com")))

    /// 許していないオリジンと、Origin 無し（curl や同一オリジン）にはヘッダを付けない。
    @Test
    def testCorsResponseHeadersDenied(): Unit \ Assert =
        Assert.assertEq(expected = (("Vary", "Origin") :: Nil, Nil),
            (Cors.responseHeaders(adminOnly(), requestFrom("https://evil.example")),
             Cors.responseHeaders(adminOnly(), { version = "HTTP/1.1", method = "GET", path = "/graphql", headers = Nil, body = "" })))

    /// "*" で許しても "*" ではなく届いたオリジンを返す。
    @Test
    def testCorsWildcardEchoesOrigin(): Unit \ Assert =
        Assert.assertEq(expected = Some(("Access-Control-Allow-Origin", "https://x.example")),
            Cors.responseHeaders({ allowedOrigins = "*" :: Nil }, requestFrom("https://x.example")) |> List.head)

    /// withHeaders は元のヘッダの後ろに CORS ヘッダを足し、status と body は変えない。
    @Test
    def testCorsWithHeaders(): Unit \ Assert =
        let response = Cors.withHeaders(adminOnly(), requestFrom("https://admin.example.com"), { status = 405, headers = ("Allow", "POST") :: Nil, body = "{}" });
        Assert.assertEq(expected = (405, ("Allow", "POST") :: ("Access-Control-Allow-Origin", "https://admin.example.com") :: ("Vary", "Origin") :: Nil, "{}"),
            (response#status, response#headers, response#body))

    // ---- preflight ----

    /// 許したオリジンの preflight は 204 で、表のメソッド + OPTIONS・鍵とプレビューのヘッダ・Max-Age だけを返す（Allow-Origin は withHeaders が足す）。
    @Test
    def testCorsPreflightAllowed(): Unit \ Assert =
        let response = Cors.preflight(adminOnly(), Method.Post :: Method.Get :: Nil, requestFrom("https://admin.example.com"));
        Assert.assertEq(expected = (204, "", ("Access-Control-Allow-Methods", "POST, GET, OPTIONS") :: ("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Api-Key, X-Preview-Token") :: ("Access-Control-Max-Age", "86400") :: Nil),
            (response#status, response#body, response#headers))

    /// 許していないオリジンの preflight は 204 だがヘッダを一切付けない。
    @Test
    def testCorsPreflightDenied(): Unit \ Assert =
        let response = Cors.preflight(adminOnly(), Method.Get :: Nil, requestFrom("https://evil.example"));
        Assert.assertEq(expected = (204, Nil, ""), (response#status, response#headers, response#body))

    // ---- wrap ----

    /// 受けるメソッドのあるパスへの OPTIONS は next を呼ばず preflight（Allow-Origin 付き）。無いパスは next の応答（404）にも CORS ヘッダが付く。
    @Test
    def testCorsWrapPreflightAndPassThrough(): Unit \ Assert =
        let allowedMethods = path -> if (path == "/graphql") Method.Post :: Nil else Nil;
        let pipeline = Cors.wrap(adminOnly(), allowedMethods, _ -> { status = 404, headers = Nil, body = "" });
        let call = path -> pipeline({ request = { version = "HTTP/1.1", method = "OPTIONS", path = path, headers = ("origin", "https://admin.example.com") :: Nil, body = "" }, params = Map.empty(), credential = Credential.Missing, auth = Ok(Authentication.anonymous()), contentVersion = None });
        Assert.assertEq(
            expected = ((204, Some("https://admin.example.com"), Some("POST, OPTIONS")), (404, Some("https://admin.example.com"), None)),
            (call("/graphql") |> summarize, call("/nope") |> summarize))

    /// (status, Allow-Origin, Allow-Methods)。
    def summarize(response: HttpResponse): (Int32, Option[String], Option[String]) =
        (response#status, Http.findHeader("Access-Control-Allow-Origin", response#headers), Http.findHeader("Access-Control-Allow-Methods", response#headers))

}
