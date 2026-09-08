///
/// richText の規則。ホワイトリストの検査、asset の取り出し、平文と HTML。
/// 本文の穴を塞ぐノード（gallery / image の alt / linkCard / codeBlock の fileName と highlightLines / details）と、
/// 数式（math / mathBlock）・Mermaid・タスクリスト（listItem の checked）・動画（video）もここ。
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
                ("fields.body.content[0]", "知らないノード 'iframe' です（paragraph, heading, bulletList, orderedList, listItem, blockquote, codeBlock, table, tableRow, tableCell, tableHeader, callout, gallery, details, text, hardBreak, horizontalRule, image, embed, linkCard, mathBlock, video）"),
                ("fields.body.content[1].content[0].marks[0]", "link は attrs.href（http(s):// か mailto:）か attrs.entryId（entry の id）のどちらか 1 つにしてください"),
                ("fields.body.content[2]", "heading の attrs.level は 1 〜 4 にしてください"),
                ("fields.body.content[3]", "image の attrs.assetId は asset の id にしてください")
            },
            (RichText.validate("fields.body", node("paragraph", Nil)) ::: RichText.validate("fields.body", bad))
                |> List.map(violation -> { let Violation.Violation(path, message) = violation; (path, message) }))

    /// link の href は http(s) と mailto だけ。javascript: / data: は大文字でも通らず、相対パスと # も通らない。
    @Test
    def testIsSafeHref(): Unit \ Assert =
        let cases = List#{
            ("https://example.com/",   true),
            ("http://example.com/",    true),
            ("mailto:a@example.com",   true),
            ("javascript:alert(1)",    false),
            ("JAVASCRIPT:alert(1)",    false),
            ("data:text/html,x",       false),
            ("/docs/intro",            false),
            ("#top",                   false),
            ("",                       false)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (href, _) -> (href, RichText.isSafeHref(href))))

    /// 見出しの id は英数字と _ - の 1 〜 64 文字。64 文字は通り、65 文字と空と記号は通らない。
    @Test
    def testIsHeadingId(): Unit \ Assert =
        let cases = List#{ (String.repeat(64, "a"), true), (String.repeat(65, "a"), false), ("intro_1-a", true), ("", false), ("見出し", false), ("a b", false) };
        Assert.assertEq(expected = cases, cases |> List.map(match (id, _) -> (id, RichText.isHeadingId(id))))

    /// heading の level は 1 〜 maxHeadingLevel。0 と maxHeadingLevel + 1 は止まり、1 と maxHeadingLevel は通る。
    @Test
    def testHeadingLevelBounds(): Unit \ Assert =
        let heading = level -> nodeWith("heading", List#{("level", CmsTestKit.intJson(level))}, Nil);
        let doc = node("doc", List#{ heading(0), heading(1), heading(RichText.maxHeadingLevel()), heading(RichText.maxHeadingLevel() + 1) });
        Assert.assertEq(
            expected = List#{ "fields.body.content[0]", "fields.body.content[3]" },
            CmsTestKit.violationPaths(RichText.validate("fields.body", doc)))

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

    /// 平文の空行: 箇条書きの項目の間は空行 1 つ、リストの後の段落との間も空行 1 つ、末尾に改行は無い。
    ///
    ///   bulletList ─ listItem ─ paragraph "x"
    ///              └ listItem ─ paragraph "y"
    ///   paragraph "後"
    @Test
    def testToTextCollapsesBlankLines(): Unit \ Assert =
        Assert.assertEq(expected = "x\n\ny\n\n後",
            RichText.toText(node("doc", List#{
                node("bulletList", List#{ node("listItem", List#{ node("paragraph", List#{ text("x") }) }), node("listItem", List#{ node("paragraph", List#{ text("y") }) }) }),
                node("paragraph", List#{ text("後") }) })))

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

    // ---- 本文の穴を塞ぐノード ----

    def gallery(columns: Option[Int32], content: List[Json]): Json =
        CmsTestKit.richNode("gallery", columns |> Option.map(found -> ("columns", CmsTestKit.intJson(found))) |> Option.toList, content)

    def imageWith(attrs: List[(String, Json)]): Json = CmsTestKit.richLeaf("image", ("assetId", Json.JString("asset001")) :: attrs)

    def linkCard(url: String): Json = CmsTestKit.richLeaf("linkCard", List#{ ("url", Json.JString(url)) })

    def codeBlockWith(attrs: List[(String, Json)], code: String): Json = CmsTestKit.richNode("codeBlock", attrs, List#{ text(code) })

    def details(summary: Option[Json], content: List[Json]): Json =
        CmsTestKit.richNode("details", summary |> Option.map(found -> ("summary", found)) |> Option.toList, content)

    /// 1 ブロックだけの doc が validate に通るか。
    def isValidDoc(block: Json): Bool = List.isEmpty(RichText.validate("fields.body", node("doc", List#{ block })))

    /// gallery の attrs.columns は 2 〜 4。無ければ通る（既定 2）。1 と 5 は止まる。
    @Test
    def testValidateGalleryColumns(): Unit \ Assert =
        let cases = List#{ (None, true), (Some(1), false), (Some(2), true), (Some(4), true), (Some(5), false) };
        Assert.assertEq(expected = cases, cases |> List.map(match (columns, _) -> (columns, isValidDoc(gallery(columns, List#{ image("asset001", "") })))))

    /// gallery の中は image だけ。paragraph が混ざればその子の場所で、空なら gallery の場所で止まる。中の image の assetId も見る。
    @Test
    def testValidateGalleryChildren(): Unit \ Assert =
        let bad = node("doc", List#{
            gallery(None, List#{ image("asset001", ""), node("paragraph", Nil) }),
            gallery(None, Nil),
            gallery(None, List#{ image("not an id!", "") })
        });
        Assert.assertEq(
            expected = List#{ "fields.body.content[0].content[1]", "fields.body.content[1]", "fields.body.content[2].content[0]" },
            CmsTestKit.violationPaths(RichText.validate("fields.body", bad)))

    /// image の attrs.alt は省略できる文字列。数値は止まる。
    @Test
    def testValidateImageAlt(): Unit \ Assert =
        let cases = List#{ (Nil, true), (List#{ ("alt", Json.JString("説明")) }, true), (List#{ ("alt", Json.JString("")) }, true), (List#{ ("alt", CmsTestKit.intJson(1)) }, false) };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (attrs, _) -> isValidDoc(imageWith(attrs))))

    /// linkCard の attrs.url は http(s) だけ。javascript: / ftp: / mailto: は止まる。
    @Test
    def testValidateLinkCard(): Unit \ Assert =
        let cases = List#{
            ("https://example.com/a",  true),
            ("http://example.com/",    true),
            ("javascript:alert(1)",    false),
            ("ftp://example.com/",     false),
            ("mailto:a@example.com",   false),
            ("",                       false)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (url, _) -> (url, isValidDoc(linkCard(url)))))

    /// codeBlock の attrs.fileName はパスの文字（英数字・日本語・/ . _ -）。空白と " < > と空は止まる。
    @Test
    def testValidateCodeBlockFileName(): Unit \ Assert =
        let cases = List#{
            ("src/a.ts",          true),
            ("ドキュメント/設定.yml", true),
            ("Makefile",          true),
            ("a b.ts",            false),
            ("a\"b",              false),
            ("<x>",               false),
            ("",                  false)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (fileName, _) -> (fileName, isValidDoc(codeBlockWith(List#{ ("fileName", Json.JString(fileName)) }, "x")))))

    /// codeBlock の attrs.highlightLines は `1,3-5` の形。文字・閉じない範囲・空は止まる。
    @Test
    def testValidateCodeBlockHighlightLines(): Unit \ Assert =
        let cases = List#{ ("1,3-5", true), ("7", true), ("2-4", true), ("a", false), ("3-", false), ("1,", false), ("", false) };
        Assert.assertEq(expected = cases, cases |> List.map(match (lines, _) -> (lines, isValidDoc(codeBlockWith(List#{ ("highlightLines", Json.JString(lines)) }, "x")))))

    /// details の attrs.summary は空でない文字列。無い・空・数値は止まる。
    @Test
    def testValidateDetailsSummary(): Unit \ Assert =
        let cases = List#{ (Some(Json.JString("補足")), true), (Some(Json.JString("")), false), (Some(Json.JString("  ")), false), (Some(CmsTestKit.intJson(1)), false), (None, false) };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (summary, _) -> isValidDoc(details(summary, List#{ node("paragraph", List#{ text("中身") }) }))))

    /// gallery は data-gallery に columns（無ければ 2）。中の image は caption の有無に関わらず figure。無い asset の image は出ない。
    @Test
    def testToHtmlGallery(): Unit \ Assert =
        let images = Map#{ AssetId.AssetId("asset001") => { url = "u1", width = Some(640), height = Some(480) }, AssetId.AssetId("asset002") => { url = "u2", width = None, height = None } };
        let doc = node("doc", List#{
            gallery(Some(3), List#{ imageWith(List#{ ("alt", Json.JString("a")) }), CmsTestKit.richLeaf("image", List#{ ("assetId", Json.JString("asset002")), ("caption", Json.JString("図 1")) }), image("asset009", "") }),
            gallery(None, List#{ imageWith(Nil) })
        });
        Assert.assertEq(
            expected = "<div data-gallery=\"3\"><figure><img src=\"u1\" alt=\"a\" width=\"640\" height=\"480\"></figure><figure><img src=\"u2\" alt=\"\"><figcaption>図 1</figcaption></figure></div>"
                ++ "<div data-gallery=\"2\"><figure><img src=\"u1\" alt=\"\" width=\"640\" height=\"480\"></figure></div>",
            RichText.toHtml(images, doc))

    /// linkCard は data-link-card 付きの a で、中身は url。文字はエスケープ。
    @Test
    def testToHtmlLinkCard(): Unit \ Assert =
        Assert.assertEq(
            expected = "<a data-link-card href=\"https://example.com/?a=1&amp;b=2\">https://example.com/?a=1&amp;b=2</a>",
            RichText.toHtml(Map.empty(), node("doc", List#{ linkCard("https://example.com/?a=1&b=2") })))

    /// codeBlock の fileName と highlightLines は pre の data 属性。language の class はそのまま。無い物は出ない。
    @Test
    def testToHtmlCodeBlockFileNameAndHighlightLines(): Unit \ Assert =
        let doc = node("doc", List#{
            codeBlockWith(List#{ ("language", Json.JString("ts")), ("fileName", Json.JString("src/a.ts")), ("highlightLines", Json.JString("1,3-5")) }, "let x = 1"),
            codeBlockWith(List#{ ("fileName", Json.JString("Makefile")) }, "check:"),
            codeBlockWith(List#{ ("highlightLines", Json.JString("2")) }, "y")
        });
        Assert.assertEq(
            expected = "<pre data-file-name=\"src/a.ts\" data-highlight-lines=\"1,3-5\"><code class=\"language-ts\">let x = 1</code></pre>"
                ++ "<pre data-file-name=\"Makefile\"><code>check:</code></pre>"
                ++ "<pre data-highlight-lines=\"2\"><code>y</code></pre>",
            RichText.toHtml(Map.empty(), doc))

    /// details は summary をエスケープして summary に、中身はそのまま。
    @Test
    def testToHtmlDetails(): Unit \ Assert =
        Assert.assertEq(
            expected = "<details><summary>&lt;補足&gt;</summary><p>中身</p><ul><li><p>x</p></li></ul></details>",
            RichText.toHtml(Map.empty(), node("doc", List#{ details(Some(Json.JString("<補足>")), List#{ node("paragraph", List#{ text("中身") }), node("bulletList", List#{ node("listItem", List#{ node("paragraph", List#{ text("x") }) }) }) }) })))

    /// 平文: gallery は中の caption を改行で（caption の無い image は出ない）、linkCard は url、details は summary と中身。
    @Test
    def testToTextNewNodes(): Unit \ Assert =
        let doc = node("doc", List#{
            gallery(Some(3), List#{ imageWith(List#{ ("caption", Json.JString("図 1")) }), imageWith(Nil), imageWith(List#{ ("caption", Json.JString("図 2")) }) }),
            linkCard("https://example.com/"),
            details(Some(Json.JString("補足")), List#{ node("paragraph", List#{ text("中身") }) })
        });
        Assert.assertEq(expected = "図 1\n図 2\nhttps://example.com/\n補足\n中身", RichText.toText(doc))

    /// assetIds は gallery の中の image も拾う。重複は 1 つ。
    @Test
    def testAssetIdsInGallery(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "asset001", "asset002" },
            RichText.assetIds(node("doc", List#{ gallery(None, List#{ image("asset001", ""), image("asset002", "") }), image("asset001", "") })) |> List.map(AssetId.text))

    /// details の中の見出しも目次に出て、h-N の番号は外と続く。
    @Test
    def testHeadingsInDetails(): Unit \ Assert =
        let doc = node("doc", List#{
            nodeWith("heading", List#{("level", CmsTestKit.intJson(2))}, List#{text("A")}),
            details(Some(Json.JString("補足")), List#{ nodeWith("heading", List#{("level", CmsTestKit.intJson(3))}, List#{text("B")}) })
        });
        Assert.assertEq(
            expected = (List#{ (2, "A", "h-1"), (3, "B", "h-2") }, "<h2 id=\"h-1\">A</h2><details><summary>補足</summary><h3 id=\"h-2\">B</h3></details>"),
            (RichText.headings(doc) |> List.map(heading -> (heading#level, heading#text, heading#id)), RichText.toHtml(Map.empty(), doc)))

    // ---- 数式 / Mermaid / タスクリスト / 動画 ----

    /// math マークだけの text。TeX はそのまま。
    def mathText(tex: String): Json = CmsTestKit.richText(List#{ CmsTestKit.richMark("math", Nil) }, tex)

    def mathBlock(attrs: List[(String, Json)]): Json = CmsTestKit.richLeaf("mathBlock", attrs)

    def listItemWith(checked: Option[Json], content: List[Json]): Json =
        CmsTestKit.richNode("listItem", checked |> Option.map(found -> ("checked", found)) |> Option.toList, content)

    def video(attrs: List[(String, Json)]): Json = CmsTestKit.richLeaf("video", attrs)

    def paragraphOf(text: Json): Json = node("paragraph", List#{ text })

    /// math は TeX が空か他のマークと混ざれば止まる。mathBlock は attrs.tex が無いか空なら止まる。
    /// listItem の attrs.checked は Bool だけ。video の attrs.assetId と poster は asset の id の形。
    @Test
    def testValidateSecondWave(): Unit \ Assert =
        let cases = List#{
            (paragraphOf(mathText("a^2")),                                                                              true),
            (paragraphOf(mathText("")),                                                                                 false),
            (paragraphOf(CmsTestKit.richText(List#{ CmsTestKit.richMark("math", Nil), mark("bold") }, "x")),           false),
            (mathBlock(List#{ ("tex", Json.JString("E=mc^2")) }),                                                       true),
            (mathBlock(Nil),                                                                                            false),
            (mathBlock(List#{ ("tex", Json.JString("  ")) }),                                                           false),
            (node("bulletList", List#{ listItemWith(Some(Json.JBool(true)), List#{ paragraphOf(text("a")) }) }),        true),
            (node("bulletList", List#{ listItemWith(Some(Json.JBool(false)), List#{ paragraphOf(text("a")) }) }),       true),
            (node("bulletList", List#{ listItemWith(Some(Json.JString("true")), List#{ paragraphOf(text("a")) }) }),    false),
            (video(List#{ ("assetId", Json.JString("asset001")) }),                                                     true),
            (video(List#{ ("assetId", Json.JString("asset001")), ("caption", Json.JString("動画")), ("poster", Json.JString("asset002")) }), true),
            (video(List#{ ("assetId", Json.JString("not an id!")) }),                                                   false),
            (video(List#{ ("assetId", Json.JString("asset001")), ("poster", Json.JString("bad!")) }),                   false),
            (video(Nil),                                                                                                false)
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (block, _) -> isValidDoc(block)))

    /// math は data-math="inline" の span、mathBlock は data-math="block" の div。TeX はエスケープする。
    @Test
    def testToHtmlMath(): Unit \ Assert =
        let doc = node("doc", List#{ node("paragraph", List#{ text("和は "), mathText("a<b") }), mathBlock(List#{ ("tex", Json.JString("x<y")) }) });
        Assert.assertEq(
            expected = "<p>和は <span data-math=\"inline\">a&lt;b</span></p><div data-math=\"block\">x&lt;y</div>",
            RichText.toHtml(Map.empty(), doc))

    /// language が mermaid の codeBlock は pre に data-diagram が付く。他の言語には付かない。
    @Test
    def testToHtmlMermaid(): Unit \ Assert =
        let doc = node("doc", List#{
            codeBlockWith(List#{ ("language", Json.JString("mermaid")) }, "graph TD;\nA-->B"),
            codeBlockWith(List#{ ("language", Json.JString("ts")) }, "x")
        });
        Assert.assertEq(
            expected = "<pre data-diagram=\"mermaid\"><code class=\"language-mermaid\">graph TD;\nA--&gt;B</code></pre><pre><code class=\"language-ts\">x</code></pre>",
            RichText.toHtml(Map.empty(), doc))

    /// listItem の checked は li の data-checked。無ければ属性無し。
    @Test
    def testToHtmlTaskList(): Unit \ Assert =
        let doc = node("doc", List#{ node("bulletList", List#{
            listItemWith(Some(Json.JBool(true)), List#{ paragraphOf(text("a")) }),
            listItemWith(Some(Json.JBool(false)), List#{ paragraphOf(text("b")) }),
            listItemWith(None, List#{ paragraphOf(text("c")) })
        }) });
        Assert.assertEq(
            expected = "<ul><li data-checked=\"true\"><p>a</p></li><li data-checked=\"false\"><p>b</p></li><li><p>c</p></li></ul>",
            RichText.toHtml(Map.empty(), doc))

    /// video は figure の中の video。src と poster は渡した asset の URL、caption は figcaption。asset が無ければ出ず、poster の asset が無ければ poster だけ出ない。
    @Test
    def testToHtmlVideo(): Unit \ Assert =
        let images = Map#{ AssetId.AssetId("asset001") => { url = "v.mp4", width = None, height = None }, AssetId.AssetId("asset002") => { url = "p.jpg", width = Some(640), height = Some(480) } };
        let doc = node("doc", List#{
            video(List#{ ("assetId", Json.JString("asset001")), ("caption", Json.JString("<動画>")), ("poster", Json.JString("asset002")) }),
            video(List#{ ("assetId", Json.JString("asset001")) }),
            video(List#{ ("assetId", Json.JString("asset009")) }),
            video(List#{ ("assetId", Json.JString("asset001")), ("poster", Json.JString("asset009")) })
        });
        Assert.assertEq(
            expected = "<figure><video controls src=\"v.mp4\" poster=\"p.jpg\"></video><figcaption>&lt;動画&gt;</figcaption></figure>"
                ++ "<figure><video controls src=\"v.mp4\"></video></figure>"
                ++ "<figure><video controls src=\"v.mp4\"></video></figure>",
            RichText.toHtml(images, doc))

    /// 平文では math と mathBlock の TeX がそのまま出る。
    @Test
    def testToTextMath(): Unit \ Assert =
        let doc = node("doc", List#{ node("paragraph", List#{ text("和は "), mathText("a^2") }), mathBlock(List#{ ("tex", Json.JString("E=mc^2")) }) });
        Assert.assertEq(expected = "和は a^2\nE=mc^2", RichText.toText(doc))

    /// assetIds は video の assetId と poster の両方を拾う。重複は 1 つ。
    @Test
    def testAssetIdsVideo(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "asset001", "asset002" },
            RichText.assetIds(node("doc", List#{ video(List#{ ("assetId", Json.JString("asset001")), ("poster", Json.JString("asset002")) }), image("asset001", "") })) |> List.map(AssetId.text))

}
