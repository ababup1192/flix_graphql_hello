///
/// richText の doc と Markdown の双方向変換。方言の表・往復・境界・壊れた入力・RichText との整合。
///
mod TestMarkdown {

    use Util.Json.Json

    // ---- 組み立て ----

    def doc(blocks: List[Json]): Json = CmsTestKit.richNode("doc", Nil, blocks)

    def paragraph(inlines: List[Json]): Json = CmsTestKit.richNode("paragraph", Nil, inlines)

    def plain(text: String): Json = CmsTestKit.richText(Nil, text)

    def marked(kind: String, text: String): Json = CmsTestKit.richText(List#{ CmsTestKit.richMark(kind, Nil) }, text)

    def linked(href: String, text: String): Json =
        CmsTestKit.richText(List#{ CmsTestKit.richMark("link", List#{ ("href", Json.JString(href)) }) }, text)

    def entryLinked(entryId: String, text: String): Json =
        CmsTestKit.richText(List#{ CmsTestKit.richMark("link", List#{ ("entryId", Json.JString(entryId)) }) }, text)

    def heading(level: Int32, text: String): Json =
        CmsTestKit.richNode("heading", List#{ ("level", CmsTestKit.intJson(level)) }, List#{ plain(text) })

    def headingWithId(level: Int32, id: String, text: String): Json =
        CmsTestKit.richNode("heading", List#{ ("level", CmsTestKit.intJson(level)), ("id", Json.JString(id)) }, List#{ plain(text) })

    def listItem(blocks: List[Json]): Json = CmsTestKit.richNode("listItem", Nil, blocks)

    def bulletList(items: List[Json]): Json = CmsTestKit.richNode("bulletList", Nil, items)

    def orderedList(items: List[Json]): Json = CmsTestKit.richNode("orderedList", Nil, items)

    def blockquote(blocks: List[Json]): Json = CmsTestKit.richNode("blockquote", Nil, blocks)

    def callout(kind: String, blocks: List[Json]): Json = CmsTestKit.richNode("callout", List#{ ("kind", Json.JString(kind)) }, blocks)

    def codeBlock(language: Option[String], code: String): Json =
        CmsTestKit.richNode("codeBlock", language |> Option.map(found -> ("language", Json.JString(found))) |> Option.toList, List#{ plain(code) })

    def table(rows: List[Json]): Json = CmsTestKit.richNode("table", Nil, rows)

    def tableRow(cells: List[Json]): Json = CmsTestKit.richNode("tableRow", Nil, cells)

    def tableHeader(inlines: List[Json]): Json = CmsTestKit.richNode("tableHeader", Nil, List#{ paragraph(inlines) })

    def tableCell(inlines: List[Json]): Json = CmsTestKit.richNode("tableCell", Nil, List#{ paragraph(inlines) })

    def horizontalRule(): Json = CmsTestKit.richLeaf("horizontalRule", Nil)

    def hardBreak(): Json = CmsTestKit.richLeaf("hardBreak", Nil)

    def image(assetId: String, caption: Option[String], size: Option[(Int32, Int32)]): Json =
        CmsTestKit.richLeaf("image",
            (("assetId", Json.JString(assetId)) :: Nil)
                ::: (caption |> Option.map(found -> ("caption", Json.JString(found))) |> Option.toList)
                ::: (size |> Option.map(match (width, height) -> List#{ ("width", CmsTestKit.intJson(width)), ("height", CmsTestKit.intJson(height)) }) |> Option.getWithDefault(Nil)))

    def embed(url: String): Json = CmsTestKit.richLeaf("embed", List#{ ("url", Json.JString(url)) })

    def simpleParagraph(text: String): Json = paragraph(List#{ plain(text) })

    ///
    /// 方言の表。1 行 = (doc, 正規形の Markdown)。書く方向と読む方向の両方で使う。
    ///
    def dialectPairs(): List[(Json, String)] = List#{
        // paragraph: 段落は空行区切り
        (doc(List#{ simpleParagraph("段落 1"), simpleParagraph("段落 2") }), "段落 1\n\n段落 2"),
        // heading: level と attrs.id（無ければ付けない）
        (doc(List#{ heading(1, "題名") }), "# 題名"),
        (doc(List#{ headingWithId(2, "intro", "見出し") }), "## 見出し {#intro}"),
        (doc(List#{ heading(4, "小見出し") }), "#### 小見出し"),
        // bulletList / listItem: 入れ子は 2 空白
        (doc(List#{ bulletList(List#{ listItem(List#{ simpleParagraph("a") }), listItem(List#{ simpleParagraph("b"), bulletList(List#{ listItem(List#{ simpleParagraph("c") }) }) }) }) }), "- a\n- b\n  - c"),
        // orderedList: 番号は 1 から
        (doc(List#{ orderedList(List#{ listItem(List#{ simpleParagraph("a") }), listItem(List#{ simpleParagraph("b") }) }) }), "1. a\n2. b"),
        // blockquote
        (doc(List#{ blockquote(List#{ simpleParagraph("引用"), simpleParagraph("続き") }) }), "> 引用\n>\n> 続き"),
        // codeBlock: attrs.language。中身はエスケープしない
        (doc(List#{ codeBlock(Some("ts"), "const x = 1;\nconst y = *x*;") }), "```ts\nconst x = 1;\nconst y = *x*;\n```"),
        (doc(List#{ codeBlock(None, "*raw*") }), "```\n*raw*\n```"),
        // table: 1 行目が tableHeader、2 行目が区切り。セルの | は \|
        (doc(List#{ table(List#{
            tableRow(List#{ tableHeader(List#{ plain("見出し") }), tableHeader(List#{ plain("値") }) }),
            tableRow(List#{ tableCell(List#{ plain("a") }), tableCell(List#{ plain("b|c") }) }) }) }),
         "| 見出し | 値 |\n| --- | --- |\n| a | b\\|c |"),
        // callout: GitHub alerts
        (doc(List#{ callout("note", List#{ simpleParagraph("補足") }) }), "> [!NOTE]\n> 補足"),
        (doc(List#{ callout("tip", List#{ simpleParagraph("ヒント") }) }), "> [!TIP]\n> ヒント"),
        (doc(List#{ callout("warning", List#{ simpleParagraph("注意") }) }), "> [!WARNING]\n> 注意"),
        // horizontalRule
        (doc(List#{ simpleParagraph("上"), horizontalRule(), simpleParagraph("下") }), "上\n\n---\n\n下"),
        // hardBreak: 行末の \
        (doc(List#{ paragraph(List#{ plain("行 1"), hardBreak(), plain("行 2") }) }), "行 1\\\n行 2"),
        // image: caption と asset:ID。width / height があれば直後に
        (doc(List#{ image("asset001", Some("写真"), Some((640, 480))) }), "![写真](asset:asset001){width=640 height=480}"),
        (doc(List#{ image("asset001", Some("写真"), None) }), "![写真](asset:asset001)"),
        (doc(List#{ image("asset001", None, None) }), "![](asset:asset001)"),
        // embed: URL だけの段落
        (doc(List#{ embed("https://www.youtube.com/watch?v=dQw4w9WgXcQ") }), "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        (doc(List#{ embed("https://vimeo.com/123456") }), "https://vimeo.com/123456"),
        (doc(List#{ embed("https://x.com/flixlang/status/1234567890") }), "https://x.com/flixlang/status/1234567890"),
        // marks
        (doc(List#{ paragraph(List#{ plain("a "), marked("bold", "太字"), plain(" b") }) }), "a **太字** b"),
        (doc(List#{ paragraph(List#{ plain("a "), marked("italic", "斜体"), plain(" b") }) }), "a _斜体_ b"),
        (doc(List#{ paragraph(List#{ plain("a "), marked("strike", "打ち消し"), plain(" b") }) }), "a ~~打ち消し~~ b"),
        (doc(List#{ paragraph(List#{ plain("a "), marked("code", "x*y"), plain(" b") }) }), "a `x*y` b"),
        (doc(List#{ paragraph(List#{ plain("a "), marked("underline", "下線"), plain(" b") }) }), "a <u>下線</u> b"),
        (doc(List#{ paragraph(List#{ linked("https://example.com/?a=1&b=2", "外部") }) }), "[外部](https://example.com/?a=1&b=2)"),
        (doc(List#{ paragraph(List#{ entryLinked("post-1", "記事") }) }), "[記事](entry:post-1)")
    }

    ///
    /// 読む時だけ受ける形。1 行 = (Markdown, doc)。書くとこの形にはならない。
    ///
    def readOnlyPairs(): List[(String, Json)] = List#{
        // * と + の箇条書き
        ("* a\n* b", doc(List#{ bulletList(List#{ listItem(List#{ simpleParagraph("a") }), listItem(List#{ simpleParagraph("b") }) }) })),
        ("+ a", doc(List#{ bulletList(List#{ listItem(List#{ simpleParagraph("a") }) }) })),
        // 1) の番号と、1 以外から始まる番号（振り直す）
        ("1) a\n2) b", doc(List#{ orderedList(List#{ listItem(List#{ simpleParagraph("a") }), listItem(List#{ simpleParagraph("b") }) }) })),
        ("3. a\n7. b", doc(List#{ orderedList(List#{ listItem(List#{ simpleParagraph("a") }), listItem(List#{ simpleParagraph("b") }) }) })),
        // 罫線の別表記
        ("***", doc(List#{ horizontalRule() })),
        ("* * *", doc(List#{ horizontalRule() })),
        ("___", doc(List#{ horizontalRule() })),
        // 大文字小文字を問わない alert
        ("> [!Note]\n> 補足", doc(List#{ callout("note", List#{ simpleParagraph("補足") }) })),
        ("> [!warning]\n> 注意", doc(List#{ callout("warning", List#{ simpleParagraph("注意") }) })),
        // __ の太字と * の斜体
        ("__太字__", doc(List#{ paragraph(List#{ marked("bold", "太字") }) })),
        ("*斜体*", doc(List#{ paragraph(List#{ marked("italic", "斜体") }) })),
        // 行末 2 空白の hardBreak
        ("行 1  \n行 2", doc(List#{ paragraph(List#{ plain("行 1"), hardBreak(), plain("行 2") }) })),
        // 提供元でない URL だけの段落は link 付きの段落
        ("https://example.com/", doc(List#{ paragraph(List#{ linked("https://example.com/", "https://example.com/") }) })),
        // 見出しの後ろの空白と、閉じ側の #
        ("##   見出し  ", doc(List#{ heading(2, "見出し") })),
        // CRLF
        ("a\r\n\r\nb", doc(List#{ simpleParagraph("a"), simpleParagraph("b") })),
        // 末尾の改行
        ("a\n", doc(List#{ simpleParagraph("a") }))
    }

    // ---- 1. doc → Markdown ----

    /// 方言の表の doc を書くと、正規形の Markdown になる。
    @Test
    def testToMarkdownDialect(): Unit \ Assert =
        Assert.assertEq(
            expected = dialectPairs() |> List.map(match (_, markdown) -> (markdown, markdown)),
            dialectPairs() |> List.map(match (document, markdown) -> (markdown, Markdown.toMarkdown(document))))

    // ---- 2. Markdown → doc ----

    /// 方言の表の Markdown を読むと、同じ doc になる。
    @Test
    def testFromMarkdownDialect(): Unit \ Assert =
        Assert.assertEq(
            expected = dialectPairs() |> List.map(match (document, markdown) -> (markdown, document)),
            dialectPairs() |> List.map(match (_, markdown) -> (markdown, Markdown.fromMarkdown(markdown))))

    /// 読む時だけ受ける形（* の箇条書き・1) の番号・*** の罫線・[!Note]・__ と *・行末 2 空白・CRLF）。
    @Test
    def testFromMarkdownReadOnlyForms(): Unit \ Assert =
        Assert.assertEq(
            expected = readOnlyPairs(),
            readOnlyPairs() |> List.map(match (markdown, _) -> (markdown, Markdown.fromMarkdown(markdown))))

    // ---- 3. 往復 ----

    ///
    /// 全 node と全 mark を含む見本の記事。
    ///
    ///   doc
    ///   ├ heading(1, id: title)  "タイトル"
    ///   ├ paragraph  全 mark を 1 つずつ
    ///   ├ heading(2)  "見出し 2"
    ///   ├ bulletList ─ listItem "箇条書き 1" / listItem "箇条書き 2" ─ bulletList ─ listItem "入れ子"
    ///   ├ orderedList ─ listItem "番号 1" / listItem "番号 2"
    ///   ├ blockquote ─ paragraph "引用"
    ///   ├ codeBlock(ts) "const x = 1;"
    ///   ├ table ─ tableRow(tableHeader "見出し", tableHeader "値") / tableRow(tableCell **太字**, tableCell "a|b")
    ///   ├ callout(tip) ─ paragraph "ヒント"
    ///   ├ horizontalRule
    ///   ├ image(asset001, "キャプション", 640x480)
    ///   ├ embed(YouTube)
    ///   └ paragraph "行 1" hardBreak "行 2"
    ///
    def article(): Json = doc(List#{
        headingWithId(1, "title", "タイトル"),
        paragraph(List#{
            plain("これは "), marked("bold", "太字"), plain(" と "), marked("italic", "斜体"), plain(" と "), marked("strike", "打ち消し"),
            plain(" と "), marked("code", "code"), plain(" と "), marked("underline", "下線"), plain(" と "),
            linked("https://example.com/", "外部"), plain(" と "), entryLinked("post-1", "記事"), plain(" です。") }),
        heading(2, "見出し 2"),
        bulletList(List#{ listItem(List#{ simpleParagraph("箇条書き 1") }), listItem(List#{ simpleParagraph("箇条書き 2"), bulletList(List#{ listItem(List#{ simpleParagraph("入れ子") }) }) }) }),
        orderedList(List#{ listItem(List#{ simpleParagraph("番号 1") }), listItem(List#{ simpleParagraph("番号 2") }) }),
        blockquote(List#{ simpleParagraph("引用") }),
        codeBlock(Some("ts"), "const x = 1;"),
        table(List#{
            tableRow(List#{ tableHeader(List#{ plain("見出し") }), tableHeader(List#{ plain("値") }) }),
            tableRow(List#{ tableCell(List#{ marked("bold", "太字") }), tableCell(List#{ plain("a|b") }) }) }),
        callout("tip", List#{ simpleParagraph("ヒント") }),
        horizontalRule(),
        image("asset001", Some("キャプション"), Some((640, 480))),
        embed("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        paragraph(List#{ plain("行 1"), hardBreak(), plain("行 2") })
    })

    /// 見本の記事の正規形の Markdown。
    def articleMarkdown(): String =
        "# タイトル {#title}\n\n"
        ++ "これは **太字** と _斜体_ と ~~打ち消し~~ と `code` と <u>下線</u> と [外部](https://example.com/) と [記事](entry:post-1) です。\n\n"
        ++ "## 見出し 2\n\n"
        ++ "- 箇条書き 1\n- 箇条書き 2\n  - 入れ子\n\n"
        ++ "1. 番号 1\n2. 番号 2\n\n"
        ++ "> 引用\n\n"
        ++ "```ts\nconst x = 1;\n```\n\n"
        ++ "| 見出し | 値 |\n| --- | --- |\n| **太字** | a\\|b |\n\n"
        ++ "> [!TIP]\n> ヒント\n\n"
        ++ "---\n\n"
        ++ "![キャプション](asset:asset001){width=640 height=480}\n\n"
        ++ "https://www.youtube.com/watch?v=dQw4w9WgXcQ\n\n"
        ++ "行 1\\\n行 2"

    /// 見本の記事は doc → md → doc で元に戻り、md → doc → md でも元に戻る。
    @Test
    def testRoundTripArticle(): Unit \ Assert =
        Assert.assertEq(
            expected = (article(), articleMarkdown()),
            (Markdown.fromMarkdown(Markdown.toMarkdown(article())), Markdown.toMarkdown(Markdown.fromMarkdown(articleMarkdown()))))

    // ---- 4. 境界 ----

    /// 空の doc は空文字、空文字と空白だけの Markdown は空の doc。
    @Test
    def testEmpty(): Unit \ Assert =
        Assert.assertEq(
            expected = ("", doc(Nil), doc(Nil)),
            (Markdown.toMarkdown(doc(Nil)), Markdown.fromMarkdown(""), Markdown.fromMarkdown("\n\n  \n")))

    /// 空の段落は出さない。連続する空行は 1 つになる。
    @Test
    def testBlankParagraphsAndLines(): Unit \ Assert =
        Assert.assertEq(
            expected = ("a", doc(List#{ simpleParagraph("a"), simpleParagraph("b") }), "a\n\nb"),
            (Markdown.toMarkdown(doc(List#{ paragraph(Nil), simpleParagraph("a"), paragraph(Nil) })),
             Markdown.fromMarkdown("a\n\n\n\nb"),
             Markdown.toMarkdown(Markdown.fromMarkdown("a\n\n\n\nb"))))

    /// 入れ子リスト 3 段と、リスト内の codeBlock。
    @Test
    def testNestedListAndCodeInList(): Unit \ Assert =
        let nested = doc(List#{ bulletList(List#{ listItem(List#{ simpleParagraph("a"),
            orderedList(List#{ listItem(List#{ simpleParagraph("b"),
                bulletList(List#{ listItem(List#{ simpleParagraph("c") }) }) }) }) }) }) });
        let nestedMarkdown = "- a\n  1. b\n    - c";
        let codeInList = doc(List#{ bulletList(List#{ listItem(List#{ simpleParagraph("a"), codeBlock(None, "code") }), listItem(List#{ simpleParagraph("b") }) }) });
        let codeInListMarkdown = "- a\n\n  ```\n  code\n  ```\n- b";
        Assert.assertEq(
            expected = (nestedMarkdown, nested, codeInListMarkdown, codeInList),
            (Markdown.toMarkdown(nested), Markdown.fromMarkdown(nestedMarkdown), Markdown.toMarkdown(codeInList), Markdown.fromMarkdown(codeInListMarkdown)))

    /// blockquote の中の callout と、表の中の太字。
    @Test
    def testCalloutInQuoteAndBoldInTable(): Unit \ Assert =
        let quoted = doc(List#{ blockquote(List#{ callout("warning", List#{ simpleParagraph("注意") }) }) });
        let quotedMarkdown = "> > [!WARNING]\n> > 注意";
        let boldTable = doc(List#{ table(List#{ tableRow(List#{ tableHeader(List#{ marked("bold", "h") }) }), tableRow(List#{ tableCell(List#{ plain("x "), marked("italic", "c") }) }) }) });
        let boldTableMarkdown = "| **h** |\n| --- |\n| x _c_ |";
        Assert.assertEq(
            expected = (quotedMarkdown, quoted, boldTableMarkdown, boldTable),
            (Markdown.toMarkdown(quoted), Markdown.fromMarkdown(quotedMarkdown), Markdown.toMarkdown(boldTable), Markdown.fromMarkdown(boldTableMarkdown)))

    /// エスケープ対象の文字（* _ [ ] ` \ # | < > ~）は書く時にエスケープし、読むと戻る。行頭の - と 1. も段落のまま。
    @Test
    def testEscapes(): Unit \ Assert =
        let special = doc(List#{ simpleParagraph("a*b_c[d]e`f\\g#h|i<j>k~l") });
        let specialMarkdown = "a\\*b\\_c\\[d\\]e\\`f\\\\g\\#h\\|i\\<j\\>k\\~l";
        let lineStart = doc(List#{ simpleParagraph("- 箇条書きではない"), simpleParagraph("1. 番号ではない") });
        Assert.assertEq(
            expected = (specialMarkdown, special, lineStart),
            (Markdown.toMarkdown(special), Markdown.fromMarkdown(specialMarkdown), Markdown.fromMarkdown(Markdown.toMarkdown(lineStart))))

    /// 日本語と絵文字はそのまま往復する。マークの入れ子は外側のマークで括る。
    @Test
    def testUnicodeAndNestedMarks(): Unit \ Assert =
        let unicode = doc(List#{ simpleParagraph("日本語と😀の段落"), heading(2, "見出し🎉") });
        let unicodeMarkdown = "日本語と😀の段落\n\n## 見出し🎉";
        let nested = doc(List#{ paragraph(List#{
            CmsTestKit.richText(List#{ CmsTestKit.richMark("bold", Nil), CmsTestKit.richMark("italic", Nil) }, "a"),
            marked("bold", "b") }) });
        let nestedMarkdown = "**_a_b**";
        Assert.assertEq(
            expected = (unicodeMarkdown, unicode, nestedMarkdown, nested),
            (Markdown.toMarkdown(unicode), Markdown.fromMarkdown(unicodeMarkdown), Markdown.toMarkdown(nested), Markdown.fromMarkdown(nestedMarkdown)))

    // ---- 5. 壊れた入力 ----

    /// 閉じない ``` は末尾まで codeBlock、閉じない [ は文字、未知の alert は普通の blockquote。javascript: のリンクは読めるが validate で止まる。
    @Test
    def testBrokenInput(): Unit \ Assert =
        Assert.assertEq(
            expected = (
                doc(List#{ codeBlock(None, "code\nmore") }),
                doc(List#{ simpleParagraph("a [b") }),
                doc(List#{ blockquote(List#{ simpleParagraph("[!FOO]\nx") }) }),
                List#{ "fields.body.content[0].content[0].marks[0]" }),
            (Markdown.fromMarkdown("```\ncode\nmore"),
             Markdown.fromMarkdown("a [b"),
             Markdown.fromMarkdown("> [!FOO]\n> x"),
             CmsTestKit.violationPaths(RichText.validate("fields.body", Markdown.fromMarkdown("[x](javascript:alert(1))")))))

    /// 壊れた入力でも validate に通る doc を返す（規則外の言語名・見出しの id・5 段以上の見出し・規則外の asset id）。
    @Test
    def testBrokenInputStillValidates(): Unit \ Assert =
        let markdown = "```C++\nx\n```\n\n# 題 {#見出し}\n\n###### 深い\n\n![c](asset:not an id)";
        Assert.assertEq(
            expected = (Nil, doc(List#{
                codeBlock(None, "x"),
                heading(1, "題 {#見出し}"),
                heading(4, "深い"),
                simpleParagraph("![c](asset:not an id)") })),
            (RichText.validate("fields.body", Markdown.fromMarkdown(markdown)), Markdown.fromMarkdown(markdown)))

    // ---- 6. RichText との整合 ----

    /// 往復した記事は validate で Nil。平文は Markdown から記号を落とした物と同じ。
    @Test
    def testConsistentWithRichText(): Unit \ Assert =
        let roundTripped = Markdown.fromMarkdown(Markdown.toMarkdown(article()));
        Assert.assertEq(
            expected = (Nil,
                "タイトル\nこれは 太字 と 斜体 と 打ち消し と code と 下線 と 外部 と 記事 です。\n見出し 2\n箇条書き 1\n箇条書き 2\n入れ子\n番号 1\n番号 2\n引用\nconst x = 1;\n見出し\n値\n太字\na|b\nヒント\n行 1\n行 2"),
            (RichText.validate("fields.body", roundTripped),
             RichText.toText(roundTripped) |> String.replaceMatches(regex = "\n+", to = "\n")))

}
