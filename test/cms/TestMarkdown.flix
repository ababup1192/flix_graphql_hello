///
/// richText の doc と Markdown の双方向変換。方言の表・往復・境界・壊れた入力・RichText との整合。
/// 本文の穴を塞ぐノード（gallery / image の alt / linkCard / codeBlock の fileName と highlightLines / details）と、
/// 数式（`$…$` `$$`）・Mermaid・タスクリスト（`- [ ]`）・動画（`@[video]`）の方言もここ。
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

    /// 結合したセル。colspan / rowspan は 2 以上の時だけ attrs に出る。
    def spanHeader(colspan: Int32, rowspan: Int32, inlines: List[Json]): Json =
        CmsTestKit.richNode("tableHeader", spanAttrs(colspan, rowspan), List#{ paragraph(inlines) })

    def spanCell(colspan: Int32, rowspan: Int32, inlines: List[Json]): Json =
        CmsTestKit.richNode("tableCell", spanAttrs(colspan, rowspan), List#{ paragraph(inlines) })

    def spanAttrs(colspan: Int32, rowspan: Int32): List[(String, Json)] =
        (if (colspan > 1) List#{ ("colspan", CmsTestKit.intJson(colspan)) } else Nil)
            ::: (if (rowspan > 1) List#{ ("rowspan", CmsTestKit.intJson(rowspan)) } else Nil)

    def alignedHeader(align: String, inlines: List[Json]): Json =
        CmsTestKit.richNode("tableHeader", List#{ ("align", Json.JString(align)) }, List#{ paragraph(inlines) })

    def alignedCell(align: String, inlines: List[Json]): Json =
        CmsTestKit.richNode("tableCell", List#{ ("align", Json.JString(align)) }, List#{ paragraph(inlines) })

    def horizontalRule(): Json = CmsTestKit.richLeaf("horizontalRule", Nil)

    def hardBreak(): Json = CmsTestKit.richLeaf("hardBreak", Nil)

    /// 画像 1 枚（image の中の imageItem）。caption は content の text 1 つ（無ければ content 自体を付けない）。
    def picture(assetId: String, alt: Option[String], caption: Option[String], size: Option[(Int32, Int32)]): Json =
        let attrs =
            (("assetId", Json.JString(assetId)) :: Nil)
                ::: (alt |> Option.map(found -> ("alt", Json.JString(found))) |> Option.toList)
                ::: (size |> Option.map(match (width, height) -> List#{ ("width", CmsTestKit.intJson(width)), ("height", CmsTestKit.intJson(height)) }) |> Option.getWithDefault(Nil));
        match caption {
            case Some(found) => CmsTestKit.richNode("imageItem", attrs, List#{ plain(found) })
            case None        => CmsTestKit.richLeaf("imageItem", attrs)
        }

    /// 画像の塊。1 枚でも複数枚でも同じ image。
    def pictures(items: List[Json]): Json = CmsTestKit.richNode("image", Nil, items)

    /// 1 枚だけの image。
    def image(assetId: String, alt: Option[String], caption: Option[String], size: Option[(Int32, Int32)]): Json =
        pictures(List#{ picture(assetId, alt, caption, size) })

    def embed(url: String): Json = CmsTestKit.richLeaf("embed", List#{ ("url", Json.JString(url)) })

    def linkCard(url: String): Json = CmsTestKit.richLeaf("linkCard", List#{ ("url", Json.JString(url)) })

    def codeBlockWith(language: Option[String], fileName: Option[String], highlightLines: Option[String], code: String): Json =
        CmsTestKit.richNode("codeBlock",
            (language |> Option.map(found -> ("language", Json.JString(found))) |> Option.toList)
                ::: (fileName |> Option.map(found -> ("fileName", Json.JString(found))) |> Option.toList)
                ::: (highlightLines |> Option.map(found -> ("highlightLines", Json.JString(found))) |> Option.toList),
            List#{ plain(code) })

    def details(summary: String, blocks: List[Json]): Json = CmsTestKit.richNode("details", List#{ ("summary", Json.JString(summary)) }, blocks)

    def simpleParagraph(text: String): Json = paragraph(List#{ plain(text) })

    def mathText(tex: String): Json = marked("math", tex)

    def mathBlock(tex: String): Json = CmsTestKit.richLeaf("mathBlock", List#{ ("tex", Json.JString(tex)) })

    def taskItem(checked: Bool, blocks: List[Json]): Json = CmsTestKit.richNode("listItem", List#{ ("checked", Json.JBool(checked)) }, blocks)

    def video(assetId: String, caption: Option[String], poster: Option[String]): Json =
        CmsTestKit.richLeaf("video",
            (("assetId", Json.JString(assetId)) :: Nil)
                ::: (caption |> Option.map(found -> ("caption", Json.JString(found))) |> Option.toList)
                ::: (poster |> Option.map(found -> ("poster", Json.JString(found))) |> Option.toList))

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
        // table の寄せ: 区切り行の : が列の寄せ。**列の全セルが同じ値を持つ**
        (doc(List#{ table(List#{
            tableRow(List#{ alignedHeader("left", List#{ plain("名") }), alignedHeader("center", List#{ plain("印") }), alignedHeader("right", List#{ plain("額") }) }),
            tableRow(List#{ alignedCell("left", List#{ plain("a") }), alignedCell("center", List#{ plain("b") }), alignedCell("right", List#{ plain("c") }) }) }) }),
         "| 名 | 印 | 額 |\n| :--- | :---: | ---: |\n| a | b | c |"),
        // table のセルの結合: 中身の後ろに {colspan=N rowspan=N}。覆われる所には空のセルを置く
        (doc(List#{ table(List#{
            tableRow(List#{ spanHeader(2, 1, List#{ plain("見出し") }) }),
            tableRow(List#{ tableCell(List#{ plain("a") }), tableCell(List#{ plain("b") }) }) }) }),
         "| 見出し {colspan=2} |  |\n| --- | --- |\n| a | b |"),
        (doc(List#{ table(List#{
            tableRow(List#{ tableHeader(List#{ plain("h1") }), tableHeader(List#{ plain("h2") }) }),
            tableRow(List#{ spanCell(1, 2, List#{ plain("A") }), tableCell(List#{ plain("b") }) }),
            tableRow(List#{ tableCell(List#{ plain("c") }) }) }) }),
         "| h1 | h2 |\n| --- | --- |\n| A {rowspan=2} | b |\n|  | c |"),
        (doc(List#{ table(List#{
            tableRow(List#{ spanHeader(2, 2, List#{ plain("角") }), tableHeader(List#{ plain("h") }) }),
            tableRow(List#{ tableCell(List#{ plain("x") }) }),
            tableRow(List#{ tableCell(List#{ plain("a") }), tableCell(List#{ plain("b") }), tableCell(List#{ plain("c") }) }) }) }),
         "| 角 {colspan=2 rowspan=2} |  | h |\n| --- | --- | --- |\n|  |  | x |\n| a | b | c |"),
        // 上付き・下付き・蛍光ペン。**マークダウンに広く通っている書き方に寄せる。**
        (doc(List#{ paragraph(List#{ plain("H"), marked("sub", "2"), plain("O") }) }), "H~2~O"),
        (doc(List#{ paragraph(List#{ plain("m"), marked("sup", "2") }) }), "m^2^"),
        (doc(List#{ paragraph(List#{ plain("ここが "), marked("highlight", "大事"), plain(" です") }) }), "ここが ==大事== です"),
        // callout: GitHub alerts
        (doc(List#{ callout("note", List#{ simpleParagraph("補足") }) }), "> [!NOTE]\n> 補足"),
        (doc(List#{ callout("tip", List#{ simpleParagraph("ヒント") }) }), "> [!TIP]\n> ヒント"),
        (doc(List#{ callout("warning", List#{ simpleParagraph("注意") }) }), "> [!WARNING]\n> 注意"),
        // horizontalRule
        (doc(List#{ simpleParagraph("上"), horizontalRule(), simpleParagraph("下") }), "上\n\n---\n\n下"),
        // hardBreak: 行末の \
        (doc(List#{ paragraph(List#{ plain("行 1"), hardBreak(), plain("行 2") }) }), "行 1\\\n行 2"),
        // image: `![alt](asset:ID)`。[] が alt、caption は直後の行に `*…*`。alt と caption の 4 通り。width / height があれば直後に
        (doc(List#{ image("asset001", None, None, None) }), "![](asset:asset001)"),
        (doc(List#{ image("asset001", Some("説明"), None, None) }), "![説明](asset:asset001)"),
        (doc(List#{ image("asset001", None, Some("写真"), None) }), "![](asset:asset001)\n*写真*"),
        (doc(List#{ image("asset001", Some("説明"), Some("写真"), None) }), "![説明](asset:asset001)\n*写真*"),
        (doc(List#{ image("asset001", Some("説明"), Some("写真"), Some((640, 480))) }), "![説明](asset:asset001){width=640 height=480}\n*写真*"),
        (doc(List#{ image("asset001", None, Some("引用 \"符\""), None) }), "![](asset:asset001)\n*引用 \"符\"*"),
        // 複数枚: 1 行に画像を 2 つ以上、空白区切り。列数は書かない（枚数から決まる）。caption は次の行に枚数だけ `*…*`（無い画像は `**`）
        (doc(List#{ pictures(List#{ picture("asset001", None, None, None), picture("asset002", None, Some("図 2"), None) }) }), "![](asset:asset001) ![](asset:asset002)\n** *図 2*"),
        (doc(List#{ pictures(List#{ picture("asset001", None, None, None), picture("asset002", None, None, Some((640, 480))), picture("asset003", Some("c"), None, None) }) }), "![](asset:asset001) ![](asset:asset002){width=640 height=480} ![c](asset:asset003)"),
        // 複数枚の alt も 1 枚の時と同じく [] に入る（caption の位置に移らない）
        (doc(List#{ pictures(List#{ picture("asset001", Some("a"), None, None), picture("asset002", Some("b"), Some("図"), None) }) }), "![a](asset:asset001) ![b](asset:asset002)\n** *図*"),
        (doc(List#{ pictures(List#{ picture("asset001", None, None, None), picture("asset002", None, None, None), picture("asset003", None, None, None), picture("asset004", None, None, None), picture("asset005", None, None, None) }) }), "![](asset:asset001) ![](asset:asset002) ![](asset:asset003) ![](asset:asset004) ![](asset:asset005)"),
        (doc(List#{ pictures(List#{ picture("asset001", None, None, None), picture("asset002", None, None, None) }) }), "![](asset:asset001) ![](asset:asset002)"),
        // embed: URL だけの段落
        (doc(List#{ embed("https://www.youtube.com/watch?v=dQw4w9WgXcQ") }), "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        (doc(List#{ embed("https://vimeo.com/123456") }), "https://vimeo.com/123456"),
        (doc(List#{ embed("https://x.com/flixlang/status/1234567890") }), "https://x.com/flixlang/status/1234567890"),
        // linkCard: URL だけの段落で、提供元でない物
        (doc(List#{ linkCard("https://example.com/") }), "https://example.com/"),
        (doc(List#{ linkCard("http://example.com/a?b=1&c=2") }), "http://example.com/a?b=1&c=2"),
        // codeBlock: ```言語:ファイル名 {行}。言語無しは `:` から、行だけは空白の後ろ
        (doc(List#{ codeBlockWith(Some("ts"), Some("src/a.ts"), Some("1,3-5"), "const x = 1;") }), "```ts:src/a.ts {1,3-5}\nconst x = 1;\n```"),
        (doc(List#{ codeBlockWith(None, Some("src/a.ts"), None, "x") }), "```:src/a.ts\nx\n```"),
        (doc(List#{ codeBlockWith(Some("ts"), None, Some("2"), "x") }), "```ts {2}\nx\n```"),
        (doc(List#{ codeBlockWith(None, None, Some("2-3"), "x") }), "``` {2-3}\nx\n```"),
        // details: GitHub がそのまま畳む形。summary の行、空行、中身、空行、閉じ
        (doc(List#{ details("補足", List#{ simpleParagraph("中身"), bulletList(List#{ listItem(List#{ simpleParagraph("a") }) }) }) }), "<details><summary>補足</summary>\n\n中身\n\n- a\n\n</details>"),
        (doc(List#{ details("空", Nil) }), "<details><summary>空</summary>\n\n</details>"),
        // marks
        (doc(List#{ paragraph(List#{ plain("a "), marked("bold", "太字"), plain(" b") }) }), "a **太字** b"),
        (doc(List#{ paragraph(List#{ plain("a "), marked("italic", "斜体"), plain(" b") }) }), "a _斜体_ b"),
        (doc(List#{ paragraph(List#{ plain("a "), marked("strike", "打ち消し"), plain(" b") }) }), "a ~~打ち消し~~ b"),
        (doc(List#{ paragraph(List#{ plain("a "), marked("code", "x*y"), plain(" b") }) }), "a `x*y` b"),
        (doc(List#{ paragraph(List#{ plain("a "), marked("underline", "下線"), plain(" b") }) }), "a <u>下線</u> b"),
        (doc(List#{ paragraph(List#{ linked("https://example.com/?a=1&b=2", "外部") }) }), "[外部](https://example.com/?a=1&b=2)"),
        (doc(List#{ paragraph(List#{ entryLinked("post-1", "記事") }) }), "[記事](entry:post-1)"),
        // math: `$…$`。TeX はそのまま。text の中の $ は \$
        (doc(List#{ paragraph(List#{ plain("和は "), mathText("a^2 + b_1"), plain(" です") }) }), "和は $a^2 + b_1$ です"),
        (doc(List#{ simpleParagraph("価格は $10 です") }), "価格は \\$10 です"),
        // mathBlock: `$$` の行で囲む。中身はエスケープしない
        (doc(List#{ mathBlock("E = mc^2\n\\frac{1}{2}") }), "$$\nE = mc^2\n\\frac{1}{2}\n$$"),
        // Mermaid: 普通の codeBlock
        (doc(List#{ codeBlock(Some("mermaid"), "graph TD;\nA-->B") }), "```mermaid\ngraph TD;\nA-->B\n```"),
        // タスクリスト: listItem の checked は `- [ ]` `- [x]`。無ければ普通の項目。orderedList でも同じ
        (doc(List#{ bulletList(List#{ taskItem(true, List#{ simpleParagraph("a") }), taskItem(false, List#{ simpleParagraph("b") }), listItem(List#{ simpleParagraph("c") }) }) }), "- [x] a\n- [ ] b\n- c"),
        (doc(List#{ orderedList(List#{ taskItem(false, List#{ simpleParagraph("a") }) }) }), "1. [ ] a"),
        // video: `@[video](asset:ID "caption"){poster=asset:ID}`
        (doc(List#{ video("asset001", None, None) }), "@[video](asset:asset001)"),
        (doc(List#{ video("asset001", Some("動画"), None) }), "@[video](asset:asset001 \"動画\")"),
        (doc(List#{ video("asset001", None, Some("asset002")) }), "@[video](asset:asset001){poster=asset:asset002}"),
        (doc(List#{ video("asset001", Some("動画"), Some("asset002")) }), "@[video](asset:asset001 \"動画\"){poster=asset:asset002}")
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
        // 古い形: title の caption は読む時だけ受ける（content に写す）。空の title は caption 無し
        ("![写真](asset:asset001 \"図\")", doc(List#{ image("asset001", Some("写真"), Some("図"), None) })),
        ("![写真](asset:asset001 \"\")", doc(List#{ image("asset001", Some("写真"), None, None) })),
        ("![写真](asset:asset001 \"\"){width=640 height=480}", doc(List#{ image("asset001", Some("写真"), None, Some((640, 480))) })),
        ("![](asset:asset001 \"a\") ![](asset:asset002 \"b\")", doc(List#{ pictures(List#{ picture("asset001", None, Some("a"), None), picture("asset002", None, Some("b"), None) }) })),
        // asset 管理外の画像（`![alt](URL)`）は image にならず、alt を URL へのリンクにした文字になる
        ("![外部](https://example.com/a.png)", doc(List#{ paragraph(List#{ linked("https://example.com/a.png", "外部") }) })),
        ("前 ![外部](https://example.com/a.png) 後", doc(List#{ paragraph(List#{ plain("前 "), linked("https://example.com/a.png", "外部"), plain(" 後") }) })),
        // 古い `{columns=N}` は読んで捨てる（列数は枚数から決まる）
        ("![](asset:asset001) ![](asset:asset002) {columns=9}", doc(List#{ pictures(List#{ picture("asset001", None, None, None), picture("asset002", None, None, None) }) })),
        ("![](asset:asset001) ![](asset:asset002) {columns=1}", doc(List#{ pictures(List#{ picture("asset001", None, None, None), picture("asset002", None, None, None) }) })),
        ("![](asset:asset001)   ![](asset:asset002)  {columns=2}", doc(List#{ pictures(List#{ picture("asset001", None, None, None), picture("asset002", None, None, None) }) })),
        // summary の無い details は「詳細」。中身の前後の空行は無くてもよい
        ("<details>\n中身\n</details>", doc(List#{ details("詳細", List#{ simpleParagraph("中身") }) })),
        // 閉じない details は末尾まで
        ("<details><summary>補足</summary>\n\n中身\n\n続き", doc(List#{ details("補足", List#{ simpleParagraph("中身"), simpleParagraph("続き") }) })),
        // 見出しの後ろの空白と、閉じ側の #
        ("##   見出し  ", doc(List#{ heading(2, "見出し") })),
        // CRLF
        ("a\r\n\r\nb", doc(List#{ simpleParagraph("a"), simpleParagraph("b") })),
        // 末尾の改行
        ("a\n", doc(List#{ simpleParagraph("a") })),
        // 大文字の X も済みと読む
        ("- [X] a", doc(List#{ bulletList(List#{ taskItem(true, List#{ simpleParagraph("a") }) }) })),
        // `$$` の行の後ろの空白
        ("$$  \nx\n$$  ", doc(List#{ mathBlock("x") }))
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

    ///
    /// 結合の値が壊れている時は 1 として読む（`{…}` 自体は colspan / rowspan があれば落とす）。
    /// colspan / rowspan を持たない `{…}` はセルの文字として残す。
    ///
    def brokenSpanPairs(): List[(String, Json)] = List#{
        ("| a {colspan=0} | b |\n| --- | --- |", doc(List#{ table(List#{ tableRow(List#{ tableHeader(List#{ plain("a") }), tableHeader(List#{ plain("b") }) }) }) })),
        ("| a {colspan=abc} | b |\n| --- | --- |", doc(List#{ table(List#{ tableRow(List#{ tableHeader(List#{ plain("a") }), tableHeader(List#{ plain("b") }) }) }) })),
        ("| a {rowspan=99999} | b |\n| --- | --- |", doc(List#{ table(List#{ tableRow(List#{ tableHeader(List#{ plain("a") }), tableHeader(List#{ plain("b") }) }) }) })),
        ("| a {colspan=2 foo=1} | b |\n| --- | --- |", doc(List#{ table(List#{ tableRow(List#{ spanHeader(2, 1, List#{ plain("a") }) }) }) })),
        ("| a {foo=1} | b |\n| --- | --- |", doc(List#{ table(List#{ tableRow(List#{ tableHeader(List#{ plain("a {foo=1}") }), tableHeader(List#{ plain("b") }) }) }) }))
    }

    @Test
    def testFromMarkdownBrokenSpan(): Unit \ Assert =
        Assert.assertEq(
            expected = brokenSpanPairs() |> List.map(snd),
            brokenSpanPairs() |> List.map(fst) |> List.map(Markdown.fromMarkdown))

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
    ///   ├ image(asset001, alt "説明", "キャプション", 640x480)
    ///   ├ embed(YouTube)
    ///   ├ gallery(3) ─ image(asset002) / image(asset003, "図 2") / image(asset004, alt "d")
    ///   ├ linkCard(https://example.com/card)
    ///   ├ codeBlock(ts, src/a.ts, 1,3-5) "const y = 2;"
    ///   ├ details("補足") ─ paragraph "畳んだ中身" / gallery(2) ─ image(asset005) / image(asset006)
    ///   ├ paragraph "和は " math "a^2" " で $10"
    ///   ├ mathBlock "E = mc^2"
    ///   ├ codeBlock(mermaid) "graph TD;\nA-->B"
    ///   ├ bulletList ─ listItem(checked) "済み" / listItem(unchecked) "未着手"
    ///   ├ video(asset007, "動画", poster asset008)
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
        image("asset001", Some("説明"), Some("キャプション"), Some((640, 480))),
        embed("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        pictures(List#{ picture("asset002", None, None, None), picture("asset003", None, Some("図 2"), None), picture("asset004", Some("d"), None, None) }),
        linkCard("https://example.com/card"),
        codeBlockWith(Some("ts"), Some("src/a.ts"), Some("1,3-5"), "const y = 2;"),
        details("補足", List#{ simpleParagraph("畳んだ中身"), pictures(List#{ picture("asset005", None, None, None), picture("asset006", None, None, None) }) }),
        paragraph(List#{ plain("和は "), mathText("a^2"), plain(" で $10") }),
        mathBlock("E = mc^2"),
        codeBlock(Some("mermaid"), "graph TD;\nA-->B"),
        bulletList(List#{ taskItem(true, List#{ simpleParagraph("済み") }), taskItem(false, List#{ simpleParagraph("未着手") }) }),
        video("asset007", Some("動画"), Some("asset008")),
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
        ++ "![説明](asset:asset001){width=640 height=480}\n*キャプション*\n\n"
        ++ "https://www.youtube.com/watch?v=dQw4w9WgXcQ\n\n"
        ++ "![](asset:asset002) ![](asset:asset003) ![d](asset:asset004)\n** *図 2* **\n\n"
        ++ "https://example.com/card\n\n"
        ++ "```ts:src/a.ts {1,3-5}\nconst y = 2;\n```\n\n"
        ++ "<details><summary>補足</summary>\n\n畳んだ中身\n\n![](asset:asset005) ![](asset:asset006)\n\n</details>\n\n"
        ++ "和は $a^2$ で \\$10\n\n"
        ++ "$$\nE = mc^2\n$$\n\n"
        ++ "```mermaid\ngraph TD;\nA-->B\n```\n\n"
        ++ "- [x] 済み\n- [ ] 未着手\n\n"
        ++ "@[video](asset:asset007 \"動画\"){poster=asset:asset008}\n\n"
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

    ///
    /// 見出し行の無い表（全セルが tableCell）は、空の見出し行を挟んで書き出し、読み戻すと同じ形に戻る。
    ///
    ///   | (空) | (空) |
    ///   | ---  | ---  |
    ///   | a    | b    |
    ///   | c    | d    |
    ///
    @Test
    def testHeaderlessTableRoundTrip(): Unit \ Assert =
        let headerless = doc(List#{ table(List#{
            tableRow(List#{ tableCell(List#{ plain("a") }), tableCell(List#{ plain("b") }) }),
            tableRow(List#{ tableCell(List#{ plain("c") }), tableCell(List#{ plain("d") }) }) }) });
        let headerlessMarkdown = "|  |  |\n| --- | --- |\n| a | b |\n| c | d |";
        Assert.assertEq(
            expected = (headerlessMarkdown, headerless, headerless),
            (Markdown.toMarkdown(headerless), Markdown.fromMarkdown(headerlessMarkdown),
             Markdown.fromMarkdown(Markdown.toMarkdown(headerless))))

    ///
    /// 括弧の対応を数えて閉じる位置を返す（`closingBracket` / `closingParen`）。
    /// 入れ子・エスケープ・閉じが無い・文字列の終わりで切れる、の境界を link の切れ目で見る。
    ///
    def bracketPairs(): List[(String, Json)] = List#{
        // 入れ子の `[` は対応する `]` まで数える（内側で切らない）
        ("[a[b]c](https://example.com/)", doc(List#{ paragraph(List#{ linked("https://example.com/", "a[b]c") }) })),
        // `\` の次の `]` は数えない
        ("[a\\]b](https://example.com/)", doc(List#{ paragraph(List#{ linked("https://example.com/", "a]b") }) })),
        // 入れ子の `(` は対応する `)` まで数える
        ("[a](https://example.com/x(y)z)", doc(List#{ paragraph(List#{ linked("https://example.com/x(y)z", "a") }) })),
        // 閉じる `]` が無ければ link にせず文字のまま
        ("[a(https://example.com/)", doc(List#{ simpleParagraph("[a(https://example.com/)") })),
        // 閉じる `)` が無ければ link にせず文字のまま
        ("[a](https://example.com/", doc(List#{ simpleParagraph("[a](https://example.com/") })),
        // 文字列の終わりが `\` でも数え続けない
        ("[a\\", doc(List#{ simpleParagraph("[a\\") }))
    }

    @Test
    def testFromMarkdownBrackets(): Unit \ Assert =
        Assert.assertEq(
            expected = bracketPairs(),
            bracketPairs() |> List.map(match (markdown, _) -> (markdown, Markdown.fromMarkdown(markdown))))

    /// エスケープ対象の文字（* _ [ ] ` \ # | < > ~ ^ =）は書く時にエスケープし、読むと戻る。行頭の - と 1. も段落のまま。
    /// 平文の `2^10^` は上付きに、`m==n` はハイライトにならない。
    @Test
    def testEscapes(): Unit \ Assert =
        let special = doc(List#{ simpleParagraph("a*b_c[d]e`f\\g#h|i<j>k~l2^10^m==n") });
        let specialMarkdown = "a\\*b\\_c\\[d\\]e\\`f\\\\g\\#h\\|i\\<j\\>k\\~l2\\^10\\^m\\=\\=n";
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

    /// 閉じない ``` は末尾まで codeBlock、閉じない [ は文字、未知の alert は普通の blockquote。javascript: のリンクは link マークが落ちて validate を通る。
    @Test
    def testBrokenInput(): Unit \ Assert =
        Assert.assertEq(
            expected = (
                doc(List#{ codeBlock(None, "code\nmore") }),
                doc(List#{ simpleParagraph("a [b") }),
                doc(List#{ blockquote(List#{ simpleParagraph("[!FOO]\nx") }) }),
                Nil),
            (Markdown.fromMarkdown("```\ncode\nmore"),
             Markdown.fromMarkdown("a [b"),
             Markdown.fromMarkdown("> [!FOO]\n> x"),
             CmsTestKit.violationPaths(RichText.validate("fields.body", Markdown.fromMarkdown("[x](javascript:alert(1))")))))

    ///
    /// 相対リンク（`/` で始まるパスと `#` の断片）は link マークが残る。
    /// validate を通らない href（javascript: / data: / vbscript: / `//` の protocol-relative / scheme の無い相対パス）は
    /// link マークだけ落ちて文字が残り、doc は違反ゼロで返る。
    ///
    @Test
    def testRelativeAndUnsafeLinks(): Unit \ Assert =
        let cases = List#{
            ("[会社概要](/about)",       doc(List#{ paragraph(List#{ linked("/about", "会社概要") }) })),
            ("[上へ](#top)",             doc(List#{ paragraph(List#{ linked("#top", "上へ") }) })),
            ("[x](javascript:alert(1))", doc(List#{ simpleParagraph("x") })),
            ("[x](JaVaScRiPt:alert(1))", doc(List#{ simpleParagraph("x") })),
            ("[x](data:text/html,y)",    doc(List#{ simpleParagraph("x") })),
            ("[x](vbscript:msgbox(1))",  doc(List#{ simpleParagraph("x") })),
            ("[x](//evil.example.com/)", doc(List#{ simpleParagraph("x") })),
            ("[x](about.html)",          doc(List#{ simpleParagraph("x") }))
        };
        Assert.assertEq(
            expected = cases |> List.map(match (markdown, expectedDoc) -> (markdown, expectedDoc, Nil)),
            cases |> List.map(match (markdown, _) ->
                (markdown, Markdown.fromMarkdown(markdown), CmsTestKit.violationPaths(RichText.validate("fields.body", Markdown.fromMarkdown(markdown))))))

    /// 1 行に画像と文字が混ざれば普通の段落（gallery にも image にもならない）。閉じない details は末尾まで、`</details>` だけの行は何も作らない。
    @Test
    def testBrokenNewNodes(): Unit \ Assert =
        Assert.assertEq(
            expected = (
                doc(List#{ simpleParagraph("![](asset:asset001) と ![](asset:asset002)") }),
                doc(List#{ simpleParagraph("![](asset:asset001) 説明") }),
                doc(List#{ details("補足", List#{ simpleParagraph("a") }), simpleParagraph("b") }),
                doc(List#{ simpleParagraph("a") })),
            (Markdown.fromMarkdown("![](asset:asset001) と ![](asset:asset002)"),
             Markdown.fromMarkdown("![](asset:asset001) 説明"),
             Markdown.fromMarkdown("<details><summary>補足</summary>\na\n</details>\nb"),
             Markdown.fromMarkdown("</details>\na")))

    /// 閉じない `$$` は末尾まで mathBlock、中身の無い `$$` は何も作らない。`$` が 1 つだけの文と `- [ ]` の後に何も無い項目は文字のまま。
    /// `[ ] a` で始まる段落の項目は書く時にエスケープされ、タスクにならず往復する。
    @Test
    def testBrokenSecondWave(): Unit \ Assert =
        let bracketItem = doc(List#{ bulletList(List#{ listItem(List#{ simpleParagraph("[ ] a") }) }) });
        Assert.assertEq(
            expected = (
                doc(List#{ mathBlock("x\ny") }),
                doc(Nil),
                doc(List#{ simpleParagraph("a $ b") }),
                doc(List#{ bulletList(List#{ listItem(List#{ simpleParagraph("[ ]") }) }) }),
                bracketItem),
            (Markdown.fromMarkdown("$$\nx\ny"),
             Markdown.fromMarkdown("$$\n$$"),
             Markdown.fromMarkdown("a $ b"),
             Markdown.fromMarkdown("- [ ]"),
             Markdown.fromMarkdown(Markdown.toMarkdown(bracketItem))))

    /// 壊れた入力でも validate に通る doc を返す（規則外の言語名・見出しの id・5 段以上の見出し・規則外の asset id・規則外のファイル名と行）。
    @Test
    def testBrokenInputStillValidates(): Unit \ Assert =
        let markdown = "```C++\nx\n```\n\n# 題 {#見出し}\n\n###### 深い\n\n![c](asset:not an id)\n\n```ts:a<b {3-}\ny\n```";
        Assert.assertEq(
            expected = (Nil, doc(List#{
                codeBlock(None, "x"),
                heading(1, "題 {#見出し}"),
                heading(4, "深い"),
                simpleParagraph("![c](asset:not an id)"),
                codeBlock(Some("ts"), "y") })),
            (RichText.validate("fields.body", Markdown.fromMarkdown(markdown)), Markdown.fromMarkdown(markdown)))

    // ---- 6. RichText との整合 ----

    /// 入れ子で書いた Markdown も richText の形に潰れて validate を通る。
    ///
    ///   `> > 中` → 1 段の引用 / `~^a^~` → 上付きだけ / 表のセルは段落 1 つ
    @Test
    def testNestedMarkdownFlattens(): Unit \ Assert =
        let cases = List#{
            "> > 中",
            "~^a^~",
            "^~a~^",
            "| a |\n| --- |\n| ~^b^~ |"
        };
        Assert.assertEq(
            expected = cases |> List.map(_ -> Nil),
            cases |> List.map(markdown -> RichText.validate("fields.body", Markdown.fromMarkdown(markdown))))

    /// `> > 中` は 1 段の引用になり、書き戻しても `>>` にならない。
    @Test
    def testQuoteInQuoteFlattens(): Unit \ Assert =
        Assert.assertEq(
            expected = (doc(List#{ blockquote(List#{ simpleParagraph("中") }) }), "> 中"),
            (Markdown.fromMarkdown("> > 中"), Markdown.toMarkdown(Markdown.fromMarkdown("> > 中"))))

    /// 上付きの中の下付きは、後に書いた方だけ残る。
    @Test
    def testSubInSupKeepsOne(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ doc(List#{ paragraph(List#{ marked("sub", "a") }) }), doc(List#{ paragraph(List#{ marked("sup", "a") }) }) },
            List#{ Markdown.fromMarkdown("^~a~^"), Markdown.fromMarkdown("~^a^~") })

    /// CommonMark のフェンス。~~~ でも 4 個以上でも開き、同じ記号で開いた数以上でしか閉じない。
    /// 書き戻しは常に ` で、中身の ` の並びより 1 つ多い数（最小は 3）。
    @Test
    def testFenceVariants(): Unit \ Assert =
        let cases = List#{
            // ~~~ で開き ~~~ で閉じる。書き戻しは ```
            ("~~~\nx\n~~~",              doc(List#{ codeBlock(None, "x") }),        "```\nx\n```"),
            // ~~~ の中の ``` は中身
            ("~~~ts\n```\n~~~",          doc(List#{ codeBlock(Some("ts"), "```") }), "````ts\n```\n````"),
            // ``` 4 個の中の ``` 3 個は中身。書き戻しも 4 個
            ("````\n```\n````",          doc(List#{ codeBlock(None, "```") }),      "````\n```\n````"),
            // 中身の ```` には ````` で囲む
            ("`````\n````\n`````",       doc(List#{ codeBlock(None, "````") }),     "`````\n````\n`````"),
            // ``` で開いた物は ~~~ では閉じない
            ("```\n~~~\n```",            doc(List#{ codeBlock(None, "~~~") }),      "```\n~~~\n```"),
            // ~~~ で開いた物は ``` では閉じない
            ("~~~\n```\nx\n~~~",         doc(List#{ codeBlock(None, "```\nx") }),   "````\n```\nx\n````"),
            // 4 個で開いた物は 3 個では閉じない
            ("````\n```\nx\n````",       doc(List#{ codeBlock(None, "```\nx") }),   "````\n```\nx\n````"),
            // 閉じないまま終われば末尾まで
            ("~~~\nx\ny",                doc(List#{ codeBlock(None, "x\ny") }),     "```\nx\ny\n```")
        };
        Assert.assertEq(
            expected = cases,
            cases |> List.map(match (markdown, tree, _) -> (markdown, Markdown.fromMarkdown(markdown), Markdown.toMarkdown(tree))))

    /// フェンスの折り返しの印は `{…}` の中の `wrap`。強調する行と並べても書ける。
    @Test
    def testFenceWrapRoundTrip(): Unit \ Assert =
        let cases = List#{
            ("```ts {wrap}\nx\n```",        codeBlockWrap(Some("ts"), None, true)),
            ("``` {wrap}\nx\n```",          codeBlockWrap(None, None, true)),
            ("```ts {1,3-5 wrap}\nx\n```",  codeBlockWrap(Some("ts"), Some("1,3-5"), true)),
            ("```ts {1,3-5}\nx\n```",       codeBlockWrap(Some("ts"), Some("1,3-5"), false)),
            ("```ts\nx\n```",               codeBlockWrap(Some("ts"), None, false))
        };
        Assert.assertEq(
            expected = cases |> List.map(match (markdown, tree) -> (markdown, tree, markdown)),
            cases |> List.map(match (markdown, _) -> (markdown, Markdown.fromMarkdown(markdown), Markdown.toMarkdown(Markdown.fromMarkdown(markdown)))))

    /// wrap は `{…}` の中の語だけ。中身の `wrap` も言語名の `wrap` も折り返しにならない。
    /// `{…}` の中の知らない語は落ちる（強調する行としても読めないため）。
    @Test
    def testFenceWrapIsOnlyInBraces(): Unit \ Assert =
        Assert.assertEq(
            expected = (
                doc(List#{ codeBlock(None, "wrap") }),
                doc(List#{ codeBlock(Some("wrap"), "x") }),
                doc(List#{ codeBlock(None, "x") })),
            (Markdown.fromMarkdown("```\nwrap\n```"),
             Markdown.fromMarkdown("```wrap\nx\n```"),
             Markdown.fromMarkdown("``` {nowrap}\nx\n```")))

    def codeBlockWrap(language: Option[String], highlightLines: Option[String], wrap: Bool): Json =
        CmsTestKit.richNode("codeBlock",
            (language |> Option.map(found -> ("language", Json.JString(found))) |> Option.toList)
                ::: (highlightLines |> Option.map(found -> ("highlightLines", Json.JString(found))) |> Option.toList)
                ::: (if (wrap) ("wrap", Json.JBool(true)) :: Nil else Nil),
            List#{ plain("x") }) |> found -> doc(List#{ found })

    /// 往復した記事は validate で Nil。平文は Markdown から記号を落とした物と同じ。
    @Test
    def testConsistentWithRichText(): Unit \ Assert =
        let roundTripped = Markdown.fromMarkdown(Markdown.toMarkdown(article()));
        Assert.assertEq(
            expected = (Nil,
                "タイトル\nこれは 太字 と 斜体 と 打ち消し と code と 下線 と 外部 と 記事 です。\n見出し 2\n箇条書き 1\n箇条書き 2\n入れ子\n番号 1\n番号 2\n引用\nconst x = 1;\n見出し\n値\n太字\na|b\nヒント\n図 2\nhttps://example.com/card\nconst y = 2;\n補足\n畳んだ中身\n和は a^2 で $10\nE = mc^2\ngraph TD;\nA-->B\n済み\n未着手\n行 1\n行 2"),
            (RichText.validate("fields.body", roundTripped),
             RichText.toText(roundTripped) |> String.replaceMatches(regex = "\n+", to = "\n")))

}
