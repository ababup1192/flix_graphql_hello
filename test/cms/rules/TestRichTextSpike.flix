///
/// 画像の出典（image.attrs.source / sourceUrl）と引用の出典（blockquote.attrs.cite / citeUrl）、
/// 画像のリンク・縮小・配置（image.attrs.href / size / align）が、
/// 検査・HTML・平文・Markdown の書き出しと読み・往復（doc → Markdown → doc）で通る事を確かめる。
/// 設計は docs/design/richtext-note-style.md の 3 章と 4 章。
///
mod TestRichTextSpike {

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

    def image(attrs: List[(String, Json)]): Json =
        CmsTestKit.richLeaf("image", ("assetId", Json.JString("asset001")) :: attrs)

    /// キャプションを content に持つ image。
    def captioned(attrs: List[(String, Json)], caption: List[Json]): Json =
        CmsTestKit.richNode("image", ("assetId", Json.JString("asset001")) :: attrs, caption)

    def marked(kind: String, text: String): Json = CmsTestKit.richText(List#{ CmsTestKit.richMark(kind, Nil) }, text)

    def gallery(images: List[Json]): Json = CmsTestKit.richNode("gallery", List#{ ("columns", CmsTestKit.intJson(2)) }, images)

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
        // gallery の中の image も同じ figcaption
        (doc(List#{ gallery(List#{ image(List#{ s("caption", "写真"), s("source", "出典社"), s("sourceUrl", "https://src.example/") }), image(Nil) }) }),
         "<div data-gallery=\"2\"><figure><img src=\"u\" alt=\"\"><figcaption>写真 ${citeLink()}</figcaption></figure><figure><img src=\"u\" alt=\"\"></figure></div>")
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
        // gallery の中は figure が常にあるので size / align は figure に付く
        (doc(List#{ gallery(List#{ image(List#{ s("href", "https://go.example/"), s("size", "small") }), image(Nil) }) }),
         "<div data-gallery=\"2\"><figure data-size=\"small\">${linkedImg("")}</figure><figure><img src=\"u\" alt=\"\"></figure></div>")
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
            RichText.toText(doc(List#{ gallery(List#{ image(List#{ s("caption", "写真"), s("href", "https://go.example/"), s("size", "small"), s("align", "left") }) }) })))

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
         doc(List#{ captioned(List#{ ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)), s("source", "出典社"), s("sourceUrl", "https://src.example/") }, List#{ plain("写真") }) })),
        // 知らない key は捨てる。並びの順も問わない
        ("![](asset:asset001){foo=bar height=450 width=800}",
         doc(List#{ image(List#{ ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }) })),
        // width と height は片方だけなら無視
        ("![](asset:asset001){width=800 source=\"出典社\"}",
         doc(List#{ image(List#{ s("source", "出典社") }) })),
        // `\"` のエスケープ
        ("![](asset:asset001){source=\"a \\\"b\\\"\"}",
         doc(List#{ image(List#{ s("source", "a \"b\"") }) })),
        // 空の `{}` は無いのと同じ
        ("![](asset:asset001){}",
         doc(List#{ image(Nil) })),
        // `> — [出典](URL)` は cite と citeUrl
        ("> 引用\n>\n> — [著者](https://src.example/)",
         doc(List#{ blockquoteWith(List#{ s("cite", "著者"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) })),
        // URL 無し
        ("> 引用\n>\n> — 著者",
         doc(List#{ blockquoteWith(List#{ s("cite", "著者") }, List#{ simpleParagraph("引用") }) })),
        // `[text](URL)` 1 つだけでなければ段落の文字列全部が cite
        ("> 引用\n>\n> — [著者](https://src.example/) より",
         doc(List#{ blockquoteWith(List#{ s("cite", "著者 より") }, List#{ simpleParagraph("引用") }) })),
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
         doc(List#{ image(List#{ s("href", "https://go.example/") }) })),
        ("[![](asset:asset001){source=\"出典社\"}](https://go.example/)\n*写真*",
         doc(List#{ captioned(List#{ s("href", "https://go.example/"), s("source", "出典社") }, List#{ plain("写真") }) })),
        ("![](asset:asset001){size=small align=left}",
         doc(List#{ image(List#{ s("size", "small"), s("align", "left") }) })),
        ("![](asset:asset001){align=right}",
         doc(List#{ image(List#{ s("align", "right") }) })),
        ("[![説明](asset:asset001){width=800 height=450 size=small align=left source=\"出典社\" sourceUrl=https://src.example/}](https://go.example/)\n*写真*",
         doc(List#{ captioned(List#{ s("alt", "説明"), s("href", "https://go.example/"), s("size", "small"), s("align", "left"), s("source", "出典社"), s("sourceUrl", "https://src.example/"), ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }, List#{ plain("写真") }) })),
        // gallery の中でも同じ
        ("[![](asset:asset001){size=small}](https://go.example/) ![](asset:asset001)",
         doc(List#{ gallery(List#{ image(List#{ s("href", "https://go.example/"), s("size", "small") }), image(Nil) }) })),
        // 決まった値でない size / align は捨てる（validate に通る doc を返す）
        ("![](asset:asset001){size=large align=center}",
         doc(List#{ image(Nil) })),
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
        doc(List#{ captioned(List#{ s("alt", "説明"), s("source", "出典社"), s("sourceUrl", "https://src.example/"), ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }, List#{ plain("写真") }) }),
        doc(List#{ image(List#{ s("source", "a \"b\" [c]") }) }),
        doc(List#{ gallery(List#{ image(List#{ s("source", "出典社") }), image(List#{ s("sourceUrl", "https://src.example/") }) }) }),
        doc(List#{ blockquoteWith(List#{ s("cite", "著者"), s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }),
        doc(List#{ blockquoteWith(List#{ s("cite", "著者") }, List#{ simpleParagraph("引用"), simpleParagraph("二段落目") }) }),
        doc(List#{ blockquoteWith(List#{ s("citeUrl", "https://src.example/") }, List#{ simpleParagraph("引用") }) }),
        doc(List#{ blockquote(List#{ simpleParagraph("引用"), paragraph(List#{ plain("— "), linked("https://src.example/", "出典") }) }) }),
        doc(List#{ blockquote(List#{ simpleParagraph("— 本文だけ") }) }),
        doc(List#{ simpleParagraph("— 本文") })
    }

    @Test
    def testRoundTripKeepsSource(): Unit \ Assert =
        Assert.assertEq(
            expected = roundTripDocs(),
            roundTripDocs() |> List.map(roundTrip))

    /// href だけ / href + caption + source / size + align（left / right） / 3 つ全部 / gallery の中。
    def roundTripPlacementDocs(): List[Json] = List#{
        doc(List#{ image(List#{ s("href", "https://go.example/") }) }),
        doc(List#{ captioned(List#{ s("href", "https://go.example/"), s("source", "出典社") }, List#{ plain("写真") }) }),
        doc(List#{ image(List#{ s("size", "small"), s("align", "left") }) }),
        doc(List#{ image(List#{ s("size", "small"), s("align", "right") }) }),
        doc(List#{ captioned(List#{ s("alt", "説明"), s("href", "https://go.example/"), s("size", "small"), s("align", "left"), s("source", "出典社"), s("sourceUrl", "https://src.example/"), ("width", CmsTestKit.intJson(800)), ("height", CmsTestKit.intJson(450)) }, List#{ plain("写真") }) }),
        doc(List#{ gallery(List#{ image(List#{ s("href", "https://go.example/"), s("size", "small") }), image(List#{ s("align", "left") }) }) }),
        doc(List#{ image(List#{ s("href", "https://go.example/") }), simpleParagraph("次") })
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
         "<div data-gallery=\"2\"><figure><img src=\"u\" alt=\"\"><figcaption>${captionLinkHtml()}</figcaption></figure><figure><img src=\"u\" alt=\"\"><figcaption>旧</figcaption></figure></div>")
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
         "![](asset:asset001) ![](asset:asset001) ![](asset:asset001) {columns=2}\n** *撮影: [山田](https://src.example/)* *旧*"),
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
    /// 旧 title は content に写す、title と行の両方あれば行が勝つ、gallery の枚数より少ない `*…*` は前から詰める。
    ///
    def captionReadPairs(): List[(String, Json)] = List#{
        ("![](asset:asset001)\n*撮影: [山田](https://src.example/)*", doc(List#{ captioned(Nil, linkCaption()) })),
        ("![](asset:asset001)\n***太** と _斜_*", doc(List#{ captioned(Nil, List#{ marked("bold", "太"), plain(" と "), marked("italic", "斜") }) })),
        ("![](asset:asset001)\n*a \\* b\\**", doc(List#{ captioned(Nil, List#{ plain("a * b*") }) })),
        ("![](asset:asset001)\n\n*写真*", doc(List#{ image(Nil), paragraph(List#{ marked("italic", "写真") }) })),
        ("![](asset:asset001)\n*写真", doc(List#{ paragraph(List#{ plain("![](asset:asset001)\n*写真") }) })),
        ("![](asset:asset001)\n*写真*\n続き", doc(List#{ paragraph(List#{ plain("![](asset:asset001)\n"), marked("italic", "写真"), plain("\n続き") }) })),
        ("![](asset:asset001 \"旧\")", doc(List#{ captioned(Nil, List#{ plain("旧") }) })),
        ("![](asset:asset001 \"旧\")\n*新*", doc(List#{ captioned(Nil, List#{ plain("新") }) })),
        ("![](asset:asset001) ![](asset:asset001) ![](asset:asset001) {columns=2}\n** *撮影: [山田](https://src.example/)* *旧*",
         doc(List#{ gallery(List#{ image(Nil), captioned(Nil, linkCaption()), captioned(Nil, List#{ plain("旧") }) }) })),
        ("![](asset:asset001) ![](asset:asset001)\n*a*", doc(List#{ gallery(List#{ captioned(Nil, List#{ plain("a") }), image(Nil) }) })),
        ("![](asset:asset001) ![](asset:asset001)\n*a* b", doc(List#{ paragraph(List#{ plain("![](asset:asset001) ![](asset:asset001)\n"), marked("italic", "a"), plain(" b") }) }))
    }

    @Test
    def testFromMarkdownCaptionContent(): Unit \ Assert =
        Assert.assertEq(
            expected = captionReadPairs() |> List.map(snd),
            captionReadPairs() |> List.map(fst) |> List.map(Markdown.fromMarkdown))

    /// 往復。link / bold / `*` の逃がし / gallery の複数キャプション / 出典と一緒。
    def roundTripCaptionDocs(): List[Json] = List#{
        doc(List#{ captioned(Nil, linkCaption()) }),
        doc(List#{ captioned(List#{ s("source", "出典社"), s("sourceUrl", "https://src.example/") }, List#{ marked("bold", "太"), plain(" と "), marked("italic", "斜"), plain(" と "), marked("strike", "消"), plain(" と "), marked("code", "c") }) }),
        doc(List#{ captioned(Nil, List#{ plain("a * b* _c_ [d]") }) }),
        doc(List#{ gallery(List#{ image(Nil), captioned(Nil, linkCaption()), captioned(List#{ s("href", "https://go.example/") }, List#{ plain("旧") }) }) }),
        doc(List#{ captioned(Nil, List#{ plain("写真") }), simpleParagraph("次") })
    }

    @Test
    def testRoundTripKeepsCaptionContent(): Unit \ Assert =
        Assert.assertEq(
            expected = roundTripCaptionDocs(),
            roundTripCaptionDocs() |> List.map(roundTrip))

}
