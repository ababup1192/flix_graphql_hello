///
/// 画像の出典（image.attrs.source / sourceUrl）と引用の出典（blockquote の最後の quoteCite。旧 attrs.cite / citeUrl は読む側だけ）、
/// 画像のリンク・縮小・配置（image.attrs.href / size / align）が、
/// 検査・HTML・平文・Markdown の書き出しと読み・往復（doc → Markdown → doc）で通る事を確かめる。
///
/// 役割の境界: `TestRichText` は richText 単体（validate / toHtml / toText）を見る。こちらは Markdown との
/// 往復と、旧形式（旧 gallery・旧 attrs.caption・旧 attrs.cite）を読む側だけ受ける後方互換を見る。
///
/// 設計は docs/design/richtext-note-style.md の 3 章と 4 章。
///
mod TestRichTextRoundTrip {

    use Util.Json.Json

    // ---- 組み立て ----

    def doc(blocks: List[Json]): Json = CmsTestKit.richNode("doc", Nil, blocks)

    def paragraph(inlines: List[Json]): Json = CmsTestKit.richNode("paragraph", Nil, inlines)

    def plain(text: String): Json = CmsTestKit.richText(Nil, text)

    def simpleParagraph(text: String): Json = paragraph(List#{ plain(text) })

    def linked(href: String, text: String): Json =
        CmsTestKit.richText(List#{ CmsTestKit.richMark("link", List#{ ("href", Json.JString(href)) }) }, text)

    def blockquote(blocks: List[Json]): Json = CmsTestKit.richNode("blockquote", Nil, blocks)

    def blockquoteWith(attrs: List[(String, Json)], blocks: List[Json]): Json = CmsTestKit.richNode("blockquote", attrs, blocks)

    def quoteCite(inlines: List[Json]): Json = CmsTestKit.richNode("quoteCite", Nil, inlines)

    /// 出典を content の最後に持つ引用。
    def quoted(blocks: List[Json], cite: List[Json]): Json =
        CmsTestKit.richNode("blockquote", Nil, blocks ::: (quoteCite(cite) :: Nil))

    def image(attrs: List[(String, Json)]): Json =
        CmsTestKit.richLeaf("image", ("assetId", Json.JString("asset001")) :: attrs)

    /// キャプションを content に持つ image。
    def captioned(attrs: List[(String, Json)], caption: List[Json]): Json =
        CmsTestKit.richNode("image", ("assetId", Json.JString("asset001")) :: attrs, caption)

    def marked(kind: String, text: String): Json = CmsTestKit.richText(List#{ CmsTestKit.richMark(kind, Nil) }, text)

    /// 古い gallery（読む側だけの互換）。中は古い形の image。
    def gallery(images: List[Json]): Json = CmsTestKit.richNode("gallery", List#{ ("columns", CmsTestKit.intJson(2)) }, images)

    /// 画像 1 枚（image の中の imageItem）。キャプションが空なら content を付けない。
    def item(attrs: List[(String, Json)], caption: List[Json]): Json =
        if (List.isEmpty(caption)) CmsTestKit.richLeaf("imageItem", ("assetId", Json.JString("asset001")) :: attrs)
        else CmsTestKit.richNode("imageItem", ("assetId", Json.JString("asset001")) :: attrs, caption)

    /// 画像の塊。imageItem の並び。
    def pictures(items: List[Json]): Json = CmsTestKit.richNode("image", Nil, items)

    /// 1 枚だけの image。
    def one(attrs: List[(String, Json)], caption: List[Json]): Json = pictures(item(attrs, caption) :: Nil)

    def s(name: String, value: String): (String, Json) = (name, Json.JString(value))

    def images(): Map[AssetId, RichText.ImageRef] =
        Map#{ AssetId.AssetId("asset001") => { url = "u", width = None, height = None } }

    def html(document: Json): String = RichText.toHtml(images(), Map.empty(), Map.empty(), document)

    def roundTrip(document: Json): Json = Markdown.fromMarkdown(Markdown.toMarkdown(document))

    def citeLink(): String = "<cite><a href=\"https://src.example/\" target=\"_blank\" rel=\"noopener noreferrer\">出典社</a></cite>"

    /// href 付きの img。
    def linkedImg(extra: String): String = "<a href=\"https://go.example/\" target=\"_blank\" rel=\"noopener noreferrer\"><img src=\"u\" alt=\"\"${extra}></a>"

    // ================================================================
    // 1. 検査: source / sourceUrl / cite / citeUrl の受かる形と落ちる形
    // ================================================================

    ///
    /// 1 行 = (ノード, 通るか)。sourceUrl / citeUrl は http(s) だけ。空文字は「無い」と同じで通る。
    ///
    def validatePairs(): List[(Json, Bool)] = List#{
        (image(List#{ s("caption", "写真"), s("source", "出典社"), s("sourceUrl", "https://src.example/") }), true),
        (image(List#{ s("source", "出典社") }), true),
        (image(List#{ s("sourceUrl", "http://src.example/") }), true),
        (image(List#{ s("source", ""), s("sourceUrl", "") }), true),
        (image(List#{ s("sourceUrl", "mailto:a@example.com") }), false),
        (image(List#{ ("source", CmsTestKit.intJson(1)) }), false),
        (blockquoteWith(List#{ s("cite", "著者"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }), true),
        (blockquoteWith(List#{ s("cite", ""), s("citeUrl", "") }, List#{ simpleParagraph("引用") }), true),
        (blockquoteWith(List#{ s("citeUrl", "mailto:a@example.com") }, List#{ simpleParagraph("引用") }), false),
        (blockquoteWith(List#{ ("cite", CmsTestKit.intJson(1)) }, List#{ simpleParagraph("引用") }), false),
        (gallery(List#{ image(List#{ s("sourceUrl", "javascript:alert(1)") }) }), false)
    }

    @Test
    def testValidateSourceAttrs(): Unit \ Assert =
        Assert.assertEq(
            expected = validatePairs() |> List.map(snd),
            validatePairs() |> List.map(fst) |> List.map(node -> List.isEmpty(RichText.validate("fields.body", doc(List#{ node })))))

    ///
    /// 1 行 = (ノード, 通るか)。href は http(s) だけ、size は small だけ、align は left だけ。空文字は「無い」と同じで通る。
    ///
    def validatePlacementPairs(): List[(Json, Bool)] = List#{
        (image(List#{ s("href", "https://go.example/") }), true),
        (image(List#{ s("href", "http://go.example/") }), true),
        (image(List#{ s("href", "") }), true),
        (image(List#{ s("href", "mailto:a@example.com") }), false),
        (image(List#{ s("href", "javascript:alert(1)") }), false),
        (image(List#{ s("size", "small") }), true),
        (image(List#{ s("size", "") }), true),
        (image(List#{ s("size", "large") }), false),
        (image(List#{ ("size", CmsTestKit.intJson(1)) }), false),
        (image(List#{ s("align", "left") }), true),
        (image(List#{ s("align", "right") }), true),
        (image(List#{ s("align", "center") }), false),
        (image(List#{ s("href", "https://go.example/"), s("size", "small"), s("align", "left"), s("caption", "写真"), s("source", "出典社") }), true),
        (gallery(List#{ image(List#{ s("href", "mailto:a@example.com") }) }), false),
        (gallery(List#{ image(List#{ s("size", "small"), s("align", "left") }) }), true)
    }

    @Test
    def testValidatePlacementAttrs(): Unit \ Assert =
        Assert.assertEq(
            expected = validatePlacementPairs() |> List.map(snd),
            validatePlacementPairs() |> List.map(fst) |> List.map(node -> List.isEmpty(RichText.validate("fields.body", doc(List#{ node })))))

    // ================================================================
    // 2. doc → HTML: figure / figcaption / cite の形
    // ================================================================

    ///
    /// image。caption も source も無ければ img だけ。source だけなら figcaption の中身は cite だけ。sourceUrl が無ければ a を巻かない。
    ///
    def imageHtmlPairs(): List[(Json, String)] = List#{
        (doc(List#{ image(Nil) }), "<img src=\"u\" alt=\"\">"),
        (doc(List#{ image(List#{ s("caption", "写真") }) }), "<figure><img src=\"u\" alt=\"\"><figcaption>写真</figcaption></figure>"),
        (doc(List#{ image(List#{ s("source", "出典社") }) }), "<figure><img src=\"u\" alt=\"\"><figcaption><cite>出典社</cite></figcaption></figure>"),
        (doc(List#{ image(List#{ s("source", "出典社"), s("sourceUrl", "https://src.example/") }) }), "<figure><img src=\"u\" alt=\"\"><figcaption>${citeLink()}</figcaption></figure>"),
        (doc(List#{ image(List#{ s("caption", "写真"), s("source", "出典社") }) }), "<figure><img src=\"u\" alt=\"\"><figcaption>写真 <cite>出典社</cite></figcaption></figure>"),
        (doc(List#{ image(List#{ s("caption", "写真"), s("source", "出典社"), s("sourceUrl", "https://src.example/") }) }), "<figure><img src=\"u\" alt=\"\"><figcaption>写真 ${citeLink()}</figcaption></figure>"),
        // sourceUrl だけなら URL を文字として出す
        (doc(List#{ image(List#{ s("sourceUrl", "https://src.example/") }) }), "<figure><img src=\"u\" alt=\"\"><figcaption><cite><a href=\"https://src.example/\" target=\"_blank\" rel=\"noopener noreferrer\">https://src.example/</a></cite></figcaption></figure>"),
        // 空文字は無いのと同じ
        (doc(List#{ image(List#{ s("caption", ""), s("source", ""), s("sourceUrl", "") }) }), "<img src=\"u\" alt=\"\">"),
        // 文字はエスケープする
        (doc(List#{ image(List#{ s("source", "<a>") }) }), "<figure><img src=\"u\" alt=\"\"><figcaption><cite>&lt;a&gt;</cite></figcaption></figure>"),
        // 古い gallery の中の image も同じ figcaption。キャプションの無い画像は素の img
        (doc(List#{ gallery(List#{ image(List#{ s("caption", "写真"), s("source", "出典社"), s("sourceUrl", "https://src.example/") }), image(Nil) }) }),
         "<figure data-gallery=\"2\"><figure><img src=\"u\" alt=\"\"><figcaption>写真 ${citeLink()}</figcaption></figure><img src=\"u\" alt=\"\"></figure>")
    }

    @Test
    def testToHtmlImageSource(): Unit \ Assert =
        Assert.assertEq(
            expected = imageHtmlPairs() |> List.map(snd),
            imageHtmlPairs() |> List.map(fst) |> List.map(html))

    ///
    /// href は img を a で巻く（外部リンクと同じ target / rel）。size / align は figure の data-size / data-align、figure が無ければ img に付く。
    /// caption も出典も無く href だけなら figure は作らない。
    ///
    def placementHtmlPairs(): List[(Json, String)] = List#{
        (doc(List#{ image(List#{ s("href", "https://go.example/") }) }), linkedImg("")),
        (doc(List#{ image(List#{ s("href", "https://go.example/"), s("caption", "写真"), s("source", "出典社") }) }),
         "<figure>${linkedImg("")}<figcaption>写真 <cite>出典社</cite></figcaption></figure>"),
        (doc(List#{ image(List#{ s("size", "small"), s("align", "left") }) }), "<img src=\"u\" alt=\"\" data-size=\"small\" data-align=\"left\">"),
        (doc(List#{ image(List#{ s("size", "small"), s("align", "right") }) }), "<img src=\"u\" alt=\"\" data-size=\"small\" data-align=\"right\">"),
        (doc(List#{ image(List#{ s("size", "small"), s("caption", "写真") }) }), "<figure data-size=\"small\"><img src=\"u\" alt=\"\"><figcaption>写真</figcaption></figure>"),
        (doc(List#{ image(List#{ s("href", "https://go.example/"), s("size", "small") }) }), linkedImg(" data-size=\"small\"")),
        (doc(List#{ image(List#{ s("href", "https://go.example/"), s("size", "small"), s("align", "left"), s("caption", "写真"), s("source", "出典社") }) }),
         "<figure data-size=\"small\" data-align=\"left\">${linkedImg("")}<figcaption>写真 <cite>出典社</cite></figcaption></figure>"),
        // 空文字は無いのと同じ。href の `"` はエスケープする
        (doc(List#{ image(List#{ s("href", ""), s("size", ""), s("align", "") }) }), "<img src=\"u\" alt=\"\">"),
        (doc(List#{ image(List#{ s("href", "https://go.example/?q=\"a\"") }) }),
         "<a href=\"https://go.example/?q=&quot;a&quot;\" target=\"_blank\" rel=\"noopener noreferrer\"><img src=\"u\" alt=\"\"></a>"),
        // 並べた中でも、キャプションが無ければ figure を作らず size / align は img に付く
        (doc(List#{ gallery(List#{ image(List#{ s("href", "https://go.example/"), s("size", "small") }), image(Nil) }) }),
         "<figure data-gallery=\"2\">${linkedImg(" data-size=\"small\"")}<img src=\"u\" alt=\"\"></figure>")
    }

    @Test
    def testToHtmlImagePlacement(): Unit \ Assert =
        Assert.assertEq(
            expected = placementHtmlPairs() |> List.map(snd),
            placementHtmlPairs() |> List.map(fst) |> List.map(html))

    ///
    /// blockquote。cite が無ければ素の blockquote。あれば figure[data-quote] の中に blockquote と figcaption > cite。
    ///
    def quoteHtmlPairs(): List[(Json, String)] = List#{
        (doc(List#{ blockquote(List#{ simpleParagraph("引用") }) }), "<blockquote><p>引用</p></blockquote>"),
        (doc(List#{ blockquoteWith(List#{ s("cite", ""), s("citeUrl", "") }, List#{ simpleParagraph("引用") }) }), "<blockquote><p>引用</p></blockquote>"),
        (doc(List#{ blockquoteWith(List#{ s("cite", "出典社") }, List#{ simpleParagraph("引用") }) }),
         "<figure data-quote><blockquote><p>引用</p></blockquote><figcaption><cite>出典社</cite></figcaption></figure>"),
        (doc(List#{ blockquoteWith(List#{ s("cite", "出典社"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }),
         "<figure data-quote><blockquote><p>引用</p></blockquote><figcaption>${citeLink()}</figcaption></figure>"),
        (doc(List#{ blockquoteWith(List#{ s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }),
         "<figure data-quote><blockquote><p>引用</p></blockquote><figcaption><cite><a href=\"https://src.example/\" target=\"_blank\" rel=\"noopener noreferrer\">https://src.example/</a></cite></figcaption></figure>")
    }

    @Test
    def testToHtmlQuoteCite(): Unit \ Assert =
        Assert.assertEq(
            expected = quoteHtmlPairs() |> List.map(snd),
            quoteHtmlPairs() |> List.map(fst) |> List.map(html))

    // ================================================================
    // 3. 平文: gallery の caption の後ろに空白 1 つで source、引用の後ろに 1 行で `— 出典`。URL は出ない
    // ================================================================

    def textPairs(): List[(Json, String)] = List#{
        (doc(List#{ gallery(List#{ image(List#{ s("caption", "写真"), s("source", "出典社"), s("sourceUrl", "https://src.example/") }), image(List#{ s("source", "撮影者") }), image(Nil) }) }), "写真 出典社\n撮影者"),
        (doc(List#{ blockquoteWith(List#{ s("cite", "著者"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }), "引用\n— 著者"),
        (doc(List#{ blockquoteWith(List#{ s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }), "引用"),
        (doc(List#{ blockquoteWith(List#{ s("cite", "著者") }, List#{ simpleParagraph("引用") }), simpleParagraph("次") }), "引用\n— 著者\n\n次")
    }

    @Test
    def testToTextSource(): Unit \ Assert =
        Assert.assertEq(
            expected = textPairs() |> List.map(snd),
            textPairs() |> List.map(fst) |> List.map(RichText.toText))

    /// href / size / align は平文に出ない。
    @Test
    def testToTextIgnoresPlacement(): Unit \ Assert =
        Assert.assertEq(
            expected = "写真",
            RichText.toText(doc(List#{ gallery(List#{ image(List#{ s("caption", "写真"), s("href", "https://go.example/"), s("size", "small"), s("align", "left") }), image(Nil) }) })))

    // ================================================================
    // 4. doc → Markdown
    // ================================================================

    def writePairs(): List[(Json, String)] = List#{
        // image: `{...}` は width height source sourceUrl の順。source は `"…"`、sourceUrl は裸。caption は次の行
        (doc(List#{ captioned(List#{ s("source", "出典社"), s("sourceUrl", "https://src.example/"), ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }, List#{ plain("写真") }) }),
         "![](asset:asset001){width=800 height=450 source=\"出典社\" sourceUrl=https://src.example/}\n*写真*"),
        (doc(List#{ image(List#{ s("source", "出典社") }) }), "![](asset:asset001){source=\"出典社\"}"),
        (doc(List#{ image(List#{ s("sourceUrl", "https://src.example/") }) }), "![](asset:asset001){sourceUrl=https://src.example/}"),
        // source の中の `"` は `\"`
        (doc(List#{ image(List#{ s("source", "a \"b\"") }) }), "![](asset:asset001){source=\"a \\\"b\\\"\"}"),
        // gallery の中でも同じ
        (doc(List#{ gallery(List#{ image(List#{ s("source", "出典社") }), image(Nil) }) }), "![](asset:asset001){source=\"出典社\"} ![](asset:asset001)"),
        // blockquote: 引用の最後に空行を挟んで `> — [出典](URL)`
        (doc(List#{ blockquoteWith(List#{ s("cite", "著者"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }), "> 引用\n>\n> — [著者](https://src.example/)"),
        (doc(List#{ blockquoteWith(List#{ s("cite", "著者") }, List#{ simpleParagraph("引用") }) }), "> 引用\n>\n> — 著者"),
        (doc(List#{ blockquoteWith(List#{ s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }), "> 引用\n>\n> — [https://src.example/](https://src.example/)"),
        // 本文として `— ` で始まる段落は `\— ` で逃がす（cite に化けない）
        (doc(List#{ blockquote(List#{ simpleParagraph("引用"), paragraph(List#{ plain("— "), linked("https://src.example/", "出典") }) }) }), "> 引用\n>\n> \\— [出典](https://src.example/)"),
        (doc(List#{ simpleParagraph("— 本文") }), "\\— 本文")
    }

    @Test
    def testToMarkdownSource(): Unit \ Assert =
        Assert.assertEq(
            expected = writePairs() |> List.map(snd),
            writePairs() |> List.map(fst) |> List.map(Markdown.toMarkdown))

    ///
    /// href は `[![…](…){…}](URL)`（`{...}` はリンクの括弧の内側）。`{...}` は width height size align source sourceUrl の順。
    ///
    def writePlacementPairs(): List[(Json, String)] = List#{
        (doc(List#{ image(List#{ s("href", "https://go.example/") }) }), "[![](asset:asset001)](https://go.example/)"),
        (doc(List#{ captioned(List#{ s("href", "https://go.example/"), s("source", "出典社") }, List#{ plain("写真") }) }),
         "[![](asset:asset001){source=\"出典社\"}](https://go.example/)\n*写真*"),
        (doc(List#{ image(List#{ s("size", "small"), s("align", "left") }) }), "![](asset:asset001){size=small align=left}"),
        (doc(List#{ image(List#{ s("align", "right") }) }), "![](asset:asset001){align=right}"),
        (doc(List#{ captioned(List#{ s("alt", "説明"), s("href", "https://go.example/"), s("size", "small"), s("align", "left"), s("source", "出典社"), s("sourceUrl", "https://src.example/"), ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }, List#{ plain("写真") }) }),
         "[![説明](asset:asset001){width=800 height=450 size=small align=left source=\"出典社\" sourceUrl=https://src.example/}](https://go.example/)\n*写真*"),
        // 空文字は書かない
        (doc(List#{ image(List#{ s("href", ""), s("size", ""), s("align", "") }) }), "![](asset:asset001)"),
        // gallery の中でも同じ
        (doc(List#{ gallery(List#{ image(List#{ s("href", "https://go.example/"), s("size", "small") }), image(Nil) }) }),
         "[![](asset:asset001){size=small}](https://go.example/) ![](asset:asset001)")
    }

    @Test
    def testToMarkdownPlacement(): Unit \ Assert =
        Assert.assertEq(
            expected = writePlacementPairs() |> List.map(snd),
            writePlacementPairs() |> List.map(fst) |> List.map(Markdown.toMarkdown))

    // ================================================================
    // 5. Markdown → doc
    // ================================================================

    def readPairs(): List[(String, Json)] = List#{
        ("![](asset:asset001){width=800 height=450 source=\"出典社\" sourceUrl=https://src.example/}\n*写真*",
         doc(List#{ one(List#{ ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)), s("source", "出典社"), s("sourceUrl", "https://src.example/") }, List#{ plain("写真") }) })),
        // 知らない key は捨てる。並びの順も問わない
        ("![](asset:asset001){foo=bar height=450 width=800}",
         doc(List#{ one(List#{ ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }, Nil) })),
        // width と height は片方だけなら無視
        ("![](asset:asset001){width=800 source=\"出典社\"}",
         doc(List#{ one(List#{ s("source", "出典社") }, Nil) })),
        // `\"` のエスケープ
        ("![](asset:asset001){source=\"a \\\"b\\\"\"}",
         doc(List#{ one(List#{ s("source", "a \"b\"") }, Nil) })),
        // 空の `{}` は無いのと同じ
        ("![](asset:asset001){}",
         doc(List#{ one(Nil, Nil) })),
        // `> — [出典](URL)` は最後の quoteCite（リンクは出典の文字に掛かる）
        ("> 引用\n>\n> — [著者](https://src.example/)",
         doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ linked("https://src.example/", "著者") }) })),
        // URL 無し
        ("> 引用\n>\n> — 著者",
         doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ plain("著者") }) })),
        // リンクの後ろの文字も出典の内容
        ("> 引用\n>\n> — [著者](https://src.example/) より",
         doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ linked("https://src.example/", "著者"), plain(" より") }) })),
        // 空行を挟まない `— 出典` は 1 つの段落の続き（cite にならない）
        ("> 引用\n> — 著者",
         doc(List#{ blockquote(List#{ simpleParagraph("引用\n— 著者") }) })),
        // `\— ` は本文（cite にならない）
        ("> 引用\n>\n> \\— [出典](https://src.example/)",
         doc(List#{ blockquote(List#{ simpleParagraph("引用"), paragraph(List#{ plain("— "), linked("https://src.example/", "出典") }) }) })),
        // callout の最後の `— ` は畳まない
        ("> [!NOTE]\n> 注意\n>\n> — 著者",
         doc(List#{ CmsTestKit.richNode("callout", List#{ s("kind", "note") }, List#{ simpleParagraph("注意"), simpleParagraph("— 著者") }) }))
    }

    @Test
    def testFromMarkdownSource(): Unit \ Assert =
        Assert.assertEq(
            expected = readPairs() |> List.map(snd),
            readPairs() |> List.map(fst) |> List.map(Markdown.fromMarkdown))

    ///
    /// リンク付きの image と size / align の読み。境界: `{...}` をリンクの外側に置いた形、http(s) でないリンク先、決まった値でない size / align。
    ///
    def readPlacementPairs(): List[(String, Json)] = List#{
        ("[![](asset:asset001)](https://go.example/)",
         doc(List#{ one(List#{ s("href", "https://go.example/") }, Nil) })),
        ("[![](asset:asset001){source=\"出典社\"}](https://go.example/)\n*写真*",
         doc(List#{ one(List#{ s("href", "https://go.example/"), s("source", "出典社") }, List#{ plain("写真") }) })),
        ("![](asset:asset001){size=small align=left}",
         doc(List#{ one(List#{ s("size", "small"), s("align", "left") }, Nil) })),
        ("![](asset:asset001){align=right}",
         doc(List#{ one(List#{ s("align", "right") }, Nil) })),
        ("[![説明](asset:asset001){width=800 height=450 size=small align=left source=\"出典社\" sourceUrl=https://src.example/}](https://go.example/)\n*写真*",
         doc(List#{ one(List#{ s("alt", "説明"), s("href", "https://go.example/"), s("size", "small"), s("align", "left"), s("source", "出典社"), s("sourceUrl", "https://src.example/"), ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }, List#{ plain("写真") }) })),
        // 複数枚でも同じ
        ("[![](asset:asset001){size=small}](https://go.example/) ![](asset:asset001)",
         doc(List#{ pictures(List#{ item(List#{ s("href", "https://go.example/"), s("size", "small") }, Nil), item(Nil, Nil) }) })),
        // 決まった値でない size / align は捨てる（validate に通る doc を返す）
        ("![](asset:asset001){size=large align=center}",
         doc(List#{ one(Nil, Nil) })),
        // 境界: `{...}` をリンクの外側に置いた形は image として読まず、段落の文字（リンク付きの `![](asset:…)` と `{…}`）になる
        ("[![](asset:asset001)](https://go.example/){size=small}",
         doc(List#{ paragraph(List#{ linked("https://go.example/", "![](asset:asset001)"), plain("{size=small}") }) })),
        // 境界: http(s) でないリンク先は image にならない
        ("[![](asset:asset001)](mailto:a@example.com)",
         doc(List#{ paragraph(List#{ linked("mailto:a@example.com", "![](asset:asset001)") }) }))
    }

    @Test
    def testFromMarkdownPlacement(): Unit \ Assert =
        Assert.assertEq(
            expected = readPlacementPairs() |> List.map(snd),
            readPlacementPairs() |> List.map(fst) |> List.map(Markdown.fromMarkdown))

    // ================================================================
    // 6. 往復（doc → Markdown → doc）で同じ doc に戻る
    // ================================================================

    def roundTripDocs(): List[Json] = List#{
        doc(List#{ one(List#{ s("alt", "説明"), s("source", "出典社"), s("sourceUrl", "https://src.example/"), ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }, List#{ plain("写真") }) }),
        doc(List#{ one(List#{ s("source", "a \"b\" [c]") }, Nil) }),
        doc(List#{ pictures(List#{ item(List#{ s("source", "出典社") }, Nil), item(List#{ s("sourceUrl", "https://src.example/") }, Nil) }) }),
        doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ linked("https://src.example/", "著者") }) }),
        doc(List#{ quoted(List#{ simpleParagraph("引用"), simpleParagraph("二段落目") }, List#{ plain("著者") }) }),
        doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ linked("https://src.example/", "https://src.example/") }) }),
        doc(List#{ blockquote(List#{ simpleParagraph("引用"), paragraph(List#{ plain("— "), linked("https://src.example/", "出典") }) }) }),
        doc(List#{ blockquote(List#{ simpleParagraph("— 本文だけ") }) }),
        doc(List#{ simpleParagraph("— 本文") })
    }

    @Test
    def testRoundTripKeepsSource(): Unit \ Assert =
        Assert.assertEq(
            expected = roundTripDocs(),
            roundTripDocs() |> List.map(roundTrip))

    /// href だけ / href + caption + source / size + align（left / right） / 3 つ全部 / 複数枚の中。
    def roundTripPlacementDocs(): List[Json] = List#{
        doc(List#{ one(List#{ s("href", "https://go.example/") }, Nil) }),
        doc(List#{ one(List#{ s("href", "https://go.example/"), s("source", "出典社") }, List#{ plain("写真") }) }),
        doc(List#{ one(List#{ s("size", "small"), s("align", "left") }, Nil) }),
        doc(List#{ one(List#{ s("size", "small"), s("align", "right") }, Nil) }),
        doc(List#{ one(List#{ s("alt", "説明"), s("href", "https://go.example/"), s("size", "small"), s("align", "left"), s("source", "出典社"), s("sourceUrl", "https://src.example/"), ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }, List#{ plain("写真") }) }),
        doc(List#{ pictures(List#{ item(List#{ s("href", "https://go.example/"), s("size", "small") }, Nil), item(List#{ s("align", "left") }, Nil) }) }),
        doc(List#{ one(List#{ s("href", "https://go.example/") }, Nil), simpleParagraph("次") })
    }

    @Test
    def testRoundTripKeepsPlacement(): Unit \ Assert =
        Assert.assertEq(
            expected = roundTripPlacementDocs(),
            roundTripPlacementDocs() |> List.map(roundTrip))

    // ================================================================
    // 7. キャプションは content（inline）。attrs.caption は読む側だけの互換
    // ================================================================

    /// link 付きのキャプション「撮影: [山田](https://src.example/)」。
    def linkCaption(): List[Json] = List#{ plain("撮影: "), linked("https://src.example/", "山田") }

    def captionLinkHtml(): String = "撮影: <a href=\"https://src.example/\" target=\"_blank\" rel=\"noopener noreferrer\">山田</a>"

    ///
    /// 検査。1 行 = (ノード, 通るか)。content は text だけで、マークは bold / italic / strike / code / link。hardBreak と他のマークは落ちる。
    /// attrs.caption だけの旧 doc と、両方ある doc も通る。
    ///
    def validateCaptionPairs(): List[(Json, Bool)] = List#{
        (captioned(Nil, linkCaption()), true),
        (captioned(Nil, List#{ marked("bold", "太"), marked("italic", "斜"), marked("strike", "消"), marked("code", "c") }), true),
        (captioned(Nil, List#{ marked("underline", "下線") }), false),
        (captioned(Nil, List#{ marked("highlight", "蛍光") }), false),
        (captioned(Nil, List#{ marked("math", "x") }), false),
        (captioned(Nil, List#{ plain("a"), CmsTestKit.richLeaf("hardBreak", Nil), plain("b") }), false),
        (captioned(Nil, List#{ simpleParagraph("段落") }), false),
        (captioned(Nil, Nil), true),
        (image(List#{ s("caption", "旧") }), true),
        (captioned(List#{ s("caption", "旧") }, List#{ plain("新") }), true),
        (gallery(List#{ captioned(Nil, linkCaption()), captioned(Nil, List#{ marked("underline", "x") }) }), false),
        (gallery(List#{ captioned(Nil, linkCaption()), image(Nil) }), true)
    }

    @Test
    def testValidateCaptionContent(): Unit \ Assert =
        Assert.assertEq(
            expected = validateCaptionPairs() |> List.map(snd),
            validateCaptionPairs() |> List.map(fst) |> List.map(node -> List.isEmpty(RichText.validate("fields.body", doc(List#{ node })))))

    ///
    /// HTML。figcaption の中はマークの HTML（本文と同じ a / strong）+ `<cite>`。attrs.caption だけなら文字。両方あれば content。空の content は figure 無し。
    ///
    def captionHtmlPairs(): List[(Json, String)] = List#{
        (doc(List#{ captioned(Nil, linkCaption()) }), "<figure><img src=\"u\" alt=\"\"><figcaption>${captionLinkHtml()}</figcaption></figure>"),
        (doc(List#{ captioned(List#{ s("source", "出典社"), s("sourceUrl", "https://src.example/") }, List#{ marked("bold", "写真") }) }),
         "<figure><img src=\"u\" alt=\"\"><figcaption><strong>写真</strong> ${citeLink()}</figcaption></figure>"),
        (doc(List#{ image(List#{ s("caption", "旧 <b>") }) }), "<figure><img src=\"u\" alt=\"\"><figcaption>旧 &lt;b&gt;</figcaption></figure>"),
        (doc(List#{ captioned(List#{ s("caption", "旧") }, List#{ plain("新") }) }), "<figure><img src=\"u\" alt=\"\"><figcaption>新</figcaption></figure>"),
        (doc(List#{ captioned(Nil, Nil) }), "<img src=\"u\" alt=\"\">"),
        (doc(List#{ captioned(Nil, List#{ plain("") }) }), "<img src=\"u\" alt=\"\">"),
        (doc(List#{ gallery(List#{ captioned(Nil, linkCaption()), image(List#{ s("caption", "旧") }) }) }),
         "<figure data-gallery=\"2\"><figure><img src=\"u\" alt=\"\"><figcaption>${captionLinkHtml()}</figcaption></figure><figure><img src=\"u\" alt=\"\"><figcaption>旧</figcaption></figure></figure>")
    }

    @Test
    def testToHtmlCaptionContent(): Unit \ Assert =
        Assert.assertEq(
            expected = captionHtmlPairs() |> List.map(snd),
            captionHtmlPairs() |> List.map(fst) |> List.map(html))

    /// 平文。gallery の中は inline を素の文字に（旧 attrs.caption も同じ）。単独の image は今まで通り出ない。
    def captionTextPairs(): List[(Json, String)] = List#{
        (doc(List#{ gallery(List#{ captioned(List#{ s("source", "出典社") }, linkCaption()), image(List#{ s("caption", "旧") }), captioned(Nil, Nil) }) }), "撮影: 山田 出典社\n旧"),
        (doc(List#{ captioned(Nil, linkCaption()), simpleParagraph("次") }), "次")
    }

    @Test
    def testToTextCaptionContent(): Unit \ Assert =
        Assert.assertEq(
            expected = captionTextPairs() |> List.map(snd),
            captionTextPairs() |> List.map(fst) |> List.map(RichText.toText))

    ///
    /// Markdown の書き出し。画像の次の行に `*…*`。中は inline Markdown、`*` は `\*`。旧 attrs.caption も同じ形で出る（title には出さない）。
    /// gallery は枚数だけ `*…*` を空白区切りで、無い画像は `**`。どの画像にも無ければ行自体が無い。
    ///
    def captionWritePairs(): List[(Json, String)] = List#{
        (doc(List#{ captioned(Nil, linkCaption()) }), "![](asset:asset001)\n*撮影: [山田](https://src.example/)*"),
        (doc(List#{ captioned(Nil, List#{ marked("bold", "太"), plain(" と "), marked("italic", "斜") }) }), "![](asset:asset001)\n***太** と _斜_*"),
        (doc(List#{ captioned(Nil, List#{ plain("a * b*") }) }), "![](asset:asset001)\n*a \\* b\\**"),
        (doc(List#{ image(List#{ s("caption", "旧") }) }), "![](asset:asset001)\n*旧*"),
        (doc(List#{ captioned(List#{ s("caption", "旧") }, List#{ plain("新") }) }), "![](asset:asset001)\n*新*"),
        (doc(List#{ gallery(List#{ image(Nil), captioned(Nil, linkCaption()), image(List#{ s("caption", "旧") }) }) }),
         "![](asset:asset001) ![](asset:asset001) ![](asset:asset001)\n** *撮影: [山田](https://src.example/)* *旧*"),
        (doc(List#{ gallery(List#{ image(Nil), captioned(Nil, Nil) }) }), "![](asset:asset001) ![](asset:asset001)"),
        // 次のブロックとは空行で区切る
        (doc(List#{ captioned(Nil, List#{ plain("写真") }), simpleParagraph("次") }), "![](asset:asset001)\n*写真*\n\n次")
    }

    @Test
    def testToMarkdownCaptionContent(): Unit \ Assert =
        Assert.assertEq(
            expected = captionWritePairs() |> List.map(snd),
            captionWritePairs() |> List.map(fst) |> List.map(Markdown.toMarkdown))

    ///
    /// Markdown の読み。直後の行が `*` で始まり `*` で終わる時だけキャプション。境界: 直前に空行があれば段落、`*` で閉じなければ段落、
    /// 旧 title は content に写す、title と行の両方あれば行が勝つ、複数枚で `*…*` が 1 つだけなら全体のキャプション。
    ///
    def captionReadPairs(): List[(String, Json)] = List#{
        ("![](asset:asset001)\n*撮影: [山田](https://src.example/)*", doc(List#{ one(Nil, linkCaption()) })),
        ("![](asset:asset001)\n***太** と _斜_*", doc(List#{ one(Nil, List#{ marked("bold", "太"), plain(" と "), marked("italic", "斜") }) })),
        ("![](asset:asset001)\n*a \\* b\\**", doc(List#{ one(Nil, List#{ plain("a * b*") }) })),
        ("![](asset:asset001)\n\n*写真*", doc(List#{ one(Nil, Nil), paragraph(List#{ marked("italic", "写真") }) })),
        ("![](asset:asset001)\n*写真", doc(List#{ paragraph(List#{ plain("![](asset:asset001)\n*写真") }) })),
        ("![](asset:asset001)\n*写真*\n続き", doc(List#{ paragraph(List#{ plain("![](asset:asset001)\n"), marked("italic", "写真"), plain("\n続き") }) })),
        ("![](asset:asset001 \"旧\")", doc(List#{ one(Nil, List#{ plain("旧") }) })),
        ("![](asset:asset001 \"旧\")\n*新*", doc(List#{ one(Nil, List#{ plain("新") }) })),
        ("![](asset:asset001) ![](asset:asset001) ![](asset:asset001) {columns=2}\n** *撮影: [山田](https://src.example/)* *旧*",
         doc(List#{ pictures(List#{ item(Nil, Nil), item(Nil, linkCaption()), item(Nil, List#{ plain("旧") }) }) })),
        ("![](asset:asset001) ![](asset:asset001)\n*a*", doc(List#{ pictures(List#{ item(Nil, List#{ plain("a") }), item(Nil, Nil) }) })),
        ("![](asset:asset001) ![](asset:asset001)\n*a* b", doc(List#{ paragraph(List#{ plain("![](asset:asset001) ![](asset:asset001)\n"), marked("italic", "a"), plain(" b") }) }))
    }

    @Test
    def testFromMarkdownCaptionContent(): Unit \ Assert =
        Assert.assertEq(
            expected = captionReadPairs() |> List.map(snd),
            captionReadPairs() |> List.map(fst) |> List.map(Markdown.fromMarkdown))

    /// 往復。link / bold / `*` の逃がし / 複数枚のキャプション / 出典と一緒。
    def roundTripCaptionDocs(): List[Json] = List#{
        doc(List#{ one(Nil, linkCaption()) }),
        doc(List#{ one(List#{ s("source", "出典社"), s("sourceUrl", "https://src.example/") }, List#{ marked("bold", "太"), plain(" と "), marked("italic", "斜"), plain(" と "), marked("strike", "消"), plain(" と "), marked("code", "c") }) }),
        doc(List#{ one(Nil, List#{ plain("a * b* _c_ [d]") }) }),
        doc(List#{ pictures(List#{ item(Nil, Nil), item(Nil, linkCaption()), item(List#{ s("href", "https://go.example/") }, List#{ plain("旧") }) }) }),
        doc(List#{ one(Nil, List#{ plain("写真") }), simpleParagraph("次") })
    }

    @Test
    def testRoundTripKeepsCaptionContent(): Unit \ Assert =
        Assert.assertEq(
            expected = roundTripCaptionDocs(),
            roundTripCaptionDocs() |> List.map(roundTrip))

    // ================================================================
    // 8. 引用の出典も内容（quoteCite）。attrs.cite / citeUrl は読む側だけの互換
    // ================================================================

    /// リンクを掛けた出典「[著者](https://src.example/)」。
    def citeLinkContent(): List[Json] = List#{ linked("https://src.example/", "著者") }

    /// 出典のリンクの HTML（本文のリンクと同じ a）。
    def citeContentLinkHtml(): String = "<cite><a href=\"https://src.example/\" target=\"_blank\" rel=\"noopener noreferrer\">著者</a></cite>"

    ///
    /// 検査。1 行 = (ノード, 通るか)。quoteCite は引用の最後の子だけで、中は text。マークは bold / italic / strike / code / link。
    /// 旧 attrs だけの doc と、両方ある doc も通る。
    ///
    def validateQuoteCitePairs(): List[(Json, Bool)] = List#{
        (quoted(List#{ simpleParagraph("引用") }, citeLinkContent()), true),
        (quoted(List#{ simpleParagraph("引用") }, List#{ marked("bold", "太"), marked("italic", "斜"), marked("strike", "消"), marked("code", "c") }), true),
        (quoted(List#{ simpleParagraph("引用") }, List#{ marked("underline", "下線") }), false),
        (quoted(List#{ simpleParagraph("引用") }, List#{ marked("highlight", "蛍光") }), false),
        (quoted(List#{ simpleParagraph("引用") }, List#{ plain("a"), CmsTestKit.richLeaf("hardBreak", Nil) }), false),
        (quoted(List#{ simpleParagraph("引用") }, List#{ simpleParagraph("段落") }), false),
        // 出典が空でも形としては通る
        (quoted(List#{ simpleParagraph("引用") }, Nil), true),
        // 最後でない quoteCite は通らない
        (CmsTestKit.richNode("blockquote", Nil, List#{ quoteCite(List#{ plain("著者") }), simpleParagraph("引用") }), false),
        // 引用の外の quoteCite も通らない
        (quoteCite(List#{ plain("著者") }), false),
        // 旧 attrs だけ / 旧 attrs と content の両方
        (blockquoteWith(List#{ s("cite", "著者"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }), true),
        (CmsTestKit.richNode("blockquote", List#{ s("cite", "旧") }, List#{ simpleParagraph("引用"), quoteCite(List#{ plain("新") }) }), true)
    }

    @Test
    def testValidateQuoteCiteContent(): Unit \ Assert =
        Assert.assertEq(
            expected = validateQuoteCitePairs() |> List.map(snd),
            validateQuoteCitePairs() |> List.map(fst) |> List.map(node -> List.isEmpty(RichText.validate("fields.body", doc(List#{ node })))))

    ///
    /// HTML。figcaption > cite の中はマークの HTML。旧 attrs だけなら今まで通りの形で出る。両方あれば content。空なら素の blockquote。
    ///
    def quoteCiteHtmlPairs(): List[(Json, String)] = List#{
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, citeLinkContent()) }),
         "<figure data-quote><blockquote><p>引用</p></blockquote><figcaption>${citeContentLinkHtml()}</figcaption></figure>"),
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ marked("bold", "著者") }) }),
         "<figure data-quote><blockquote><p>引用</p></blockquote><figcaption><cite><strong>著者</strong></cite></figcaption></figure>"),
        // 旧 attrs だけの doc も同じ形（cite の文字に citeUrl のリンクが掛かる）
        (doc(List#{ blockquoteWith(List#{ s("cite", "著者"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }),
         "<figure data-quote><blockquote><p>引用</p></blockquote><figcaption>${citeContentLinkHtml()}</figcaption></figure>"),
        // 両方あれば content が勝つ
        (doc(List#{ CmsTestKit.richNode("blockquote", List#{ s("cite", "旧") }, List#{ simpleParagraph("引用"), quoteCite(List#{ plain("新") }) }) }),
         "<figure data-quote><blockquote><p>引用</p></blockquote><figcaption><cite>新</cite></figcaption></figure>"),
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, Nil) }), "<blockquote><p>引用</p></blockquote>"),
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ plain("") }) }), "<blockquote><p>引用</p></blockquote>")
    }

    @Test
    def testToHtmlQuoteCiteContent(): Unit \ Assert =
        Assert.assertEq(
            expected = quoteCiteHtmlPairs() |> List.map(snd),
            quoteCiteHtmlPairs() |> List.map(fst) |> List.map(html))

    /// 平文。出典は `— 出典` の 1 行で、URL は出ない。旧 attrs も同じ。
    def quoteCiteTextPairs(): List[(Json, String)] = List#{
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, citeLinkContent()) }), "引用\n— 著者"),
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ marked("bold", "著"), plain("者") }) }), "引用\n— 著者"),
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, Nil) }), "引用"),
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, citeLinkContent()), simpleParagraph("次") }), "引用\n— 著者\n\n次")
    }

    @Test
    def testToTextQuoteCiteContent(): Unit \ Assert =
        Assert.assertEq(
            expected = quoteCiteTextPairs() |> List.map(snd),
            quoteCiteTextPairs() |> List.map(fst) |> List.map(RichText.toText))

    /// Markdown の書き出し。引用の最後に空行を挟んで `> — …`。中は inline Markdown。旧 attrs も同じ形で出る。
    def quoteCiteWritePairs(): List[(Json, String)] = List#{
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, citeLinkContent()) }), "> 引用\n>\n> — [著者](https://src.example/)"),
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ marked("bold", "著者"), plain(" より") }) }), "> 引用\n>\n> — **著者** より"),
        (doc(List#{ blockquoteWith(List#{ s("cite", "著者"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }), "> 引用\n>\n> — [著者](https://src.example/)"),
        (doc(List#{ CmsTestKit.richNode("blockquote", List#{ s("cite", "旧") }, List#{ simpleParagraph("引用"), quoteCite(List#{ plain("新") }) }) }), "> 引用\n>\n> — 新"),
        (doc(List#{ quoted(List#{ simpleParagraph("引用") }, Nil) }), "> 引用")
    }

    @Test
    def testToMarkdownQuoteCiteContent(): Unit \ Assert =
        Assert.assertEq(
            expected = quoteCiteWritePairs() |> List.map(snd),
            quoteCiteWritePairs() |> List.map(fst) |> List.map(Markdown.toMarkdown))

    /// Markdown の読み。出典に付けられないマークは落として、必ず validate に通る doc を返す。
    def quoteCiteReadPairs(): List[(String, Json)] = List#{
        ("> 引用\n>\n> — **著者** より", doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ marked("bold", "著者"), plain(" より") }) })),
        ("> 引用\n>\n> — ==著者==", doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ plain("著者") }) })),
        ("> 引用\n>\n> — <u>著者</u>", doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ plain("著者") }) }))
    }

    @Test
    def testFromMarkdownQuoteCiteContent(): Unit \ Assert =
        Assert.assertEq(
            expected = quoteCiteReadPairs() |> List.map(snd),
            quoteCiteReadPairs() |> List.map(fst) |> List.map(Markdown.fromMarkdown))

    /// 読んだ doc は必ず検査に通る。
    @Test
    def testFromMarkdownQuoteCiteValidates(): Unit \ Assert =
        Assert.assertEq(
            expected = quoteCiteReadPairs() |> List.map(_ -> true),
            quoteCiteReadPairs() |> List.map(fst) |> List.map(text -> List.isEmpty(RichText.validate("fields.body", Markdown.fromMarkdown(text)))))

    /// 往復。link / bold / 出典の後ろの文字 / 2 段落の引用。
    def roundTripQuoteCiteDocs(): List[Json] = List#{
        doc(List#{ quoted(List#{ simpleParagraph("引用") }, citeLinkContent()) }),
        doc(List#{ quoted(List#{ simpleParagraph("引用") }, List#{ marked("bold", "著者"), plain(" より") }) }),
        doc(List#{ quoted(List#{ simpleParagraph("引用"), simpleParagraph("二段落目") }, List#{ plain("著者") }) }),
        doc(List#{ quoted(List#{ simpleParagraph("引用") }, citeLinkContent()), simpleParagraph("次") })
    }

    @Test
    def testRoundTripKeepsQuoteCiteContent(): Unit \ Assert =
        Assert.assertEq(
            expected = roundTripQuoteCiteDocs(),
            roundTripQuoteCiteDocs() |> List.map(roundTrip))

    /// 旧 attrs の doc は往復で content の形になる（書き出しは content だけ）。
    @Test
    def testRoundTripMigratesLegacyCite(): Unit \ Assert =
        Assert.assertEq(
            expected = doc(List#{ quoted(List#{ simpleParagraph("引用") }, citeLinkContent()) }),
            roundTrip(doc(List#{ blockquoteWith(List#{ s("cite", "著者"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) })))


    // ================================================================
    // 9. image は 1 枚でも複数枚でも同じノード。キャプションは画像ごと
    // ================================================================

    /// 3 枚（キャプション無し）。
    def three(): Json = pictures(List#{ item(Nil, Nil), item(Nil, Nil), item(Nil, Nil) })

    /// 素の img（キャプションの無い画像）。
    def bareImg(): String = "<img src=\"u\" alt=\"\">"

    ///
    /// 検査。1 行 = (ノード, 通るか)。image の中は imageItem だけで、1 つ以上。imageItem は image の外に置けない。
    /// 旧い形（attrs.assetId の image、gallery）も通る。
    ///
    def validatePicturesPairs(): List[(Json, Bool)] = List#{
        (one(Nil, Nil), true),
        (three(), true),
        (pictures(List#{ item(Nil, List#{ plain("1 枚目") }), item(Nil, Nil) }), true),
        // 画像が 1 枚も無い
        (pictures(Nil), false),
        // image の中に置けるのは imageItem だけ
        (pictures(List#{ item(Nil, Nil), image(Nil) }), false),
        (pictures(List#{ item(Nil, Nil), simpleParagraph("段落") }), false),
        // キャプションのマークは今までと同じ制限
        (pictures(List#{ item(Nil, List#{ marked("underline", "下線") }) }), false),
        // imageItem は image の中だけ
        (item(Nil, Nil), false),
        // 旧い形（読む側だけの互換）
        (image(List#{ s("caption", "旧") }), true),
        (gallery(List#{ image(Nil), image(Nil) }), true)
    }

    @Test
    def testValidatePictures(): Unit \ Assert =
        Assert.assertEq(
            expected = validatePicturesPairs() |> List.map(snd),
            validatePicturesPairs() |> List.map(fst) |> List.map(node -> List.isEmpty(RichText.validate("fields.body", doc(List#{ node })))))

    ///
    /// HTML。1 枚は今までの image と同じ figure / img、2 枚以上は `figure data-gallery="枚数"`。
    /// キャプションのある画像だけ figure で包む。
    ///
    def picturesHtmlPairs(): List[(Json, String)] = List#{
        // 1 枚
        (doc(List#{ one(Nil, Nil) }), bareImg()),
        (doc(List#{ one(Nil, List#{ plain("説明") }) }), "<figure>${bareImg()}<figcaption>説明</figcaption></figure>"),
        // 3 枚。data-gallery は枚数
        (doc(List#{ three() }), "<figure data-gallery=\"3\">${bareImg()}${bareImg()}${bareImg()}</figure>"),
        // 画像ごとのキャプション（モックの 3 番）
        (doc(List#{ pictures(List#{ item(Nil, Nil), item(Nil, List#{ plain("2 枚目だけ説明") }), item(Nil, Nil) }) }),
         "<figure data-gallery=\"3\">${bareImg()}<figure>${bareImg()}<figcaption>2 枚目だけ説明</figcaption></figure>${bareImg()}</figure>"),
        // 旧 gallery の doc も同じ形で出る。旧 columns は見ない（data-gallery は枚数の 3）
        (doc(List#{ CmsTestKit.richNode("gallery", List#{ ("columns", CmsTestKit.intJson(2)) }, List#{ image(Nil), image(Nil), image(Nil) }) }),
         "<figure data-gallery=\"3\">${bareImg()}${bareImg()}${bareImg()}</figure>"),
        // 旧い形の image 1 枚は今までどおり
        (doc(List#{ image(List#{ s("caption", "旧") }) }), "<figure>${bareImg()}<figcaption>旧</figcaption></figure>")
    }

    @Test
    def testToHtmlPictures(): Unit \ Assert =
        Assert.assertEq(
            expected = picturesHtmlPairs() |> List.map(snd),
            picturesHtmlPairs() |> List.map(fst) |> List.map(html))

    /// Markdown の書き出し。画像の行の次の行に、枚数だけ `*…*` を空白区切りで（無い画像は `**`）。
    def picturesWritePairs(): List[(Json, String)] = List#{
        (doc(List#{ one(Nil, List#{ plain("説明") }) }), "![](asset:asset001)\n*説明*"),
        (doc(List#{ three() }), "![](asset:asset001) ![](asset:asset001) ![](asset:asset001)"),
        (doc(List#{ pictures(List#{ item(Nil, Nil), item(Nil, List#{ plain("2 枚目") }), item(Nil, Nil) }) }),
         "![](asset:asset001) ![](asset:asset001) ![](asset:asset001)\n** *2 枚目* **")
    }

    @Test
    def testToMarkdownPictures(): Unit \ Assert =
        Assert.assertEq(
            expected = picturesWritePairs() |> List.map(snd),
            picturesWritePairs() |> List.map(fst) |> List.map(Markdown.toMarkdown))

    ///
    /// Markdown の読み。`*…*` を画像の順に配る。古い `{columns=N}` は読んで捨てる。
    ///
    def picturesReadPairs(): List[(String, Json)] = List#{
        ("![](asset:asset001)\n*説明*", doc(List#{ one(Nil, List#{ plain("説明") }) })),
        ("![](asset:asset001) ![](asset:asset001) ![](asset:asset001)", doc(List#{ three() })),
        ("![](asset:asset001) ![](asset:asset001) ![](asset:asset001)\n** *2 枚目* **",
         doc(List#{ pictures(List#{ item(Nil, Nil), item(Nil, List#{ plain("2 枚目") }), item(Nil, Nil) }) })),
        ("![](asset:asset001) ![](asset:asset001) {columns=4}",
         doc(List#{ pictures(List#{ item(Nil, Nil), item(Nil, Nil) }) }))
    }

    @Test
    def testFromMarkdownPictures(): Unit \ Assert =
        Assert.assertEq(
            expected = picturesReadPairs() |> List.map(snd),
            picturesReadPairs() |> List.map(fst) |> List.map(Markdown.fromMarkdown))

    /// 往復。1 枚 / 3 枚 / 画像ごとのキャプション（マーク付き）。
    def roundTripPicturesDocs(): List[Json] = List#{
        doc(List#{ one(Nil, List#{ plain("説明") }) }),
        doc(List#{ three() }),
        doc(List#{ pictures(List#{ item(Nil, Nil), item(Nil, List#{ plain("2 枚目") }), item(Nil, Nil) }) }),
        doc(List#{ pictures(List#{ item(Nil, List#{ marked("bold", "1 枚目") }), item(Nil, List#{ linked("https://src.example/", "2 枚目") }) }) })
    }

    @Test
    def testRoundTripKeepsPictures(): Unit \ Assert =
        Assert.assertEq(
            expected = roundTripPicturesDocs(),
            roundTripPicturesDocs() |> List.map(roundTrip))

    /// 旧 gallery（と旧 columns）の doc は往復で新しい形になる。1 枚だけの gallery は 1 枚の image に。
    def legacyPicturesDocs(): List[(Json, Json)] = List#{
        (doc(List#{ CmsTestKit.richNode("gallery", List#{ ("columns", CmsTestKit.intJson(4)) }, List#{ image(Nil), image(List#{ s("caption", "旧") }) }) }),
         doc(List#{ pictures(List#{ item(Nil, Nil), item(Nil, List#{ plain("旧") }) }) })),
        (doc(List#{ gallery(List#{ image(List#{ s("caption", "旧") }) }) }), doc(List#{ one(Nil, List#{ plain("旧") }) })),
        (doc(List#{ image(List#{ s("caption", "旧") }) }), doc(List#{ one(Nil, List#{ plain("旧") }) }))
    }

    @Test
    def testRoundTripMigratesLegacyPictures(): Unit \ Assert =
        Assert.assertEq(
            expected = legacyPicturesDocs() |> List.map(snd),
            legacyPicturesDocs() |> List.map(fst) |> List.map(roundTrip))

}
