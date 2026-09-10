///
/// 型ごとの「パスの形」。型紙（`/blog/{slug}`）から、entry が site 上で持つ path を作る。
///
mod TestLinkPath {

    /// 型紙に id と slug を差し込む。`{slug}` は値が無ければ id に落ちる。
    @Test
    def testRender(): Unit \ Assert =
        let cases = List#{
            ("/blog/{slug}", "abc123", Some("hello"), "/blog/hello"),
            ("/blog/{slug}", "abc123", None, "/blog/abc123"),
            ("/blog/{slug}", "abc123", Some(""), "/blog/abc123"),
            ("/tag/{id}", "abc123", Some("hello"), "/tag/abc123"),
            ("https://example.com/n/{slug}", "abc123", Some("hi"), "https://example.com/n/hi"),
            ("/x/{slug}/{id}", "abc123", Some("hi"), "/x/hi/abc123"),
            ("/one", "abc123", Some("hi"), "/one")
        };
        Assert.assertEq(
            expected = cases |> List.map(match (_, _, _, want) -> want),
            cases |> List.map(match (template, id, slug, _) -> LinkPath.render(template, id, slug)))

    /// 型紙が無ければ path も無い（サイトが自分で置き換える）。
    @Test
    def testNoTemplate(): Unit \ Assert =
        Assert.assertEq(expected = (None, None), (LinkPath.of(None, "abc123", Some("hi")), LinkPath.of(Some(""), "abc123", Some("hi"))))

    /// 型紙のあるなしで href が変わる。無ければ今まで通りの `#entry:{id}`。
    @Test
    def testHref(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "/blog/hi", "#entry:abc123" },
            List#{ LinkPath.href(Some("/blog/{slug}"), "abc123", Some("hi")), LinkPath.href(None, "abc123", Some("hi")) })

    ///
    /// 型紙の検査。`{id}` と `{slug}` だけ、`/` か http(s):// で始まる。
    ///
    /// 空は「設定なし」なので通る。
    ///
    @Test
    def testCheck(): Unit \ Assert =
        let cases = List#{
            ("", true),
            ("/blog/{slug}", true),
            ("/tag/{id}", true),
            ("/x/{slug}/{id}", true),
            ("https://example.com/n/{slug}", true),
            ("http://example.com/n/{id}", true),
            ("/one", true),
            ("/blog/{slag}", false),
            ("/blog/{}", false),
            ("/blog/{slug", false),
            ("/blog/slug}", false),
            ("blog/{slug}", false),
            ("javascript:alert(1){id}", false),
            ("//evil.example.com/{id}", false)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (template, _) -> (template, List.isEmpty(LinkPath.check("previewUrl", template)))))

    /// 止まった時は場所と理由が出る。
    @Test
    def testCheckMessage(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ ("linkPath", "パスの形に使えるのは {id} と {slug} だけです") },
            LinkPath.check("linkPath", "/blog/{slag}") |> List.map(violation -> { let Violation.Violation(path, message) = violation; (path, message) }))

}
