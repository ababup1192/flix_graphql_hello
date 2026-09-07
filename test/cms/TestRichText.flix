///
/// richText の規則。ホワイトリストの検査、asset の取り出し、平文と HTML。
///
mod TestRichText {

    use Util.Json.Json

    def node(kind: String, content: List[Json]): Json =
        Json.JObject(Map#{ "type" => Json.JString(kind), "content" => Json.JArray(List.toVector(content)) })

    def nodeWith(kind: String, attrs: List[(String, Json)], content: List[Json]): Json =
        Json.JObject(Map#{ "type" => Json.JString(kind), "attrs" => Json.JObject(List.toMap(attrs)), "content" => Json.JArray(List.toVector(content)) })

    def text(s: String): Json = Json.JObject(Map#{ "type" => Json.JString("text"), "text" => Json.JString(s) })

    def marked(s: String, marks: List[Json]): Json =
        Json.JObject(Map#{ "type" => Json.JString("text"), "text" => Json.JString(s), "marks" => Json.JArray(List.toVector(marks)) })

    def mark(kind: String): Json = Json.JObject(Map#{ "type" => Json.JString(kind) })

    def link(href: String): Json = Json.JObject(Map#{ "type" => Json.JString("link"), "attrs" => Json.JObject(Map#{ "href" => Json.JString(href) }) })

    def image(assetId: String, alt: String): Json =
        Json.JObject(Map#{ "type" => Json.JString("image"), "attrs" => Json.JObject(Map#{ "assetId" => Json.JString(assetId), "alt" => Json.JString(alt) }) })

    ///
    /// 見本の doc。
    ///
    ///   doc
    ///   ├ heading(2)  "見出し"
    ///   ├ paragraph   "a" [bold] "<b>" [link]
    ///   ├ image       asset001 "写真"
    ///   └ bulletList ─ listItem ─ paragraph "x" hardBreak "y"
    ///
    def sample(): Json =
        node("doc", List#{
            nodeWith("heading", List#{("level", CmsTestKit.intJson(2))}, List#{text("見出し")}),
            node("paragraph", List#{marked("a", List#{mark("bold")}), marked("<b>", List#{link("https://example.com/?a=1&b=2")})}),
            image("asset001", "写真"),
            node("bulletList", List#{node("listItem", List#{node("paragraph", List#{text("x"), mark("hardBreak"), text("y")})})})
        })

    // ---- 検査 ----

    /// 見本は通る。
    @Test
    def testValidateSample(): Unit \ Assert =
        Assert.assertEq(expected = Nil, RichText.validate("fields.body", sample()))

    /// 根が doc でない・知らないノード・危ない href・範囲外の heading・規則外の assetId、はそれぞれ場所付きで止まる。
    @Test
    def testValidateRejects(): Unit \ Assert =
        let bad = node("doc", List#{
            node("iframe", Nil),
            node("paragraph", List#{marked("x", List#{link("javascript:alert(1)")})}),
            nodeWith("heading", List#{("level", CmsTestKit.intJson(7))}, Nil),
            image("not an id!", "")
        });
        Assert.assertEq(
            expected = List#{
                ("fields.body", "richText は { type: \"doc\", content: [...] } の形にしてください"),
                ("fields.body.content[0]", "知らないノード 'iframe' です（paragraph, heading, bulletList, orderedList, listItem, blockquote, codeBlock, table, tableRow, tableCell, tableHeader, callout, text, hardBreak, horizontalRule, image, embed）"),
                ("fields.body.content[1].content[0].marks[0]", "link は attrs.href（http(s):// か mailto:）か attrs.entryId（entry の id）のどちらか 1 つにしてください"),
                ("fields.body.content[2]", "heading の attrs.level は 1 〜 4 にしてください"),
                ("fields.body.content[3]", "image の attrs.assetId は asset の id にしてください")
            },
            (RichText.validate("fields.body", node("paragraph", Nil)) ::: RichText.validate("fields.body", bad))
                |> List.map(violation -> { let Violation.Violation(path, message) = violation; (path, message) }))

    // ---- 取り出し ----

    /// image の assetId を集める。重複は 1 つ。
    @Test
    def testAssetIds(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "asset001", "asset002" },
            RichText.assetIds(node("doc", List#{ image("asset001", ""), node("blockquote", List#{ image("asset002", ""), image("asset001", "") }) }))
                |> List.map(AssetId.text))

    /// 平文はブロックの終わりと hardBreak で改行し、image は出ない。
    @Test
    def testToText(): Unit \ Assert =
        Assert.assertEq(expected = "見出し\na<b>\nx\ny", RichText.toText(sample()))

    // ---- HTML ----

    /// マークはタグに、文字はエスケープ、image は渡した URL で、無い asset の image は出ない。
    @Test
    def testToHtml(): Unit \ Assert =
        let images = Map#{ AssetId.AssetId("asset001") => { url = "https://cdn.example/1/asset001/写真.png", width = Some(640), height = Some(480) } };
        Assert.assertEq(
            expected = "<h2 id=\"h-1\">見出し</h2>"
                ++ "<p><strong>a</strong><a href=\"https://example.com/?a=1&amp;b=2\" target=\"_blank\" rel=\"noopener noreferrer\">&lt;b&gt;</a></p>"
                ++ "<img src=\"https://cdn.example/1/asset001/写真.png\" alt=\"写真\" width=\"640\" height=\"480\">"
                ++ "<ul><li><p>x<br>y</p></li></ul>",
            RichText.toHtml(images, sample()))

    /// 見出しの一覧。attrs.id があればそれ、無ければ出現順の h-N（id 付きの物は番号を消費しない）。html の id と同じ。
    ///
    ///   doc
    ///   ├ heading(2) "A"            → h-1
    ///   ├ heading(3, id: "intro") "B" → intro
    ///   └ blockquote ─ heading(2) "C" → h-2
    @Test
    def testHeadings(): Unit \ Assert =
        let doc = node("doc", List#{
            nodeWith("heading", List#{("level", CmsTestKit.intJson(2))}, List#{text("A")}),
            nodeWith("heading", List#{("level", CmsTestKit.intJson(3)), ("id", Json.JString("intro"))}, List#{text("B")}),
            node("blockquote", List#{nodeWith("heading", List#{("level", CmsTestKit.intJson(2))}, List#{text("C")})})
        });
        Assert.assertEq(
            expected = (List#{ (2, "A", "h-1"), (3, "B", "intro"), (2, "C", "h-2") },
                        "<h2 id=\"h-1\">A</h2><h3 id=\"intro\">B</h3><blockquote><h2 id=\"h-2\">C</h2></blockquote>"),
            (RichText.headings(doc) |> List.map(heading -> (heading#level, heading#text, heading#id)), RichText.toHtml(Map.empty(), doc)))

    /// codeBlock の language は class に出る。規則外の id と language は検査で止まる。
    @Test
    def testCodeBlockLanguageAndBadAttrs(): Unit \ Assert =
        let code = node("doc", List#{ nodeWith("codeBlock", List#{("language", Json.JString("ts"))}, List#{text("let x = 1")}) });
        let bad = node("doc", List#{
            nodeWith("heading", List#{("level", CmsTestKit.intJson(1)), ("id", Json.JString("見出し"))}, Nil),
            nodeWith("codeBlock", List#{("language", Json.JString("C++"))}, Nil)
        });
        Assert.assertEq(
            expected = ("<pre><code class=\"language-ts\">let x = 1</code></pre>", List#{ "fields.body.content[0]", "fields.body.content[1]" }),
            (RichText.toHtml(Map.empty(), code), RichText.validate("fields.body", bad) |> List.map(violation -> { let Violation.Violation(path, _) = violation; path })))

    // ---- ブログ向けの表現 ----

    def embed(url: String): Json = Json.JObject(Map#{ "type" => Json.JString("embed"), "attrs" => Json.JObject(Map#{ "url" => Json.JString(url) }) })

    def entryLink(id: String): Json = Json.JObject(Map#{ "type" => Json.JString("link"), "attrs" => Json.JObject(Map#{ "entryId" => Json.JString(id) }) })

    /// 表・コールアウト・キャプション付き画像・埋め込み・entry へのリンク。空の段落は出ない。
    @Test
    def testToHtmlBlogNodes(): Unit \ Assert =
        let doc = node("doc", List#{
            node("paragraph", Nil),
            node("table", List#{ node("tableRow", List#{ node("tableHeader", List#{ node("paragraph", List#{ text("h") }) }), node("tableCell", List#{ node("paragraph", List#{ text("c") }) }) }) }),
            nodeWith("callout", List#{("kind", Json.JString("warning"))}, List#{ node("paragraph", List#{ text("注意") }) }),
            Json.JObject(Map#{ "type" => Json.JString("image"), "attrs" => Json.JObject(Map#{ "assetId" => Json.JString("asset001"), "alt" => Json.JString("a"), "caption" => Json.JString("図 1") }) }),
            embed("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10"),
            embed("https://x.com/flixlang/status/1234567890"),
            node("paragraph", List#{ marked("関連", List#{ entryLink("b2") }) })
        });
        let images = Map#{ AssetId.AssetId("asset001") => { url = "u", width = None, height = None } };
        Assert.assertEq(
            expected = "<table><tr><th><p>h</p></th><td><p>c</p></td></tr></table>"
                ++ "<aside data-kind=\"warning\"><p>注意</p></aside>"
                ++ "<figure><img src=\"u\" alt=\"a\"><figcaption>図 1</figcaption></figure>"
                ++ "<figure data-embed=\"youtube\"><iframe src=\"https://www.youtube.com/embed/dQw4w9WgXcQ\" loading=\"lazy\" allowfullscreen allow=\"accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture\"></iframe></figure>"
                ++ "<figure data-embed=\"x\"><blockquote class=\"twitter-tweet\"><a href=\"https://x.com/flixlang/status/1234567890\">https://x.com/flixlang/status/1234567890</a></blockquote></figure>"
                ++ "<p><a href=\"#entry:b2\" data-entry-id=\"b2\">関連</a></p>",
            RichText.toHtml(images, doc))

    /// 埋め込みの URL の判定。知らない提供元と任意の iframe は通らない。
    @Test
    def testEmbedOf(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ Some((RichText.EmbedProvider.YouTube, "dQw4w9WgXcQ")), Some((RichText.EmbedProvider.Vimeo, "123456")), Some((RichText.EmbedProvider.X, "99")), None, None },
            List#{ "https://youtu.be/dQw4w9WgXcQ?si=abc", "https://vimeo.com/123456", "https://twitter.com/a_b/status/99", "https://evil.example/watch?v=dQw4w9WgXcQ", "javascript:alert(1)" }
                |> List.map(RichText.embedOf))

    /// callout の kind と embed の url は検査で止まる。entry へのリンクは entryId を集められる。
    @Test
    def testValidateBlogNodes(): Unit \ Assert =
        let bad = node("doc", List#{
            nodeWith("callout", List#{("kind", Json.JString("danger"))}, Nil),
            embed("https://evil.example/"),
            node("paragraph", List#{ marked("x", List#{ entryLink("b2") }), marked("y", List#{ entryLink("b2") }) })
        });
        Assert.assertEq(
            expected = (List#{ "fields.body.content[0]", "fields.body.content[1]" }, List#{ "b2" }),
            (RichText.validate("fields.body", bad) |> List.map(violation -> { let Violation.Violation(path, _) = violation; path }),
             RichText.linkedEntryIds(bad) |> List.map(EntryId.text)))

    /// 抜粋・語数・読了時間。日本語は 1 文字 1 語、英語は空白区切り。
    @Test
    def testDerivedValues(): Unit \ Assert =
        let long = node("doc", List#{ node("paragraph", List#{ text(String.repeat(600, "あ")) }), node("paragraph", List#{ text("hello world again") }) });
        Assert.assertEq(
            expected = ("見出し a<b> x y", "見出し a…", 603, 2),
            (RichText.excerpt(120, sample()), RichText.excerpt(5, sample()), RichText.wordCount(long), RichText.readingTimeMinutes(long)))

    /// asset が無ければ image は空。マークは先頭が一番外。
    @Test
    def testToHtmlWithoutAssetAndNestedMarks(): Unit \ Assert =
        Assert.assertEq(
            expected = "<p><strong><em>x</em></strong></p>",
            RichText.toHtml(Map.empty(), node("doc", List#{ image("asset001", ""), node("paragraph", List#{ marked("x", List#{ mark("bold"), mark("italic") }) }) })))

}
