///
/// RequestId: X-Request-Id を受けるか捨てるかの規則と、応答ヘッダで返す middleware。
///
mod TestRequestId {

    /// 26 文字の ULID の形（Crockford の base32）。
    def looksLikeUlid(text: String): Bool =
        String.length(text) == 26 and String.forAll(ch -> Char.isAsciiDigit(ch) or (Char.isAscii(ch) and Char.isLetter(ch) and Char.isUpperCase(ch)), text)

    /// 受ける: 英数字と _ - だけで 1 〜 64 文字。捨てる: 空、65 文字、空白・記号・改行・非 ASCII。
    @Test
    def testAcceptTable(): Unit \ Assert =
        let cases = List#{
            ("01J9ZK3Q8R6S4T2V1W0X9Y8Z7A",           Some("01J9ZK3Q8R6S4T2V1W0X9Y8Z7A")),
            ("8b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e",  Some("8b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e")),
            ("req_1",                                  Some("req_1")),
            (String.repeat(64, "a"),                   Some(String.repeat(64, "a"))),
            ("",                                       None),
            (String.repeat(65, "a"),                   None),
            ("a b",                                    None),
            ("a\nb",                                   None),
            ("a.b",                                    None),
            ("id=1;x",                                 None),
            ("あ",                                     None)
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (value, _) -> RequestId.accept(value)))

    /// ヘッダの名前は大文字小文字を問わず、形が合わなければ None。
    @Test
    def testOfHeadersTable(): Unit \ Assert =
        let cases = List#{
            (("x-request-id", "abc") :: Nil,            Some("abc")),
            (("X-Request-Id", "abc") :: Nil,            Some("abc")),
            (("X-Request-Id", "a b") :: Nil,            None),
            (("Host", "example.com") :: Nil,            None),
            (Nil,                                       None)
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (headers, _) -> RequestId.ofHeaders(headers)))

    /// ヘッダに無ければ ULID の形の id を作る。あればそれ。
    @Test
    def testResolveMakesUlidWhenMissing(): Unit \ {Assert, IO} =
        Assert.assertEq(
            expected = (true, "given"),
            (looksLikeUlid(RequestId.resolve(Nil)), RequestId.resolve(("X-Request-Id", "given") :: Nil)))

    /// wrap は next の応答に X-Request-Id を足す（他のヘッダはそのまま）。
    @Test
    def testWrapAddsResponseHeader(): Unit \ Assert =
        let next = _ -> ({ status = 404, headers = ("Allow", "POST") :: Nil, body = "" }: HttpResponse);
        let response = RequestId.wrap("rid", next)({ request = { version = "HTTP/1.1", method = "GET", path = "/x", headers = Nil, body = "" }, params = Map.empty(), credential = Credential.Missing, auth = Ok(Authentication.anonymous()), contentVersion = None });
        Assert.assertEq(expected = (404, ("X-Request-Id", "rid") :: ("Allow", "POST") :: Nil), (response#status, response#headers))

}
