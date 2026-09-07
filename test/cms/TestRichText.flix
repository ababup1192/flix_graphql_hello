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
                ("fields.body.content[0]", "知らないノード 'iframe' です（paragraph, heading, bulletList, orderedList, listItem, blockquote, codeBlock, text, hardBreak, horizontalRule, image）"),
                ("fields.body.content[1].content[0].marks[0]", "link の href は http(s):// か mailto: で始めてください"),
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
        let urls = Map#{ AssetId.AssetId("asset001") => "https://cdn.example/1/asset001/写真.png" };
        Assert.assertEq(
            expected = "<h2>見出し</h2>"
                ++ "<p><strong>a</strong><a href=\"https://example.com/?a=1&amp;b=2\" rel=\"noopener\">&lt;b&gt;</a></p>"
                ++ "<img src=\"https://cdn.example/1/asset001/写真.png\" alt=\"写真\">"
                ++ "<ul><li><p>x<br>y</p></li></ul>",
            RichText.toHtml(urls, sample()))

    /// asset が無ければ image は空。マークは先頭が一番外。
    @Test
    def testToHtmlWithoutAssetAndNestedMarks(): Unit \ Assert =
        Assert.assertEq(
            expected = "<p><strong><em>x</em></strong></p>",
            RichText.toHtml(Map.empty(), node("doc", List#{ image("asset001", ""), node("paragraph", List#{ marked("x", List#{ mark("bold"), mark("italic") }) }) })))

}
