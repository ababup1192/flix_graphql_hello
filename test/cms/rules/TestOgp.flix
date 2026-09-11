///
/// Ogp: HTML から OGP を読む純粋な規則。属性の順・引用符・`<title>` への倒し方・相対 URL・200 字・壊れた HTML。
/// 取りに行って良い URL の判定と、取り直しの判定もここ。
///
mod TestOgp {

    def page(): String = "https://example.com/articles/how-to-write?ref=x"

    /// 比べる形（record は Eq / ToString を持たない）。(title, description, imageUrl, siteName)
    def parts(meta: Ogp.Meta): (Option[String], Option[String], Option[String], Option[String]) = (meta#title, meta#description, meta#imageUrl, meta#siteName)

    // ---- 読む ----

    /// 4 つの og:* が揃った普通のページ。property が先でも content が先でも、シングルクォートでも同じ。
    @Test
    def testParseReadsOgpInAnyAttributeOrderAndQuote(): Unit \ Assert =
        let expected = (Some("読みやすい文章"), Some("一文を短くする"), Some("https://example.com/og.png"), Some("example"));
        let cases = List#{
            "<html><head><meta property=\"og:title\" content=\"読みやすい文章\"><meta property=\"og:description\" content=\"一文を短くする\"><meta property=\"og:image\" content=\"https://example.com/og.png\"><meta property=\"og:site_name\" content=\"example\"></head></html>",
            "<meta content=\"読みやすい文章\" property=\"og:title\" /><meta content=\"一文を短くする\" property=\"og:description\"/><meta content=\"https://example.com/og.png\" property=\"og:image\"><meta content=\"example\" property=\"og:site_name\">",
            "<META property='og:title' content='読みやすい文章'><meta property='og:description' content='一文を短くする'><meta property='og:image' content='https://example.com/og.png'><meta property='og:site_name' content='example'>",
            "<meta name=\"og:title\" content=\"読みやすい文章\"><meta name=\"og:description\" content=\"一文を短くする\"><meta name=\"og:image\" content=\"https://example.com/og.png\"><meta name=\"og:site_name\" content=\"example\">"
        };
        Assert.assertEq(expected = List.map(_ -> expected, cases), cases |> List.map(html -> parts(Ogp.parse(page(), html))))

    /// og:title が無ければ `<title>`（前後の空白と改行は落とす）。両方あれば og:title。両方無ければ None。
    @Test
    def testParseFallsBackToTitleTag(): Unit \ Assert =
        let cases = List#{
            ("<html><head><title>\n  ページの題名  \n</title></head></html>",                                Some("ページの題名")),
            ("<head><meta property=\"og:title\" content=\"OGP の題\"><title>タグの題</title></head>",          Some("OGP の題")),
            ("<head><meta property=\"og:description\" content=\"説明だけ\"></head>",                          None),
            ("<TITLE lang=\"ja\">大文字のタグ</TITLE>",                                                       Some("大文字のタグ")),
            ("",                                                                                              None)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (html, _) -> (html, Ogp.parse(page(), html)#title)))

    /// 相対の og:image は url で絶対にする。絶対・`//`・`/` 始まり・相対パスの 4 通り。
    @Test
    def testParseResolvesRelativeImage(): Unit \ Assert =
        let cases = List#{
            ("https://cdn.example.net/a.png", "https://cdn.example.net/a.png"),
            ("//cdn.example.net/a.png",       "https://cdn.example.net/a.png"),
            ("/images/a.png",                 "https://example.com/images/a.png"),
            ("a.png",                         "https://example.com/articles/a.png")
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (image, _) -> (image, Ogp.parse(page(), "<meta property=\"og:image\" content=\"${image}\">")#imageUrl |> Option.getWithDefault(""))))

    /// description は 200 字で切る。199 字はそのまま、201 字は 200 字。
    @Test
    def testParseCutsDescriptionAt200(): Unit \ Assert =
        let text = n -> List.range(0, n) |> List.map(_ -> "あ") |> List.join("");
        let cases = List#{ (199, 199), (200, 200), (201, 200), (1000, 200) };
        Assert.assertEq(expected = cases, cases |> List.map(match (length, _) ->
            (length, Ogp.parse(page(), "<meta property=\"og:description\" content=\"${text(length)}\">")#description |> Option.map(String.length) |> Option.getWithDefault(0))))

    /// content の実体参照は戻す。空の content は無いのと同じ。同じ property が 2 つあれば先の物。
    @Test
    def testParseEntitiesEmptyAndDuplicates(): Unit \ Assert =
        let html = "<meta property=\"og:title\" content=\"A &amp; B &quot;C&quot; &#39;D&#39;\"><meta property=\"og:title\" content=\"後の題\"><meta property=\"og:site_name\" content=\"\">";
        Assert.assertEq(
            expected = (Some("A & B \"C\" 'D'"), None),
            { let meta = Ogp.parse(page(), html); (meta#title, meta#siteName) })

    /// 壊れた HTML（閉じない meta、引用符の無い値、`>` の無いタグ、タグだけ）でも落ちず、読めた分だけ返す。
    @Test
    def testParseSurvivesBrokenHtml(): Unit \ Assert =
        let cases = List#{
            ("<meta property=og:title content=Plain",                      Some("Plain")),
            ("<meta property=\"og:title\" content=\"閉じない",              Some("閉じない")),
            ("<meta",                                                        None),
            ("<meta property=\"og:title\"",                                  None),
            ("<meta =\"x\" property=\"og:title\" content=\"ゴミの後\">",     Some("ゴミの後")),
            ("<title",                                                       None),
            ("<title>閉じない題",                                            Some("閉じない題"))
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (html, _) -> (html, Ogp.parse(page(), html)#title)))

    /// 何も無ければ全部 None。
    @Test
    def testParseNothing(): Unit \ Assert =
        Assert.assertEq(expected = (None, None, None, None), parts(Ogp.parse(page(), "<html><body><p>本文だけ</p></body></html>")))

    // ---- 取りに行って良い URL か ----

    /// http(s) 以外と、プライベートアドレスは断る。公開のホストは通る。
    @Test
    def testRefuseReason(): Unit \ Assert =
        let cases = List#{
            ("https://example.com/",                 None),
            ("http://example.com:8080/a?b=c",        None),
            ("https://user:pw@example.com/",         None),
            ("https://172.32.0.1/",                  None),
            ("https://192.169.0.1/",                 None),
            ("ftp://example.com/",                   Some("http(s) の URL だけ取りに行けます")),
            ("mailto:a@example.com",                 Some("http(s) の URL だけ取りに行けます")),
            ("https://",                             Some("URL にホストがありません")),
            ("http://localhost:8080/",               Some("プライベートアドレスには取りに行きません")),
            ("http://LOCALHOST/",                    Some("プライベートアドレスには取りに行きません")),
            ("http://app.localhost/",                Some("プライベートアドレスには取りに行きません")),
            ("http://127.0.0.1/",                    Some("プライベートアドレスには取りに行きません")),
            ("http://127.1.2.3:9000/",               Some("プライベートアドレスには取りに行きません")),
            ("http://10.0.0.5/",                     Some("プライベートアドレスには取りに行きません")),
            ("http://172.16.0.1/",                   Some("プライベートアドレスには取りに行きません")),
            ("http://172.31.255.255/",               Some("プライベートアドレスには取りに行きません")),
            ("http://192.168.1.1/",                  Some("プライベートアドレスには取りに行きません")),
            ("http://169.254.169.254/latest/",       Some("プライベートアドレスには取りに行きません")),
            ("http://0.0.0.0/",                      Some("プライベートアドレスには取りに行きません")),
            ("http://[::1]/",                        Some("プライベートアドレスには取りに行きません")),
            ("http://user@127.0.0.1/",               Some("プライベートアドレスには取りに行きません"))
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (url, _) -> (url, Ogp.refuseReason(url))))

    /// ホストの取り出し。ポート・userinfo・パスは落とし、小文字にする。
    @Test
    def testHostOf(): Unit \ Assert =
        let cases = List#{
            ("https://Example.COM/a",           "example.com"),
            ("https://example.com:8443/a",      "example.com"),
            ("https://u:p@example.com/",        "example.com"),
            ("http://[::1]:8080/",              "[::1]"),
            ("not a url",                       "")
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (url, _) -> (url, Ogp.hostOf(url))))

    // ---- 失敗の理由と取り直し ----

    /// 2xx は理由無し。401 / 403 は bot 拒否、404 / 410 は無いページ、それ以外は番号だけ。
    @Test
    def testDescribeStatus(): Unit \ Assert =
        let cases = List#{
            (200, None),
            (204, None),
            (301, Some("取得に失敗しました（HTTP 301）")),
            (401, Some("取得を断られました（HTTP 401。bot を受け付けないサイト）")),
            (403, Some("取得を断られました（HTTP 403。bot を受け付けないサイト）")),
            (404, Some("ページが見つかりません（HTTP 404）")),
            (410, Some("ページが見つかりません（HTTP 410）")),
            (500, Some("取得に失敗しました（HTTP 500）"))
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (status, _) -> (status, Ogp.describeStatus(status))))

    /// 成功した行は 7 日、失敗した行は 1 時間で取り直しの番。境界ちょうどは番。
    @Test
    def testNeedsRefetch(): Unit \ Assert =
        let hour = 60i64 * 60i64 * 1000i64;
        let day = 24i64 * hour;
        let cases = List#{
            ((0i64, false),            false),
            ((7i64 * day - 1i64, false), false),
            ((7i64 * day, false),      true),
            ((0i64, true),             false),
            ((hour - 1i64, true),      false),
            ((hour, true),             true),
            ((7i64 * day, true),       true)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match ((elapsed, hasError), _) -> ((elapsed, hasError), Ogp.needsRefetch(1000000000000i64 + elapsed, 1000000000000i64, hasError))))

}
