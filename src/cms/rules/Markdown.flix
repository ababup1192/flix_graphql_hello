///
/// richText の doc（ProseMirror 形式。RichText が正）と Markdown の双方向変換。全部純粋。
///
/// 方言は GFM + 決め事: 見出しの id は `## 見出し {#id}`、callout は GitHub alerts（`> [!NOTE]`）、image は `![alt](asset:ID){width=W height=H size=small align=left source="出典" sourceUrl=URL}`
///（`{...}` は key=value の並びで、知らない key は捨てる）、リンク付きの image は `[![alt](asset:ID){…}](https://…)`（`{…}` は image の直後）、
/// image のキャプションは画像の直後の行（空行を挟まない）に `*キャプション*`（中は inline Markdown。複数枚は画像の枚数だけ空白区切りで並べ、無い画像は `**`）、
/// 古い `![alt](asset:ID "caption")` の title は読む時だけ受ける、
/// blockquote の出典は引用の最後に空行を挟んで `> — [出典](URL)`（doc では最後の子の quoteCite。中は inline Markdown。本文の `— ` 始まりは `\— ` で逃がす）、
/// 複数枚の image は 1 行に空白区切りで並べる（古い `{columns=N}` は読んで捨てる。列数は枚数から決まる）、embed と linkCard は URL だけの段落（提供元が判れば embed）、
/// codeBlock は ```` ```言語:ファイル名 {1,3-5} ````、details は `<details><summary>…</summary>` から `</details>` の行まで、
/// entry へのリンクは `[text](entry:ID)`、underline は `<u>…</u>`、下付きは `~x~`、上付きは `^x^`、蛍光ペンは `==x==`。入れ子は 2 空白、番号は 1 から振り直す。
/// 数式は `$…$`（math マーク。TeX はそのまま）と `$$` の行で囲む mathBlock、text の `$` は `\$`。タスクリストは `- [ ]` `- [x]`（orderedList でも `1. [ ]`）。
/// video は `@[video](asset:ID "caption"){poster=asset:ID}`。Mermaid は language が mermaid の codeBlock で、Markdown では普通のフェンス。
/// 読む時は少し広く受け（`*` の箇条書き、`1)`、`***`、`__` と `*`、行末 2 空白、summary の無い `<details>`、`- [X]`）、
/// 読めない物は段落の text に落として必ず RichText.validate に通る doc を返す。
/// image は asset 管理の物だけ（`asset:`）。`![alt](URL)` は image にせず、alt を URL へのリンクにした文字に落とす。
/// link の href は `RichText.isSafeHref` が通す物（http(s) / mailto: / `/` で始まるパス / `#` の断片）だけで、他は link マークを落として文字だけ残す。
///
/// WhyNot: asset 管理外の画像を違反にしないのは、fromMarkdown が「必ず validate に通る doc を返す」約束で、違反は doc の検査の仕事のため。
/// 文字に落とす時に URL をリンクとして残すのは、書いた物が読み戻しで消えず、`\[` に化けた文字にもならないようにするため。
///
/// WhyNot: Java の Markdown ライブラリを使わないのは、方言（asset: / entry: / alerts / {#id}）を完全に握るためと、依存を増やさないため。
///
mod Markdown {

    use Util.Json.Json

    // ---- 内部の木 ----

    /// ブロック。doc の直下と listItem / blockquote / callout の中に並ぶ物。
    enum Block {
        case Paragraph(List[Inline])
        case Heading(Int32, Option[String], List[Inline])
        case BulletList(List[ListItem])
        case OrderedList(List[ListItem])
        /// (出典の inline。空なら無し, 中身)
        case Blockquote(List[Inline], List[Block])
        case CodeBlock(CodeInfo, String)
        case Table(List[List[Cell]])
        case Callout(CalloutKind, List[Block])
        case HorizontalRule
        /// 画像の塊（doc の image）。画像 1 枚以上。
        case Pictures(List[Picture])
        case Embed(String)
        case LinkCard(String)
        case Details(String, List[Block])
        case MathBlock(String)
        case Video(Clip)
    }

    /// リストの 1 項目。(タスクなら済みか, 中身)。checked が無ければ普通の項目。
    enum ListItem {
        case ListItem(Option[Bool], List[Block])
    }

    /// video 1 つ。(asset の id, caption, poster の asset の id)。
    enum Clip {
        case Clip(String, Option[String], Option[String])
    }

    /// codeBlock のフェンスに書く物。(言語, ファイル名, 強調する行, 折り返し)。
    enum CodeInfo {
        case CodeInfo(Option[String], Option[String], Option[String], Bool)
    }

    /// image 1 つ。(asset の id, alt, caption（inline。空なら無し）, (幅, 高さ), 出典, 置き方)。gallery の中でも同じ。
    enum Picture {
        case Picture(String, Option[String], List[Inline], Option[(Int32, Int32)], Attribution, Placement)
    }

    /// image の置き方。(リンク先の URL, 大きさ, 寄せ)。image の href / size / align。無ければ本文の幅で中央、リンク無し。
    enum Placement {
        case Placement(Option[String], Option[ImageSize], Option[ImageAlign])
    }

    /// image の大きさ。値は RichText.imageSizes と同じ。
    enum ImageSize with Eq {
        case Small
    }

    /// image の寄せ。値は RichText.imageAligns と同じ。
    enum ImageAlign with Eq {
        case Left
        case Right
    }

    def placementOf(fields: Map[String, Json]): Placement =
        Placement.Placement(
            attrString("href", fields) |> Option.filter(String.nonEmpty),
            attrString("size", fields) |> Option.flatMap(imageSizeOf),
            attrString("align", fields) |> Option.flatMap(imageAlignOf))

    def placementAttrs(placement: Placement): List[(String, Json)] =
        let Placement.Placement(href, size, align) = placement;
        (href |> Option.map(found -> ("href", Json.JString(found))) |> Option.toList)
            ::: (size |> Option.map(found -> ("size", Json.JString(imageSizeText(found)))) |> Option.toList)
            ::: (align |> Option.map(found -> ("align", Json.JString(imageAlignText(found)))) |> Option.toList)

    def imageSizeOf(size: String): Option[ImageSize] = match size {
        case "small" => Some(ImageSize.Small)
        case _       => None
    }

    def imageSizeText(size: ImageSize): String = match size {
        case ImageSize.Small => "small"
    }

    def imageAlignOf(align: String): Option[ImageAlign] = match align {
        case "left"  => Some(ImageAlign.Left)
        case "right" => Some(ImageAlign.Right)
        case _       => None
    }

    def imageAlignText(align: ImageAlign): String = match align {
        case ImageAlign.Left  => "left"
        case ImageAlign.Right => "right"
    }

    /// 出典。(文字, URL)。image の source / sourceUrl。空文字は無いのと同じで None。
    enum Attribution {
        case Attribution(Option[String], Option[String])
    }

    def attributionOf(textName: String, urlName: String, fields: Map[String, Json]): Attribution =
        Attribution.Attribution(attrString(textName, fields) |> Option.filter(String.nonEmpty), attrString(urlName, fields) |> Option.filter(String.nonEmpty))

    def attributionAttrs(textName: String, urlName: String, attribution: Attribution): List[(String, Json)] =
        let Attribution.Attribution(text, url) = attribution;
        (text |> Option.map(found -> (textName, Json.JString(found))) |> Option.toList)
            ::: (url |> Option.map(found -> (urlName, Json.JString(found))) |> Option.toList)

    /// summary の無い details に入れる summary。
    def defaultSummary(): String = "詳細"

    /// 表のセル。(tableHeader か, 寄せ, 中身)。
    /// **寄せは列の属性**（区切り行が列に 1 つしか持てない）。JSON はセルごとに同じ値を持つ。
    enum Cell {
        case Cell(Bool, Option[String], List[Block])
    }

    /// callout の種類。
    enum CalloutKind with Eq {
        case Note
        case Tip
        case Warning
    }

    /// 段落の中身。text はマーク付き（外側が先頭）。
    enum Inline {
        case Text(List[Mark], String)
        case HardBreak
    }

    /// text のマーク。
    enum Mark with Eq {
        case Bold
        case Italic
        case Strike
        case Underline
        case Code
        case Link(LinkTarget)
        case Math
        case Sub
        case Sup
        case Highlight
    }

    /// link の先。外部の URL か、この CMS の entry。
    enum LinkTarget with Eq {
        case Href(String)
        case Entry(String)
    }

    ///
    /// doc を Markdown にする。空の段落は出さず、ブロックは空行で区切る。末尾に改行は付けない。
    ///
    pub def toMarkdown(doc: Json): String =
        objectFields(doc) |> Option.map(fields -> blocksOf(children(fields))) |> Option.getWithDefault(Nil) |> renderBlocks

    ///
    /// Markdown を doc にする。壊れた入力でも止まらず、RichText.validate に通る形を返す。
    ///
    pub def fromMarkdown(text: String): Json =
        objectNode("doc", Nil, text |> normalizeNewlines |> String.splitOn(substr = "\n") |> parseBlocks |> List.map(blockJson))

    // ---- doc（JSON）→ 木 ----

    def blocksOf(nodes: List[Json]): List[Block] = nodes |> List.filterMap(blockOf)

    def blockOf(node: Json): Option[Block] = objectFields(node) |> Option.flatMap(fields -> match typeOf(fields) {
        case Some("paragraph")      => Some(Block.Paragraph(inlinesOf(fields)))
        case Some("heading")        => Some(Block.Heading(attrInt("level", fields) |> Option.getWithDefault(1) |> clampLevel, attrString("id", fields), inlinesOf(fields)))
        case Some("bulletList")     => Some(Block.BulletList(listItemsOf(fields)))
        case Some("orderedList")    => Some(Block.OrderedList(listItemsOf(fields)))
        case Some("blockquote")     => Some(Block.Blockquote(quoteCiteOf(fields), blocksOf(quoteBody(fields))))
        case Some("codeBlock")      => Some(Block.CodeBlock(CodeInfo.CodeInfo(attrString("language", fields), attrString("fileName", fields), attrString("highlightLines", fields), attrBool("wrap", fields) |> Option.getWithDefault(false)), childrenText(fields)))
        case Some("table")          => Some(Block.Table(children(fields) |> List.filterMap(rowOf)))
        case Some("callout")        => attrString("kind", fields) |> Option.flatMap(calloutKindOf) |> Option.map(kind -> Block.Callout(kind, blocksOf(children(fields))))
        case Some("horizontalRule") => Some(Block.HorizontalRule)
        case Some("image")          => picturesOf(fields)
        case Some("gallery")        => picturesBlockOf(children(fields) |> List.filterMap(objectFields) |> List.filter(child -> typeOf(child) == Some("image")) |> List.filterMap(pictureOf))
        case Some("embed")          => attrString("url", fields) |> Option.map(Block.Embed)
        case Some("linkCard")       => attrString("url", fields) |> Option.map(Block.LinkCard)
        case Some("details")        => Some(Block.Details(attrString("summary", fields) |> Option.filter(String.nonEmpty) |> Option.getWithDefault(defaultSummary()), blocksOf(children(fields))))
        case Some("mathBlock")      => attrString("tex", fields) |> Option.map(Block.MathBlock)
        case Some("video")          => attrString("assetId", fields) |> Option.map(assetId -> Block.Video(Clip.Clip(assetId, attrString("caption", fields) |> Option.filter(String.nonEmpty), attrString("poster", fields))))
        case _                      => None
    })

    ///
    /// image ノード。content の imageItem を画像に。attrs.assetId のある古い形は 1 枚の image として読む。
    ///
    def picturesOf(fields: Map[String, Json]): Option[Block] =
        if (Option.nonEmpty(attrString("assetId", fields)))
            pictureOf(fields) |> Option.flatMap(picture -> picturesBlockOf(picture :: Nil))
        else
            picturesBlockOf(childFields(fields) |> List.filter(child -> typeOf(child) == Some("imageItem")) |> List.filterMap(pictureOf))

    /// 画像の塊。画像が無ければ何も作らない。
    def picturesBlockOf(pictures: List[Picture]): Option[Block] =
        if (List.isEmpty(pictures)) None else Some(Block.Pictures(pictures))

    def childFields(fields: Map[String, Json]): List[Map[String, Json]] =
        children(fields) |> List.filterMap(objectFields)

    def pictureOf(fields: Map[String, Json]): Option[Picture] =
        attrString("assetId", fields) |> Option.map(assetId -> Picture.Picture(assetId, attrString("alt", fields) |> Option.filter(String.nonEmpty), captionOf(fields), dimensionsOf(fields), attributionOf("source", "sourceUrl", fields), placementOf(fields)))

    /// image のキャプション。content があればその text（hardBreak は落とす）、無ければ attrs.caption を text 1 つに。
    def captionOf(fields: Map[String, Json]): List[Inline] =
        if (List.isEmpty(children(fields))) attrString("caption", fields) |> Option.filter(String.nonEmpty) |> Option.map(found -> Inline.Text(Nil, found)) |> Option.toList
        else inlinesOf(fields) |> List.filter(inline -> not isHardBreak(inline))

    ///
    /// 引用の出典。content の最後の quoteCite があればその text（hardBreak は落とす）、
    /// 無ければ旧 attrs.cite / citeUrl を text 1 つに（citeUrl があればその文字に link マークを掛ける）。
    ///
    def quoteCiteOf(fields: Map[String, Json]): List[Inline] = match quoteCiteNode(fields) {
        case Some(cite) => inlinesOf(cite) |> List.filter(inline -> not isHardBreak(inline))
        case None       =>
            match (attrString("cite", fields) |> Option.filter(String.nonEmpty), attrString("citeUrl", fields) |> Option.filter(String.nonEmpty)) {
                case (Some(found), Some(href)) => Inline.Text(Mark.Link(LinkTarget.Href(href)) :: Nil, found) :: Nil
                case (None, Some(href))        => Inline.Text(Mark.Link(LinkTarget.Href(href)) :: Nil, href) :: Nil
                case (Some(found), None)       => Inline.Text(Nil, found) :: Nil
                case (None, None)              => Nil
            }
    }

    /// content の最後に置かれた quoteCite。
    def quoteCiteNode(fields: Map[String, Json]): Option[Map[String, Json]] =
        children(fields) |> List.reverse |> List.head |> Option.flatMap(objectFields)
            |> Option.filter(child -> typeOf(child) == Some("quoteCite"))

    /// 引用の本文。出典の quoteCite を除いた子。
    def quoteBody(fields: Map[String, Json]): List[Json] =
        children(fields) |> List.filter(child -> objectFields(child) |> Option.flatMap(typeOf) != Some("quoteCite"))

    def isHardBreak(inline: Inline): Bool = match inline {
        case Inline.HardBreak => true
        case _                => false
    }

    def dimensionsOf(fields: Map[String, Json]): Option[(Int32, Int32)] =
        attrInt("width", fields) |> Option.flatMap(width -> attrInt("height", fields) |> Option.map(height -> (width, height)))

    def listItemsOf(fields: Map[String, Json]): List[ListItem] =
        children(fields) |> List.filterMap(objectFields) |> List.filter(item -> typeOf(item) == Some("listItem"))
            |> List.map(item -> ListItem.ListItem(Map.get("checked", attrs(item)) |> Option.flatMap(EntryValue.asBool), blocksOf(children(item))))

    def rowOf(node: Json): Option[List[Cell]] =
        objectFields(node) |> Option.filter(fields -> typeOf(fields) == Some("tableRow")) |> Option.map(fields -> children(fields) |> List.filterMap(cellOf))

    def cellOf(node: Json): Option[Cell] = objectFields(node) |> Option.flatMap(fields -> match typeOf(fields) {
        case Some("tableHeader") => Some(Cell.Cell(true, alignOf(fields), blocksOf(children(fields))))
        case Some("tableCell")   => Some(Cell.Cell(false, alignOf(fields), blocksOf(children(fields))))
        case _                   => None
    })

    def alignOf(fields: Map[String, Json]): Option[String] =
        Map.get("align", attrs(fields)) |> Option.flatMap(EntryValue.asString)
            |> Option.filter(align -> List.memberOf(align, RichText.cellAligns()))

    def inlinesOf(fields: Map[String, Json]): List[Inline] = children(fields) |> List.filterMap(inlineOf)

    def inlineOf(node: Json): Option[Inline] = objectFields(node) |> Option.flatMap(fields -> match typeOf(fields) {
        case Some("text")      => Map.get("text", fields) |> Option.flatMap(EntryValue.asString) |> Option.map(text -> Inline.Text(marksOf(fields) |> List.filterMap(markOf), text))
        case Some("hardBreak") => Some(Inline.HardBreak)
        case _                 => None
    })

    def markOf(mark: Map[String, Json]): Option[Mark] = match typeOf(mark) {
        case Some("bold")      => Some(Mark.Bold)
        case Some("italic")    => Some(Mark.Italic)
        case Some("strike")    => Some(Mark.Strike)
        case Some("underline") => Some(Mark.Underline)
        case Some("code")      => Some(Mark.Code)
        case Some("link")      => linkTargetOf(mark) |> Option.map(Mark.Link)
        case Some("math")      => Some(Mark.Math)
        case Some("sub")       => Some(Mark.Sub)
        case Some("sup")       => Some(Mark.Sup)
        case Some("highlight") => Some(Mark.Highlight)
        case _                 => None
    }

    def linkTargetOf(mark: Map[String, Json]): Option[LinkTarget] =
        attrString("href", mark) |> Option.map(LinkTarget.Href) |> Option.withDefault(default = attrString("entryId", mark) |> Option.map(LinkTarget.Entry))

    def calloutKindOf(kind: String): Option[CalloutKind] = match String.toLowerCase(kind) {
        case "note"    => Some(CalloutKind.Note)
        case "tip"     => Some(CalloutKind.Tip)
        case "warning" => Some(CalloutKind.Warning)
        case _         => None
    }

    def calloutLabel(kind: CalloutKind): String = match kind {
        case CalloutKind.Note    => "NOTE"
        case CalloutKind.Tip     => "TIP"
        case CalloutKind.Warning => "WARNING"
    }

    def clampLevel(level: Int32): Int32 = Int32.max(1, Int32.min(level, RichText.maxHeadingLevel()))

    // ---- 木 → doc（JSON）----

    def blockJson(block: Block): Json = match block {
        case Block.Paragraph(inlines)              => objectNode("paragraph", Nil, inlines |> List.map(inlineJson))
        case Block.Heading(level, id, inlines)     => objectNode("heading", ("level", intJson(level)) :: (id |> Option.map(found -> ("id", Json.JString(found))) |> Option.toList), inlines |> List.map(inlineJson))
        case Block.BulletList(items)               => objectNode("bulletList", Nil, items |> List.map(listItemJson))
        case Block.OrderedList(items)              => objectNode("orderedList", Nil, items |> List.map(listItemJson))
        case Block.Blockquote(cite, blocks)         => objectNode("blockquote", Nil, (blocks |> List.map(blockJson)) ::: quoteCiteJson(cite))
        case Block.CodeBlock(info, code)           => objectNode("codeBlock", codeInfoAttrs(info), textNode(Nil, code) :: Nil)
        case Block.Table(rows)                     => objectNode("table", Nil, rows |> List.map(cells -> objectNode("tableRow", Nil, cells |> List.map(cellJson))))
        case Block.Callout(kind, blocks)           => objectNode("callout", ("kind", Json.JString(String.toLowerCase(calloutLabel(kind)))) :: Nil, blocks |> List.map(blockJson))
        case Block.HorizontalRule                  => leafNode("horizontalRule", Nil)
        case Block.Pictures(pictures)              => objectNode("image", Nil, pictures |> List.map(pictureJson))
        case Block.Embed(url)                      => leafNode("embed", ("url", Json.JString(url)) :: Nil)
        case Block.LinkCard(url)                   => leafNode("linkCard", ("url", Json.JString(url)) :: Nil)
        case Block.Details(summary, blocks)        => objectNode("details", ("summary", Json.JString(summary)) :: Nil, blocks |> List.map(blockJson))
        case Block.MathBlock(tex)                  => leafNode("mathBlock", ("tex", Json.JString(tex)) :: Nil)
        case Block.Video(clip)                     => clipJson(clip)
    }

    def clipJson(clip: Clip): Json =
        let Clip.Clip(assetId, caption, poster) = clip;
        leafNode("video",
            (("assetId", Json.JString(assetId)) :: Nil)
                ::: (caption |> Option.map(found -> ("caption", Json.JString(found))) |> Option.toList)
                ::: (poster |> Option.map(found -> ("poster", Json.JString(found))) |> Option.toList))

    /// 出典は引用の最後の quoteCite に出す（attrs.cite には書かない）。空なら node 自体を付けない。
    def quoteCiteJson(cite: List[Inline]): List[Json] =
        if (List.isEmpty(cite)) Nil else objectNode("quoteCite", Nil, cite |> List.map(inlineJson)) :: Nil

    def codeInfoAttrs(info: CodeInfo): List[(String, Json)] =
        let CodeInfo.CodeInfo(language, fileName, highlightLines, wrap) = info;
        (language |> Option.map(found -> ("language", Json.JString(found))) |> Option.toList)
            ::: (fileName |> Option.map(found -> ("fileName", Json.JString(found))) |> Option.toList)
            ::: (highlightLines |> Option.map(found -> ("highlightLines", Json.JString(found))) |> Option.toList)
            ::: (if (wrap) ("wrap", Json.JBool(true)) :: Nil else Nil)

    /// 画像 1 枚（imageItem）。image は 1 枚でも複数枚でも imageItem を並べた同じ形で、列数は持たない。caption は content に出す（attrs.caption には書かない）。空なら content 自体を付けない。
    def pictureJson(picture: Picture): Json =
        let Picture.Picture(assetId, alt, caption, dimensions, attribution, placement) = picture;
        let attrs =
            (("assetId", Json.JString(assetId)) :: Nil)
                ::: (alt |> Option.map(found -> ("alt", Json.JString(found))) |> Option.toList)
                ::: (dimensions |> Option.map(match (width, height) -> ("width", intJson(width)) :: ("height", intJson(height)) :: Nil) |> Option.getWithDefault(Nil))
                ::: attributionAttrs("source", "sourceUrl", attribution)
                ::: placementAttrs(placement);
        if (List.isEmpty(caption)) leafNode("imageItem", attrs) else objectNode("imageItem", attrs, caption |> List.map(inlineJson))

    def listItemJson(item: ListItem): Json =
        let ListItem.ListItem(checked, blocks) = item;
        objectNode("listItem", checked |> Option.map(found -> ("checked", Json.JBool(found))) |> Option.toList, blocks |> List.map(blockJson))

    def cellJson(cell: Cell): Json =
        let Cell.Cell(isHeader, align, blocks) = cell;
        let attrs = align |> Option.map(found -> ("align", Json.JString(found))) |> Option.toList;
        objectNode(if (isHeader) "tableHeader" else "tableCell", attrs, blocks |> List.map(blockJson))

    def inlineJson(inline: Inline): Json = match inline {
        case Inline.Text(marks, text) => textNode(marks |> List.map(markJson), text)
        case Inline.HardBreak         => leafNode("hardBreak", Nil)
    }

    def markJson(mark: Mark): Json = match mark {
        case Mark.Bold                            => leafNode("bold", Nil)
        case Mark.Italic                          => leafNode("italic", Nil)
        case Mark.Strike                          => leafNode("strike", Nil)
        case Mark.Underline                       => leafNode("underline", Nil)
        case Mark.Code                            => leafNode("code", Nil)
        case Mark.Link(LinkTarget.Href(href))     => leafNode("link", ("href", Json.JString(href)) :: Nil)
        case Mark.Link(LinkTarget.Entry(entryId)) => leafNode("link", ("entryId", Json.JString(entryId)) :: Nil)
        case Mark.Math                            => leafNode("math", Nil)
        case Mark.Sub                             => leafNode("sub", Nil)
        case Mark.Sup                             => leafNode("sup", Nil)
        case Mark.Highlight                       => leafNode("highlight", Nil)
    }

    /// 子を持つノード。content は空でも付ける（doc と空の段落の形）。attrs は空なら付けない。
    def objectNode(kind: String, attrs: List[(String, Json)], content: List[Json]): Json =
        Json.JObject(Map#{ "type" => Json.JString(kind), "content" => Json.JArray(List.toVector(content)) } |> withAttrs(attrs))

    /// 子を持たないノードとマーク。attrs は空なら付けない。
    def leafNode(kind: String, attrs: List[(String, Json)]): Json =
        Json.JObject(Map#{ "type" => Json.JString(kind) } |> withAttrs(attrs))

    def textNode(marks: List[Json], text: String): Json =
        Json.JObject(Map#{ "type" => Json.JString("text"), "text" => Json.JString(text) }
            |> fields -> if (List.isEmpty(marks)) fields else Map.insert("marks", Json.JArray(List.toVector(marks)), fields))

    def withAttrs(attrs: List[(String, Json)], fields: Map[String, Json]): Map[String, Json] =
        if (List.isEmpty(attrs)) fields else Map.insert("attrs", Json.JObject(List.toMap(attrs)), fields)

    def intJson(n: Int32): Json = Json.JNumber(Int32.toBigDecimal(n))

    // ---- 木 → Markdown ----

    def renderBlocks(blocks: List[Block]): String = blocks |> List.filterMap(renderBlock) |> List.join("\n\n")

    /// 1 ブロック。空の段落は None。
    def renderBlock(block: Block): Option[String] = match block {
        case Block.Paragraph(inlines)            => Some(renderInlines("\\\n", inlines) |> guardLineStarts) |> Option.filter(String.nonEmpty)
        case Block.Heading(level, id, inlines)   => Some("${String.repeat(level, "#")} ${renderInlines("<br>", inlines)}${id |> Option.map(found -> " {#${found}}") |> Option.getWithDefault("")}")
        case Block.BulletList(items)             => Some(items |> List.map(renderListItem("- ")) |> List.join("\n"))
        case Block.OrderedList(items)            => Some(items |> List.zipWithIndex |> List.map(match (index, item) -> renderListItem("${index + 1}. ", item)) |> List.join("\n"))
        case Block.Blockquote(cite, blocks)       => Some((renderBlocks(blocks) :: (citeLine(cite) |> Option.toList)) |> List.filter(String.nonEmpty) |> List.join("\n\n") |> prefixLines(">"))
        case Block.Callout(kind, blocks)         => Some(("[!${calloutLabel(kind)}]" :: (Some(renderBlocks(blocks)) |> Option.filter(String.nonEmpty) |> Option.toList)) |> List.join("\n") |> prefixLines(">"))
        case Block.CodeBlock(info, code)         => Some(renderCodeBlock(info, code))
        case Block.Table(rows)                   => Some(renderTable(rows))
        case Block.HorizontalRule                => Some("---")
        case Block.Pictures(pictures)            => Some((pictures |> List.map(renderPicture) |> List.join(" ")) ++ captionLine(pictures))
        case Block.Embed(url)                    => Some(url)
        case Block.LinkCard(url)                 => Some(url)
        case Block.Details(summary, blocks)      => Some(("<details><summary>${summary}</summary>" :: (Some(renderBlocks(blocks)) |> Option.filter(String.nonEmpty) |> Option.toList) ::: ("</details>" :: Nil)) |> List.join("\n\n"))
        case Block.MathBlock(tex)                => Some("$$\n${tex}\n$$")
        case Block.Video(clip)                   => Some(renderClip(clip))
    }

    /// `@[video](asset:ID "caption"){poster=asset:ID}`。caption と poster は無ければ書かない。
    def renderClip(clip: Clip): String =
        let Clip.Clip(assetId, caption, poster) = clip;
        "@[video](asset:${assetId}${caption |> Option.map(found -> " \"${escapeTitle(found)}\"") |> Option.getWithDefault("")})${poster |> Option.map(found -> "{poster=asset:${found}}") |> Option.getWithDefault("")}"

    ///
    /// `![alt](asset:ID){width=W height=H size=small align=left source="出典" sourceUrl=URL}`。caption はここには書かず、captionLine が次の行に出す。
    /// `{...}` は中身が無ければ書かない。href があれば全体を `[…](URL)` で巻く（`{...}` は image の直後で、リンクの括弧の内側）。
    ///
    /// WhyNot: `{...}` をリンクの外側 `[![…](…)](URL){…}` に置く形を書かず、読みもしない。
    /// 往復の形を 1 つにするため。両方を読むと、同じ doc に 2 通りの Markdown が対応し、
    /// 手で書いた物の diff が揺れる。
    ///
    /// WhyNot: caption を title（`"…"`）に書かない。title は文字列しか持てず、リンクや太字を持つキャプションが落ちる。
    /// 読む時だけ古い title を受ける。
    ///
    def renderPicture(picture: Picture): String =
        let Picture.Picture(assetId, alt, _, dimensions, attribution, placement) = picture;
        let Attribution.Attribution(source, sourceUrl) = attribution;
        let Placement.Placement(href, size, align) = placement;
        let pairs =
            (dimensions |> Option.map(match (width, height) -> "width=${width}" :: "height=${height}" :: Nil) |> Option.getWithDefault(Nil))
                ::: (size |> Option.map(found -> "size=${imageSizeText(found)}") |> Option.toList)
                ::: (align |> Option.map(found -> "align=${imageAlignText(found)}") |> Option.toList)
                ::: (source |> Option.map(found -> "source=\"${escapeTitle(found)}\"") |> Option.toList)
                ::: (sourceUrl |> Option.map(found -> "sourceUrl=${bareOrQuoted(found)}") |> Option.toList);
        let braces = if (List.isEmpty(pairs)) "" else "{${List.join(" ", pairs)}}";
        let image = "![${alt |> Option.map(escape) |> Option.getWithDefault("")}](asset:${assetId})${braces}";
        href |> Option.map(found -> "[${image}](${found})") |> Option.getWithDefault(image)

    ///
    /// image の行の直後に置くキャプションの行（先頭の改行込み）。画像ごとに `*キャプション*` を空白で並べ、無い画像は `**`。
    /// どの画像にも無ければ空。中身は普通の inline Markdown で、`*` は escape が `\*` に逃がす。
    ///
    /// WhyNot: gallery で 1 行に 1 つのキャプションにしない。gallery は画像ごとにキャプションを持つので、
    /// 行を分けると何枚目の物か読めなくなる。
    ///
    def captionLine(pictures: List[Picture]): String =
        if (List.forAll(picture -> List.isEmpty(captionInlines(picture)), pictures)) ""
        else "\n" ++ (pictures |> List.map(picture -> "*${renderInlines("", captionInlines(picture))}*") |> List.join(" "))

    def captionInlines(picture: Picture): List[Inline] =
        let Picture.Picture(_, _, caption, _, _, _) = picture;
        caption

    /// `{...}` の値。空白・`"`・`}` を含まなければ裸、含めば `"…"`。
    def bareOrQuoted(value: String): String =
        if (String.isMatch(regex = "^[^\\s\"}]+$", value)) value else "\"${escapeTitle(value)}\""

    /// 引用の最後に置く `— 出典`。中身は普通の inline Markdown（リンクを掛けた出典は `— [出典](URL)`）。空なら None。
    def citeLine(cite: List[Inline]): Option[String] =
        Some(renderInlines("", cite)) |> Option.filter(String.nonEmpty) |> Option.map(found -> "— ${found}")

    /// title の中では `"` も逃がす。
    def escapeTitle(text: String): String = escape(text) |> String.replace(src = "\"", dst = "\\\"")

    /// リストの 1 項目。1 行目に印（タスクなら `[ ]` / `[x]` も）、2 行目からは 2 空白。入れ子のリストの前は空行を挟まない。
    def renderListItem(marker: String, item: ListItem): String =
        let ListItem.ListItem(checked, blocks) = item;
        let taskMarker = marker ++ (checked |> Option.map(found -> if (found) "[x] " else "[ ] ") |> Option.getWithDefault(""));
        let lines = blocks |> List.filterMap(block -> renderBlock(block) |> Option.map(text -> (isList(block), text))) |> joinItemBlocks |> String.splitOn(substr = "\n");
        match lines {
            case first :: rest => (String.trimRight(taskMarker ++ first) :: (rest |> List.map(line -> if (String.isEmpty(line)) "" else "  ${line}"))) |> List.join("\n")
            case Nil           => String.trimRight(taskMarker)
        }

    def joinItemBlocks(rendered: List[(Bool, String)]): String =
        rendered |> List.zipWithIndex |> List.map(match (index, (isNestedList, text)) -> if (index == 0) text else if (isNestedList) "\n${text}" else "\n\n${text}") |> List.join("")

    def isList(block: Block): Bool = match block {
        case Block.BulletList(_)  => true
        case Block.OrderedList(_) => true
        case _                    => false
    }

    /// 各行の頭に印を付ける。空行は印だけ。
    def prefixLines(marker: String, text: String): String =
        text |> String.splitOn(substr = "\n") |> List.map(line -> if (String.isEmpty(line)) marker else "${marker} ${line}") |> List.join("\n")

    /// フェンスは ```` ```言語:ファイル名 {1,3-5 wrap} ````（無い物は書かない）。
    /// 中身に並ぶ ` の最大よりも 1 つ多い数で囲む（最小は 3）ので、中身の ``` や ```` を書き出せる。
    ///
    /// WhyNot: 書き出しに ~~~ を使わない。読む側は CommonMark に合わせて受けるが、
    /// 書き出しの形が 2 通りあると往復の期待値が読めなくなる。
    def renderCodeBlock(info: CodeInfo, code: String): String =
        let CodeInfo.CodeInfo(language, fileName, highlightLines, wrap) = info;
        let longest = code |> String.splitOn(substr = "\n") |> List.map(leadingBacktickCount) |> List.foldLeft(Int32.max, 0);
        let fence = String.repeat(Int32.max(3, longest + 1), "`");
        let options = (highlightLines |> Option.toList) ::: (if (wrap) wrapMarker() :: Nil else Nil);
        let header = (language |> Option.getWithDefault(""))
            ++ (fileName |> Option.map(found -> ":${found}") |> Option.getWithDefault(""))
            ++ (if (List.isEmpty(options)) "" else " {${List.join(" ", options)}}");
        "${fence}${header}\n${code}\n${fence}"

    /// 行の頭（空白を除く）に並ぶ ` の数。
    def leadingBacktickCount(line: String): Int32 =
        line |> String.trimLeft |> String.toList |> List.takeWhile(c -> c == '`') |> List.length

    /// GFM の表。1 行目の次に区切り行。列数は 1 行目に合わせる。
    /// **寄せは 1 行目のセルから取る**（区切り行は列に 1 つしか持てない）。
    def renderTable(rows: List[List[Cell]]): String =
        let headRow = rows |> List.head |> Option.getWithDefault(Nil);
        let columns = if (List.isEmpty(headRow)) 1 else List.length(headRow);
        let marks = if (List.isEmpty(headRow)) List.repeat(columns, "---") else headRow |> List.map(alignMark);
        let separator = "| ${marks |> List.join(" | ")} |";
        match rows |> List.map(renderRow) {
            case first :: rest => (first :: separator :: rest) |> List.join("\n")
            case Nil           => separator
        }

    /// 区切り行の 1 列分。`:` の位置が寄せ。
    def alignMark(cell: Cell): String =
        let Cell.Cell(_, align, _) = cell;
        match align {
            case Some("left")   => ":---"
            case Some("center") => ":---:"
            case Some("right")  => "---:"
            case _              => "---"
        }

    def renderRow(cells: List[Cell]): String = "| ${cells |> List.map(renderCell) |> List.join(" | ")} |"

    /// セルは 1 行。段落と見出しの中身だけを空白で繋ぎ、改行は <br> に。
    def renderCell(cell: Cell): String =
        let Cell.Cell(_, _, blocks) = cell;
        blocks |> List.filterMap(cellInlines) |> List.map(renderInlines("<br>")) |> List.join(" ") |> String.replace(src = "\n", dst = " ")

    def cellInlines(block: Block): Option[List[Inline]] = match block {
        case Block.Paragraph(inlines)     => Some(inlines)
        case Block.Heading(_, _, inlines) => Some(inlines)
        case _                            => None
    }

    ///
    /// 段落の中身。同じ外側のマークが続く text はまとめて 1 組の記号で囲む（`**_a_b**`）。breakText は hardBreak の書き方。
    ///
    def renderInlines(breakText: String, inlines: List[Inline]): String =
        inlines |> groupAdjacent(headMark) |> List.map(renderGroup(breakText)) |> List.join("")

    def renderGroup(breakText: String, group: (Option[Mark], List[Inline])): String = match group {
        case (None, members)            => members |> List.map(renderPlain(breakText)) |> List.join("")
        case (Some(Mark.Code), members) => "`${members |> List.map(rawText) |> List.join("")}`"
        case (Some(Mark.Math), members) => "$${members |> List.map(rawText) |> List.join("")}$"
        case (Some(mark), members)      => "${openMark(mark)}${renderInlines(breakText, members |> List.map(dropHeadMark))}${closeMark(mark)}"
    }

    def renderPlain(breakText: String, inline: Inline): String = match inline {
        case Inline.Text(_, text) => escape(text)
        case Inline.HardBreak     => breakText
    }

    def rawText(inline: Inline): String = match inline {
        case Inline.Text(_, text) => text
        case Inline.HardBreak     => ""
    }

    def headMark(inline: Inline): Option[Mark] = match inline {
        case Inline.Text(mark :: _, _) => Some(mark)
        case _                         => None
    }

    def dropHeadMark(inline: Inline): Inline = match inline {
        case Inline.Text(_ :: rest, text) => Inline.Text(rest, text)
        case other                        => other
    }

    def openMark(mark: Mark): String = match mark {
        case Mark.Bold      => "**"
        case Mark.Italic    => "_"
        case Mark.Strike    => "~~"
        case Mark.Underline => "<u>"
        case Mark.Code      => "`"
        case Mark.Link(_)   => "["
        case Mark.Math      => "$"
        case Mark.Sub       => "~"
        case Mark.Sup       => "^"
        case Mark.Highlight => "=="
    }

    def closeMark(mark: Mark): String = match mark {
        case Mark.Bold                            => "**"
        case Mark.Italic                          => "_"
        case Mark.Strike                          => "~~"
        case Mark.Underline                       => "</u>"
        case Mark.Code                            => "`"
        case Mark.Link(LinkTarget.Href(href))     => "](${href})"
        case Mark.Link(LinkTarget.Entry(entryId)) => "](entry:${entryId})"
        case Mark.Math                            => "$"
        case Mark.Sub                             => "~"
        case Mark.Sup                             => "^"
        case Mark.Highlight                       => "=="
    }

    ///
    /// text の中で Markdown の記号になる文字（* _ [ ] ` \ # | < > ~ $ ^ =）を \ で逃がす。読む時に戻る。
    ///
    def escape(text: String): String =
        text |> String.toList |> List.map(c -> if (isMarkdownSpecial(c)) "\\${c}" else Char.toString(c)) |> List.join("")

    def isMarkdownSpecial(c: Char): Bool =
        c == '*' or c == '_' or c == '[' or c == ']' or c == '`' or c == '\\' or c == '#' or c == '|' or c == '<' or c == '>' or c == '~' or c == '$' or c == '^' or c == '='

    ///
    /// 段落の各行が箇条書き・番号・罫線・引用の出典に見えないようにする（`- a` → `\- a`、`1. a` → `1\. a`、`---` → `\---`、`— a` → `\— a`）。
    /// escape が逃がさない `-` `+` `—` と数字だけ。
    ///
    def guardLineStarts(text: String): String =
        text |> String.splitOn(substr = "\n") |> List.map(guardLineStart) |> List.join("\n")

    def guardLineStart(line: String): String =
        if (String.isMatch(regex = "^[-+](\\s.*)?$", line) or String.isMatch(regex = "^-{3,}\\s*$", line) or isCiteLine(line)) "\\${line}"
        else if (String.isMatch(regex = "^[0-9]{1,9}[.)](\\s.*)?$", line)) String.replaceFirstMatch(regex = "^([0-9]{1,9})([.)])", to = "$1\\\\$2", line)
        else if (String.isMatch(regex = "^https?://\\S+$", line)) String.replaceFirstMatch(regex = ":", to = "\\\\:", line)
        else line

    /// 隣り合う要素を key が同じ間だけまとめる。
    def groupAdjacent(key: a -> k, items: List[a]): List[(k, List[a])] with Eq[k] =
        List.foldLeft((groups, item) -> match groups {
            case (k, members) :: others if k == key(item) => (k, item :: members) :: others
            case _                                         => (key(item), item :: Nil) :: groups
        }, Nil, items)
            |> List.reverse
            |> List.map(match (k, members) -> (k, List.reverse(members)))

    // ---- Markdown → 木（ブロック）----

    /// 1 行の種類。
    enum LineKind {
        case Blank
        case Fence(String, CodeInfo)
        case MathFence
        case DetailsOpen(String)
        case DetailsClose
        case HeadingLine(Int32, String)
        case Rule
        case Quote(String)
        case Bullet(String)
        case Ordered(Int32, String)
        case Plain
    }

    def normalizeNewlines(text: String): String =
        text |> String.replace(src = "\r\n", dst = "\n") |> String.replace(src = "\r", dst = "\n")

    def parseBlocks(lines: List[String]): List[Block] = parseLoop(lines, Nil)

    def parseLoop(lines: List[String], acc: List[Block]): List[Block] = match lines {
        case Nil          => List.reverse(acc)
        case line :: rest =>
            let (block, remaining) = parseOne(lineKind(line), line, rest);
            parseLoop(remaining, (block |> Option.toList) ::: acc)
    }

    /// 先頭の 1 ブロックを読み、残りの行を返す。
    def parseOne(kind: LineKind, line: String, rest: List[String]): (Option[Block], List[String]) = match kind {
        case LineKind.Blank                    => (None, rest)
        case LineKind.Fence(fence, info)       => parseFence(fence, info, rest)
        case LineKind.MathFence                => parseMathFence(rest)
        case LineKind.DetailsOpen(summary)     => parseDetails(summary, rest)
        case LineKind.DetailsClose             => (None, rest)
        case LineKind.HeadingLine(level, text) => (Some(parseHeading(level, text)), rest)
        case LineKind.Rule                     => (Some(Block.HorizontalRule), rest)
        case LineKind.Quote(_)                 => parseQuote(line :: rest)
        case LineKind.Bullet(_)                => parseList(true, line :: rest)
        case LineKind.Ordered(_, _)            => parseList(false, line :: rest)
        case LineKind.Plain                    => if (isTableStart(line, rest)) parseTable(line :: rest) else parseParagraph(line :: rest)
    }

    def lineKind(line: String): LineKind =
        List#{ blankKind, fenceKind, mathFenceKind, detailsOpenKind, detailsCloseKind, headingKind, ruleKind, quoteKind, bulletKind, orderedKind }
            |> List.findMap(classify -> classify(line))
            |> Option.getWithDefault(LineKind.Plain)

    def blankKind(line: String): Option[LineKind] = if (isBlank(line)) Some(LineKind.Blank) else None

    /// ```` ```言語:ファイル名 {1,3-5 wrap} ````。CommonMark に合わせ `~~~` でも 4 個以上でも開ける。
    /// 言語・ファイル名・行は規則に合わなければ無い物にする。
    ///
    /// WhyNot: ` のフェンスでは後ろに ` が 1 つでもあれば開かない。
    /// ```` ```a`b ```` を開く物として読むと、閉じる行の判定が中身の ` と食い違う。
    def fenceKind(line: String): Option[LineKind] = match captures("^\\s{0,3}(`{3,}|~{3,})(.*)$", line) {
        case fence :: info :: Nil =>
            if (String.startsWith(prefix = "`", fence) and String.contains(substr = "`", info)) None
            else fenceInfo(info) |> Option.map(found -> LineKind.Fence(fence, found))
        case _ => None
    }

    /// フェンスの後ろ（`言語:ファイル名 {1,3-5 wrap}`）。形に合わない物は無い物にする。
    def fenceInfo(info: String): Option[CodeInfo] = match captures("^([^\\s:{]*)(?::([^\\s{]+))?\\s*(?:\\{([^}]*)\\})?\\s*$", info) {
        case language :: fileName :: options :: Nil =>
            let (highlightLines, wrap) = fenceOptions(options);
            Some(CodeInfo.CodeInfo(
                Some(language) |> Option.filter(RichText.isLanguage),
                Some(fileName) |> Option.filter(RichText.isFileName),
                highlightLines,
                wrap))
        case _ => None
    }

    /// `{…}` の中身。空白で区切り、`wrap` は折り返し、それ以外の先頭 1 つを強調する行として見る。
    def fenceOptions(options: String): (Option[String], Bool) =
        let tokens = options |> String.replaceMatches(regex = "\\s+", to = " ") |> String.trim |> String.splitOn(substr = " ") |> List.filter(String.nonEmpty);
        let highlightLines = tokens |> List.find(token -> token != wrapMarker()) |> Option.filter(RichText.isHighlightLines);
        (highlightLines, tokens |> List.memberOf(wrapMarker()))

    /// フェンスの `{…}` に書く折り返しの印。
    def wrapMarker(): String = "wrap"

    /// `$$` だけの行。
    def mathFenceKind(line: String): Option[LineKind] =
        if (String.isMatch(regex = "^\\s{0,3}\\$\\$\\s*$", line)) Some(LineKind.MathFence) else None

    /// `<details><summary>…</summary>`。summary が無いか空なら「詳細」。
    def detailsOpenKind(line: String): Option[LineKind] = match captures("^\\s{0,3}<details>\\s*(?:<summary>(.*?)</summary>)?\\s*$", line) {
        case summary :: Nil => Some(LineKind.DetailsOpen(Some(String.trim(summary)) |> Option.filter(String.nonEmpty) |> Option.getWithDefault(defaultSummary())))
        case _              => None
    }

    def detailsCloseKind(line: String): Option[LineKind] =
        if (String.isMatch(regex = "^\\s{0,3}</details>\\s*$", line)) Some(LineKind.DetailsClose) else None

    def headingKind(line: String): Option[LineKind] = match captures("^\\s{0,3}(#{1,6})(\\s+.*)?$", line) {
        case hashes :: text :: Nil => Some(LineKind.HeadingLine(String.length(hashes), text))
        case _                     => None
    }

    def ruleKind(line: String): Option[LineKind] =
        if (String.isMatch(regex = "^\\s{0,3}([-*_])(\\s*\\1){2,}\\s*$", line)) Some(LineKind.Rule) else None

    def quoteKind(line: String): Option[LineKind] = quoteInner(line) |> Option.map(LineKind.Quote)

    def bulletKind(line: String): Option[LineKind] = bulletRest(line) |> Option.map(LineKind.Bullet)

    def orderedKind(line: String): Option[LineKind] = orderedRest(line) |> Option.map(match (number, text) -> LineKind.Ordered(number, text))

    /// `> ` を外した中身。`>` だけの行は空。
    def quoteInner(line: String): Option[String] = match captures("^\\s{0,3}> ?(.*)$", line) {
        case inner :: Nil => Some(inner)
        case _            => None
    }

    /// `- ` `* ` `+ ` の後ろ。印だけの行は空。
    def bulletRest(line: String): Option[String] = match captures("^\\s{0,3}[-*+](\\s+.*)?$", line) {
        case _ if Option.nonEmpty(ruleKind(line)) => None
        case text :: Nil                          => Some(String.trimLeft(text))
        case _                                    => None
    }

    /// `1. ` `1) ` の番号と後ろ。
    def orderedRest(line: String): Option[(Int32, String)] = match captures("^\\s{0,3}([0-9]{1,9})[.)](\\s+.*)?$", line) {
        case number :: text :: Nil => Int32.fromString(number) |> Option.map(n -> (n, String.trimLeft(text)))
        case _                     => None
    }

    def isBlank(line: String): Bool = String.isEmpty(String.trim(line))

    /// 段落を途中で切る行（見出し・フェンス・罫線・引用・箇条書き・1 から始まる番号）。
    def interruptsParagraph(line: String): Bool = match lineKind(line) {
        case LineKind.Plain              => false
        case LineKind.Ordered(number, _) => number == 1
        case _                           => true
    }

    /// 開いたフェンスから閉じるフェンスまで。閉じなければ末尾まで。
    /// 閉じられるのは同じ記号で、開いた数以上の物だけ（CommonMark）。
    def parseFence(fence: String, info: CodeInfo, rest: List[String]): (Option[Block], List[String]) =
        let marker = String.takeLeft(1, fence);
        let length = String.length(fence);
        let closes = line -> String.isMatch(regex = "^\\s{0,3}${marker}{${length},}\\s*$", line);
        let (body, after) = List.span(line -> not closes(line), rest);
        (Some(Block.CodeBlock(info, List.join("\n", body))), List.drop(1, after))

    /// `$$` から閉じる `$$` まで。閉じなければ末尾まで。中身が空なら何も作らない（validate が空の TeX を通さないため）。
    def parseMathFence(rest: List[String]): (Option[Block], List[String]) =
        let (body, after) = List.span(line -> Option.isEmpty(mathFenceKind(line)), rest);
        (Some(List.join("\n", body)) |> Option.filter(tex -> String.nonEmpty(String.trim(tex))) |> Option.map(Block.MathBlock), List.drop(1, after))

    /// `<details>` の行から `</details>` の行まで。中身は普通のブロック。閉じなければ末尾まで。
    def parseDetails(summary: String, rest: List[String]): (Option[Block], List[String]) =
        let (body, after) = List.span(line -> Option.isEmpty(detailsCloseKind(line)), rest);
        (Some(Block.Details(summary, parseBlocks(body))), List.drop(1, after))

    /// `## 見出し {#id}`。閉じ側の # は落とす。5 段以上は 4 に丸める。
    def parseHeading(level: Int32, text: String): Block =
        let trimmed = text |> String.trim |> String.replaceMatches(regex = "\\s+#+\\s*$", to = "");
        match captures("^(.*?)\\s+\\{#([A-Za-z0-9_-]{1,64})\\}$", trimmed) {
            case body :: id :: Nil => Block.Heading(clampLevel(level), Some(id), parseInlines(body))
            case _                 => Block.Heading(clampLevel(level), None, parseInlines(trimmed))
        }

    /// `> ` の続く行。1 行目が `[!NOTE]` などなら callout。
    def parseQuote(lines: List[String]): (Option[Block], List[String]) =
        let (quoted, after) = List.span(line -> Option.nonEmpty(quoteInner(line)), lines);
        let inner = quoted |> List.filterMap(quoteInner);
        (Some(quoteBlock(inner)), after)

    def quoteBlock(inner: List[String]): Block = match inner {
        case first :: rest => match alertKind(first) {
            case Some(kind) => Block.Callout(kind, parseBlocks(rest))
            case None       =>
                let (body, cite) = splitCite(inner);
                Block.Blockquote(cite, flattenQuotes(parseBlocks(body)))
        }
        case Nil => Block.Blockquote(Nil, Nil)
    }

    /// 引用の中身の最後のブロックが `— ` で始まる段落なら、それを出典として切り出す。(残りの行, 出典の inline)。
    def splitCite(inner: List[String]): (List[String], List[Inline]) =
        let (tailReversed, bodyReversed) = List.span(line -> not isBlank(line), List.reverse(inner));
        let tail = List.reverse(tailReversed);
        match (tail, parseParagraph(tail)) {
            case (first :: _, (Some(Block.Paragraph(inlines)), Nil)) if isCiteLine(first) => (List.reverse(bodyReversed), citeOf(inlines))
            case _ => (inner, Nil)
        }

    /// `— ` で始まる行（`\—` は逃がした本文なので違う）。
    def isCiteLine(line: String): Bool = String.startsWith(prefix = "— ", line)

    /// `— ` を外した残りが出典の inline。hardBreak と出典に付けられないマークは落とす（doc が validate に通る形で返る）。
    def citeOf(inlines: List[Inline]): List[Inline] =
        let stripped = match inlines {
            case Inline.Text(marks, text) :: rest => Inline.Text(marks, String.stripPrefix(substr = "— ", text) |> Option.getWithDefault(text)) :: rest
            case other                            => other
        };
        stripped |> List.filter(inline -> not isEmptyText(inline)) |> keepCaptionMarks

    ///
    /// キャプションと出典に付けられないマークを落とし、hardBreak も落とす。
    ///
    /// WhyNot: 落とさずに違反にしない。fromMarkdown は「必ず RichText.validate に通る doc を返す」約束で、
    /// `— ==著者==` のような入力で保存できない doc を作ると、取り込みがそこで止まる。
    ///
    def keepCaptionMarks(inlines: List[Inline]): List[Inline] =
        inlines |> List.filterMap(inline -> match inline {
            case Inline.Text(marks, text) => Some(Inline.Text(marks |> List.filter(isCaptionMark), text))
            case Inline.HardBreak         => None
        })

    def isCaptionMark(mark: Mark): Bool = List.memberOf(markName(mark), RichText.captionMarkNames())

    def markName(mark: Mark): String = match mark {
        case Mark.Bold      => "bold"
        case Mark.Italic    => "italic"
        case Mark.Strike    => "strike"
        case Mark.Underline => "underline"
        case Mark.Code      => "code"
        case Mark.Link(_)   => "link"
        case Mark.Math      => "math"
        case Mark.Sub       => "sub"
        case Mark.Sup       => "sup"
        case Mark.Highlight => "highlight"
    }

    def isEmptyText(inline: Inline): Bool = match inline {
        case Inline.Text(_, "") => true
        case _                  => false
    }

    ///
    /// 引用の中の引用を 1 段に潰す。
    ///
    /// WhyNot: `> > 中` を入れ子のまま読まない。richText は入れ子の引用を持たないので、
    /// そのまま doc にすると validate で断られる（取り込んだ Markdown が保存できない）。
    ///
    def flattenQuotes(blocks: List[Block]): List[Block] =
        blocks |> List.flatMap(block -> match block {
            case Block.Blockquote(_, inner) => flattenQuotes(inner)
            case other                      => other :: Nil
        })

    def alertKind(line: String): Option[CalloutKind] = match captures("^\\s*\\[!([A-Za-z]+)\\]\\s*$", line) {
        case name :: Nil => calloutKindOf(name)
        case _           => None
    }

    /// 同じ種類の印が続く間の項目。項目の中身は印の後ろと、2 空白以上で始まる続きの行（空行を挟んでよい）。印の直後の `[ ]` / `[x]` はタスク。
    def parseList(isBullet: Bool, lines: List[String]): (Option[Block], List[String]) =
        let (items, after) = parseListItems(isBullet, lines, Nil);
        (Some(if (isBullet) Block.BulletList(items) else Block.OrderedList(items)), after)

    def parseListItems(isBullet: Bool, lines: List[String], acc: List[ListItem]): (List[ListItem], List[String]) = match lines {
        case line :: rest => match markerRest(isBullet, line) {
            case Some(first) =>
                let (continuation, after) = List.span(line2 -> isBlank(line2) or leadingSpaces(line2) >= 2, rest);
                let (checked, firstBody) = taskMarker(first);
                parseListItems(isBullet, after, ListItem.ListItem(checked, parseBlocks(firstBody :: dedent(continuation))) :: acc)
            case None => (List.reverse(acc), lines)
        }
        case Nil => (List.reverse(acc), Nil)
    }

    /// `[ ] 本文` / `[x] 本文` / `[X] 本文` なら (済みか, 本文)。後ろに何も無い `[ ]` はタスクにしない（文字のまま）。
    def taskMarker(first: String): (Option[Bool], String) = match captures("^\\[( |x|X)\\] +(\\S.*)$", first) {
        case box :: body :: Nil => (Some(box != " "), body)
        case _                  => (None, first)
    }

    def markerRest(isBullet: Bool, line: String): Option[String] =
        if (isBullet) bulletRest(line) else orderedRest(line) |> Option.map(snd)

    /// 続きの行の字下げを外す。幅は最初の空でない行の空白の数。
    def dedent(lines: List[String]): List[String] =
        let width = lines |> List.find(line -> not isBlank(line)) |> Option.map(leadingSpaces) |> Option.getWithDefault(0);
        lines |> List.map(line -> if (isBlank(line)) "" else String.drop(Int32.min(width, leadingSpaces(line)), line))

    def leadingSpaces(line: String): Int32 = line |> String.takeWhile(c -> c == ' ') |> String.length

    // ---- 表 ----

    def isTableStart(line: String, rest: List[String]): Bool =
        String.contains(substr = "|", line) and (rest |> List.head |> Option.exists(isTableSeparator))

    def isTableSeparator(line: String): Bool =
        String.isMatch(regex = "^\\s*\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?\\s*$", line) and String.contains(substr = "-", line)

    /// 1 行目が tableHeader、2 行目（区切り）は寄せを読んで捨て、`|` を含む行が続く間が表。
    /// **寄せは列の属性なので、その列の全セルに同じ値を入れる**（JSON にはセルごとに乗る）。
    def parseTable(lines: List[String]): (Option[Block], List[String]) =
        let (rowLines, after) = List.span(line -> not isBlank(line) and String.contains(substr = "|", line), lines);
        let rows = match rowLines {
            case header :: separator :: body =>
                let aligns = alignsOf(separator);
                cellsOf(true, aligns, header) :: (body |> List.map(line -> cellsOf(false, aligns, line)))
            case header :: Nil => cellsOf(true, Nil, header) :: Nil
            case Nil           => Nil
        };
        (Some(Block.Table(rows)), after)

    def cellsOf(isHeader: Bool, aligns: List[Option[String]], line: String): List[Cell] =
        splitCells(line) |> List.zipWithIndex
            |> List.map(match (index, text) -> Cell.Cell(isHeader, List.nth(index, aligns) |> Option.flatten, cellBlocks(text)))

    /// 区切り行から列ごとの寄せ。`:---` 左、`:---:` 中央、`---:` 右、`---` 指定なし。
    def alignsOf(separator: String): List[Option[String]] =
        splitCells(separator) |> List.map(mark -> {
            let left = String.startsWith(prefix = ":", mark);
            let right = String.endsWith(suffix = ":", mark);
            match (left, right) {
                case (true, true)  => Some("center")
                case (true, false) => Some("left")
                case (false, true) => Some("right")
                case _             => None
            }
        })

    def cellBlocks(text: String): List[Block] = Block.Paragraph(parseInlines(text)) :: Nil

    /// 行を `|` で割る。`\|` は割らない（inline がセルの文字に戻す）。両端の `|` は捨てる。
    def splitCells(line: String): List[String] =
        let trimmed = line |> String.trim |> String.stripPrefix(substr = "|") |> Option.getWithDefault(String.trim(line));
        let (cells, current) = trimmed |> String.toList |> List.foldLeft(splitCellStep, (Nil, Nil));
        (charsToString(List.reverse(current)) :: cells) |> List.reverse |> List.map(String.trim) |> dropTrailingEmptyCell

    /// (できたセル（逆順）, 今のセルの文字（逆順）)。`\` の次の文字はそのまま積む。
    def splitCellStep(state: (List[String], List[Char]), c: Char): (List[String], List[Char]) = match state {
        case (cells, '\\' :: current) => (cells, c :: '\\' :: current)
        case (cells, current) if c == '|' => (charsToString(List.reverse(current)) :: cells, Nil)
        case (cells, current)             => (cells, c :: current)
    }

    def dropTrailingEmptyCell(cells: List[String]): List[String] = match List.reverse(cells) {
        case "" :: rest => List.reverse(rest)
        case _          => cells
    }

    // ---- 段落 ----

    /// 空行か段落を切る行まで。image だけなら image / gallery、URL だけなら embed / linkCard。
    def parseParagraph(lines: List[String]): (Option[Block], List[String]) = match lines {
        case first :: rest =>
            let (continuation, after) = List.span(line -> not interruptsParagraph(line), rest);
            let text = (first :: continuation) |> List.map(String.trimLeft) |> List.join("\n") |> String.trimRight;
            (Some(paragraphBlock(text)), after)
        case Nil => (None, Nil)
    }

    def paragraphBlock(text: String): Block =
        List#{ picturesBlock, clipBlock, urlBlock } |> List.findMap(parse -> parse(text)) |> Option.getWithDefault(Block.Paragraph(parseInlines(text)))

    ///
    /// image だけの段落。1 つでも空白区切りで 2 つ以上でも image の塊（行末の古い `{columns=N}` は読んで捨てる）。
    /// 2 行目があれば、`*` で始まり `*` で終わる時だけキャプション（複数枚は画像の枚数だけ `*…*` を空白で並べる）。
    /// 文字が混ざる・3 行目がある・2 行目がキャプションの形でない、なら None。
    ///
    def picturesBlock(text: String): Option[Block] =
        let (firstLine, captionLines) = match String.splitOn(substr = "\n", text) {
            case first :: rest => (first, rest)
            case Nil           => ("", Nil)
        };
        let (pictures, rest) = takePictures(firstLine, Nil);
        match (pictures, columnsSuffix(rest)) {
            case (_ :: _, Some(_)) => captionsFor(pictures, captionLines)
            case _                 => None
        }

    ///
    /// 画像の行に続くキャプションの行を画像に配る。1 枚なら行全体が `*…*` でその画像のキャプション、
    /// 2 枚以上なら `*…*` を空白で並べた物を画像の順に（枚数より少なければ前から詰める）。行は 1 行まで。
    ///
    def captionsFor(pictures: List[Picture], captionLines: List[String]): Option[Block] =
        let each = captions -> List.zipWith(withCaption, captions ::: List.repeat(List.length(pictures), Nil), pictures);
        match (pictures, captionLines) {
            case (_, Nil)                  => picturesBlockOf(pictures)
            case (_ :: Nil, line :: Nil)   => wholeCaption(line) |> Option.flatMap(caption -> picturesBlockOf(each(caption :: Nil)))
            case (_, line :: Nil)          => captionTokens(line) |> Option.flatMap(captions -> picturesBlockOf(each(captions)))
            case _                         => None
        }

    /// 行全体が `*…*` ならその中身の inline。他は None。
    def wholeCaption(line: String): Option[List[Inline]] = match captures("^\\*([\\s\\S]*)\\*$", String.trim(line)) {
        case inner :: Nil => Some(parseInlines(inner) |> keepCaptionMarks)
        case _            => None
    }

    ///
    /// gallery のキャプションの行。`*…*` を空白で区切って並べた物を、画像の順に読む。1 つでも形が違えば None。
    /// 閉じの `*` は「その後ろが空白 + `*` か行末」の物（`***太字***` の中の `*` で切らない）。`\` の次の文字は見ない。
    ///
    def captionTokens(line: String): Option[List[List[Inline]]] = captionTokenLoop(String.trim(line), Nil)

    def captionTokenLoop(text: String, acc: List[List[Inline]]): Option[List[List[Inline]]] =
        if (String.isEmpty(text)) Some(List.reverse(acc))
        else if (not String.startsWith(prefix = "*", text)) None
        else match captionCloser(text, 1) {
            case Some(end) => captionTokenLoop(String.trimLeft(String.sliceRight(start = end + 1, text)), (parseInlines(String.slice(start = 1, end = end, text)) |> keepCaptionMarks) :: acc)
            case None      => None
        }

    /// pos から見て、`*` の後ろが行末か「空白 + `*`」の位置。
    def captionCloser(text: String, pos: Int32): Option[Int32] =
        if (pos >= String.length(text)) None
        else match String.charAt(pos, text) {
            case '\\' => captionCloser(text, pos + 2)
            case '*'  =>
                let after = String.sliceRight(start = pos + 1, text);
                if (String.isEmpty(after) or String.isMatch(regex = "^\\s+\\*[\\s\\S]*$", after)) Some(pos) else captionCloser(text, pos + 1)
            case _    => captionCloser(text, pos + 1)
        }

    def withCaption(caption: List[Inline], picture: Picture): Picture =
        let Picture.Picture(assetId, alt, _, dimensions, attribution, placement) = picture;
        Picture.Picture(assetId, alt, caption, dimensions, attribution, placement)

    /// 先頭から image を読めるだけ読む。(image の列, 残り)。image と image の間は空白。
    def takePictures(text: String, acc: List[Picture]): (List[Picture], String) = match takeAnyPicture(text) {
        case Some((picture, rest)) =>
            if (String.isMatch(regex = "^\\s+(?:!\\[|\\[!\\[)[\\s\\S]*$", rest)) takePictures(String.trimLeft(rest), picture :: acc)
            else (List.reverse(picture :: acc), rest)
        case None => (List.reverse(acc), text)
    }

    /// `[` で始まればリンク付きの image、他は素の image。
    def takeAnyPicture(text: String): Option[(Picture, String)] =
        if (String.startsWith(prefix = "[", text)) takeLinkedPicture(text) else takePicture(text)

    /// `[![alt](asset:ID "caption"){…}](https://…)` を 1 つ。リンク先は http(s) だけ（他は image にならず段落の文字）。(image, 残りの文字)。
    def takeLinkedPicture(text: String): Option[(Picture, String)] =
        takePicture(String.drop(1, text)) |> Option.flatMap(match (picture, rest) ->
            match captures("^\\]\\((https?://[^\\s)]+)\\)([\\s\\S]*)$", rest) {
                case href :: after :: Nil => Some((withHref(href, picture), after))
                case _                    => None
            })

    def withHref(href: String, picture: Picture): Picture =
        let Picture.Picture(assetId, alt, caption, dimensions, attribution, Placement.Placement(_, size, align)) = picture;
        Picture.Picture(assetId, alt, caption, dimensions, attribution, Placement.Placement(Some(href), size, align))

    /// 画像の行の残りが空か、古い `{columns=N}` だけなら Some（列数は枚数から決まるので読んで捨てる）。他は None。
    def columnsSuffix(rest: String): Option[Unit] =
        if (String.isMatch(regex = "^\\s*(?:\\{columns=[0-9]{1,9}\\})?\\s*$", rest)) Some(()) else None

    ///
    /// `![alt](asset:ID "caption"){key=value …}` を 1 つ。[] が alt。title は古い形の caption で、読む時だけ受ける（次の行の `*…*` があればそちらが勝つ）。
    /// `{...}` は key=value の並びで、知らない key は捨てる。width と height は両方あって数字の時だけ寸法になる。size / align は決まった値の時だけ。
    /// (image, 残りの文字)。
    ///
    def takePicture(text: String): Option[(Picture, String)] =
        match captures("^!\\[((?:[^\\]\\\\]|\\\\.)*)\\]\\(asset:([A-Za-z0-9_-]{1,64})(?: \"((?:[^\"\\\\]|\\\\.)*)\")?\\)(?:\\{((?:[^}\"]|\"(?:[^\"\\\\]|\\\\.)*\")*)\\})?([\\s\\S]*)$", text) {
            case bracket :: assetId :: title :: pairsText :: rest :: Nil =>
                parseKeyValues(pairsText) |> Option.map(pairs -> {
                    let value = key -> List.findMap(match (k, v) -> if (k == key) Some(v) else None, pairs);
                    let dimensions = value("width") |> Option.flatMap(Int32.fromString) |> Option.flatMap(w -> value("height") |> Option.flatMap(Int32.fromString) |> Option.map(h -> (w, h)));
                    let attribution = Attribution.Attribution(value("source") |> Option.filter(String.nonEmpty), value("sourceUrl") |> Option.filter(String.nonEmpty));
                    let placement = Placement.Placement(None, value("size") |> Option.flatMap(imageSizeOf), value("align") |> Option.flatMap(imageAlignOf));
                    (Picture.Picture(assetId, Some(unescape(bracket)) |> Option.filter(String.nonEmpty), Some(unescape(title)) |> Option.filter(String.nonEmpty) |> Option.map(found -> Inline.Text(Nil, found)) |> Option.toList, dimensions, attribution, placement), rest)
                })
            case _ => None
        }

    /// `key=value key="v alue"` の並び。値の `"…"` は外して `\"` を戻す。並びとして読めない文字が残れば None。
    def parseKeyValues(text: String): Option[List[(String, String)]] = keyValueLoop(text, Nil)

    def keyValueLoop(text: String, acc: List[(String, String)]): Option[List[(String, String)]] =
        if (isBlank(text)) Some(List.reverse(acc))
        else match captures("^\\s*([A-Za-z][A-Za-z0-9]*)=(?:\"((?:[^\"\\\\]|\\\\.)*)\"|([^\\s\"}]*))([\\s\\S]*)$", text) {
            case key :: quoted :: bare :: rest :: Nil =>
                keyValueLoop(rest, (key, if (String.isEmpty(quoted)) bare else unescape(quoted)) :: acc)
            case _ => None
        }

    /// `@[video](asset:ID "caption"){poster=asset:ID}` だけの段落。
    def clipBlock(text: String): Option[Block] =
        match captures("^@\\[video\\]\\(asset:([A-Za-z0-9_-]{1,64})( \"((?:[^\"\\\\]|\\\\.)*)\")?\\)(?:\\{poster=asset:([A-Za-z0-9_-]{1,64})\\})?$", text) {
            case assetId :: _ :: title :: poster :: Nil =>
                Some(Block.Video(Clip.Clip(assetId, Some(unescape(title)) |> Option.filter(String.nonEmpty), Some(poster) |> Option.filter(String.nonEmpty))))
            case _ => None
        }

    /// URL だけの段落。提供元が判れば embed、他は linkCard。
    def urlBlock(text: String): Option[Block] =
        if (String.isMatch(regex = "^https?://\\S+$", text))
            Some(if (Option.nonEmpty(RichText.embedOf(text))) Block.Embed(text) else Block.LinkCard(text))
        else None

    // ---- Markdown → 木（inline）----

    /// 1 歩の結果。Literal は 1 文字を text に積む、Break は hardBreak、Nested は入れ子の解析結果。Int32 は次に読む位置。
    enum Step {
        case Literal(Char, Int32)
        case Break(Int32)
        case Nested(List[Inline], Int32)
    }

    def parseInlines(text: String): List[Inline] = scanInlines(Nil, text)

    /// marks は今かかっているマーク（外側が先頭）。
    def scanInlines(marks: List[Mark], text: String): List[Inline] = scan(marks, text, 0, Nil, Nil)

    /// pending は今の text の文字（逆順）、acc はできた inline（逆順）。
    def scan(marks: List[Mark], text: String, pos: Int32, pending: List[Char], acc: List[Inline]): List[Inline] =
        if (pos >= String.length(text)) flush(marks, pending, acc) |> List.reverse
        else match step(marks, text, pos) {
            case Step.Literal(c, next)       => scan(marks, text, next, c :: pending, acc)
            case Step.Break(next)            => scan(marks, text, next, Nil, Inline.HardBreak :: flush(marks, pending, acc))
            case Step.Nested(inlines, next)  => scan(marks, text, next, Nil, List.reverse(inlines) ::: flush(marks, pending, acc))
        }

    def flush(marks: List[Mark], pending: List[Char], acc: List[Inline]): List[Inline] =
        if (List.isEmpty(pending)) acc else Inline.Text(marks, charsToString(List.reverse(pending))) :: acc

    def step(marks: List[Mark], text: String, pos: Int32): Step = match String.charAt(pos, text) {
        case '\\' => backslashStep(text, pos)
        case '`'  => codeStep(marks, text, pos)
        case '$'  => mathStep(marks, text, pos)
        case '<'  => angleStep(marks, text, pos)
        case '!'  => bangStep(marks, text, pos)
        case '['  => linkStep(marks, text, pos)
        case ' '  => spaceStep(text, pos)
        case '*'  => delimiterStep(marks, text, pos)
        case '_'  => delimiterStep(marks, text, pos)
        case '~'  => delimiterStep(marks, text, pos)
        case '^'  => delimiterStep(marks, text, pos)
        case '='  => delimiterStep(marks, text, pos)
        case c    => Step.Literal(c, pos + 1)
    }

    /// `\` + 改行は hardBreak、`\` + 記号（ASCII と `—`）はその記号、他は `\` のまま。
    def backslashStep(text: String, pos: Int32): Step = match String.nth(pos + 1, text) {
        case Some('\n')                                          => Step.Break(pos + 2)
        case Some(next) if isAsciiPunct(next) or next == '—'     => Step.Literal(next, pos + 2)
        case _                                                   => Step.Literal('\\', pos + 1)
    }

    def isAsciiPunct(c: Char): Bool = Char.isAscii(c) and not Char.isLetterOrDigit(c) and not Char.isWhitespace(c)

    /// `` `code` ``。中は解釈しない。閉じなければ `` ` `` の文字。
    def codeStep(marks: List[Mark], text: String, pos: Int32): Step =
        match String.indexOfLeftWithOffset(substr = "`", offset = pos + 1, text) |> Option.filter(end -> end > pos + 1) {
            case Some(end) => Step.Nested(Inline.Text(marks ::: (Mark.Code :: Nil), String.slice(start = pos + 1, end = end, text)) :: Nil, end + 1)
            case None      => Step.Literal('`', pos + 1)
        }

    /// `$tex$`。中は解釈しない。閉じが無い（`\$` は閉じでない）か中身が空なら `$` の文字。
    def mathStep(marks: List[Mark], text: String, pos: Int32): Step =
        match findMathCloser(text, pos + 1) |> Option.filter(end -> end > pos + 1) {
            case Some(end) => Step.Nested(Inline.Text(marks ::: (Mark.Math :: Nil), String.slice(start = pos + 1, end = end, text)) :: Nil, end + 1)
            case None      => Step.Literal('$', pos + 1)
        }

    /// `\` の付かない次の `$` の位置。
    def findMathCloser(text: String, offset: Int32): Option[Int32] =
        String.indexOfLeftWithOffset(substr = "$", offset = offset, text) |> Option.flatMap(index ->
            if (String.nth(index - 1, text) == Some('\\')) findMathCloser(text, index + 1) else Some(index))

    /// `<u>…</u>` と `<br>`。
    def angleStep(marks: List[Mark], text: String, pos: Int32): Step =
        if (hasAt("<br>", pos, text)) Step.Break(pos + 4)
        else if (hasAt("<u>", pos, text))
            match String.indexOfLeftWithOffset(substr = "</u>", offset = pos + 3, text) {
                case Some(end) => Step.Nested(scanInlines(marks ::: (Mark.Underline :: Nil), String.slice(start = pos + 3, end = end, text)), end + 4)
                case None      => Step.Literal('<', pos + 1)
            }
        else Step.Literal('<', pos + 1)

    /// `[text](target)`。閉じないか target に空白があれば `[` の文字。`![` は image の書き方なので link にしない（bangStep が見る）。
    def linkStep(marks: List[Mark], text: String, pos: Int32): Step =
        match (if (String.nth(pos - 1, text) == Some('!')) None else findLink(text, pos)) {
            case Some((labelEnd, targetEnd)) => linkNested(marks, text, pos, labelEnd, targetEnd)
            case None                        => Step.Literal('[', pos + 1)
        }

    /// `![alt](URL)`。asset 管理外の画像は image にせず、alt を URL へのリンクにする。`![alt](asset:ID)` が文の途中にある時は `!` の文字のまま。
    def bangStep(marks: List[Mark], text: String, pos: Int32): Step =
        match (if (String.nth(pos + 1, text) == Some('[')) findLink(text, pos + 1) else None) {
            case Some((labelEnd, targetEnd)) if not String.startsWith(prefix = "asset:", String.slice(start = labelEnd + 2, end = targetEnd, text)) =>
                linkNested(marks, text, pos + 1, labelEnd, targetEnd)
            case _ => Step.Literal('!', pos + 1)
        }

    ///
    /// pos の `[` から `](target)` の形を探す。(`](` の位置, 閉じる `)` の位置)。閉じないか target に空白があれば None。
    ///
    /// WhyNot: 最初の `](` で label を切らない。`[![alt](asset:ID)](URL)` を内側の `](` で切ると
    /// `asset:ID` への link になり、fromMarkdown の「validate に通る doc を返す」約束が破れる。
    ///
    def findLink(text: String, pos: Int32): Option[(Int32, Int32)] =
        closingBracket(text, pos + 1)
            |> Option.filter(labelEnd -> String.nth(labelEnd + 1, text) == Some('('))
            |> Option.flatMap(labelEnd -> closingParen(text, labelEnd + 2) |> Option.map(targetEnd -> (labelEnd, targetEnd)))
            |> Option.filter(match (labelEnd, targetEnd) -> not String.exists(Char.isWhitespace, String.slice(start = labelEnd + 2, end = targetEnd, text)))

    /// 角括弧の対応を数えて閉じる `]` の位置。`\` の次の文字は数えない。
    def closingBracket(text: String, start: Int32): Option[Int32] =
        List.range(start, String.length(text))
            |> List.foldLeft((state, index) -> match state {
                case (Some(found), depth, _)                                          => (Some(found), depth, false)
                case (None, depth, true)                                              => (None, depth, false)
                case (None, depth, false) if String.charAt(index, text) == '\\'       => (None, depth, true)
                case (None, depth, false) if String.charAt(index, text) == '['        => (None, depth + 1, false)
                case (None, 0, false) if String.charAt(index, text) == ']'            => (Some(index), 0, false)
                case (None, depth, false) if String.charAt(index, text) == ']'        => (None, depth - 1, false)
                case other                                                            => other
            }, (None, 0, false))
            |> match (found, _, _) -> found

    ///
    /// link の中身を link マーク付きで解析した 1 歩。pos は `[` の位置。
    ///
    /// WhyNot: RichText.isSafeHref を通らない href（`javascript:` など）で link マークを作らない。
    /// fromMarkdown は「必ず RichText.validate に通る doc を返す」約束で、作ると取り込みがそこで止まる。
    ///
    def linkNested(marks: List[Mark], text: String, pos: Int32, labelEnd: Int32, targetEnd: Int32): Step =
        let target = linkTarget(String.slice(start = labelEnd + 2, end = targetEnd, text));
        let linked = if (isValidTarget(target)) marks ::: (Mark.Link(target) :: Nil) else marks;
        Step.Nested(scanInlines(linked, String.slice(start = pos + 1, end = labelEnd, text)), targetEnd + 1)

    def isValidTarget(target: LinkTarget): Bool = match target {
        case LinkTarget.Href(href) => RichText.isSafeHref(href)
        case LinkTarget.Entry(_)   => true
    }

    /// 括弧の対応を数えて閉じる `)` の位置。
    def closingParen(text: String, start: Int32): Option[Int32] =
        List.range(start, String.length(text))
            |> List.foldLeft((state, index) -> match state {
                case (Some(found), depth)          => (Some(found), depth)
                case (None, depth) if String.charAt(index, text) == '(' => (None, depth + 1)
                case (None, 0) if String.charAt(index, text) == ')'     => (Some(index), 0)
                case (None, depth) if String.charAt(index, text) == ')' => (None, depth - 1)
                case other                          => other
            }, (None, 0))
            |> fst

    def linkTarget(target: String): LinkTarget =
        String.stripPrefix(substr = "entry:", target) |> Option.flatMap(EntryId.parse) |> Option.map(id -> LinkTarget.Entry(EntryId.text(id))) |> Option.getWithDefault(LinkTarget.Href(target))

    /// 行末の 2 空白以上 + 改行は hardBreak。
    def spaceStep(text: String, pos: Int32): Step =
        let spaces = String.sliceRight(start = pos, text) |> String.takeWhile(c -> c == ' ') |> String.length;
        if (spaces >= 2 and String.nth(pos + spaces, text) == Some('\n')) Step.Break(pos + spaces + 1) else Step.Literal(' ', pos + 1)

    /// `**` `__` `~~` `==` `*` `_` `~` `^`。閉じが無ければ文字。`_` は単語の途中では開かない。
    /// **長い記号から見る**（`~~` を `~` 2 つと読まない）。
    def delimiterStep(marks: List[Mark], text: String, pos: Int32): Step =
        List#{ ("**", Mark.Bold), ("__", Mark.Bold), ("~~", Mark.Strike), ("==", Mark.Highlight),
               ("*", Mark.Italic), ("_", Mark.Italic), ("~", Mark.Sub), ("^", Mark.Sup) }
            |> List.findMap(match (delimiter, mark) -> delimited(marks, text, pos, delimiter, mark))
            |> Option.getWithDefault(Step.Literal(String.charAt(pos, text), pos + 1))

    def delimited(marks: List[Mark], text: String, pos: Int32, delimiter: String, mark: Mark): Option[Step] =
        let width = String.length(delimiter);
        let intraword = String.startsWith(prefix = "_", delimiter) and (String.nth(pos - 1, text) |> Option.exists(Char.isLetterOrDigit));
        if (not hasAt(delimiter, pos, text) or intraword) None
        else findCloser(delimiter, text, pos + width)
            |> Option.filter(end -> end > pos + width)
            |> Option.map(end -> Step.Nested(scanInlines(addMark(marks, mark), String.slice(start = pos + width, end = end, text)), end + width))

    ///
    /// 印を 1 つ足す。
    ///
    /// WhyNot: 上付きと下付きを重ねない。richText が持てない形（`~^a^~`）になり、
    /// 取り込んだ Markdown が保存できない。内側に書いた方（後に足す方）が勝つ。
    ///
    def addMark(marks: List[Mark], mark: Mark): List[Mark] =
        let raised = mark == Mark.Sub or mark == Mark.Sup;
        let kept = if (raised) marks |> List.filter(found -> found != Mark.Sub and found != Mark.Sup) else marks;
        kept ::: (mark :: Nil)

    /// 閉じの位置。1 文字の記号（* _）は、同じ記号が並んだ所（`**` の一部）を飛ばして探す。
    def findCloser(delimiter: String, text: String, offset: Int32): Option[Int32] =
        String.indexOfLeftWithOffset(substr = delimiter, offset = offset, text) |> Option.flatMap(index -> {
            let runLength = String.sliceRight(start = index, text) |> String.takeWhile(c -> Char.toString(c) == delimiter) |> String.length;
            if (String.length(delimiter) == 1 and runLength >= 2) findCloser(delimiter, text, index + runLength) else Some(index)
        })

    def hasAt(needle: String, pos: Int32, text: String): Bool =
        String.slice(start = pos, end = pos + String.length(needle), text) == needle

    /// `\` + 記号を記号に戻す（caption 用。マークは解釈しない）。
    def unescape(text: String): String = String.replaceMatches(regex = "\\\\([!-/:-@\\[-`{-~])", to = "$1", text)

    def charsToString(chars: List[Char]): String = region rc {
        let sb = StringBuilder.empty(rc);
        List.forEach(c -> StringBuilder.append(c, sb), chars);
        StringBuilder.toString(sb)
    }

    def captures(pattern: String, text: String): List[String] =
        String.toRegex(pattern) |> Result.map(rgx -> Regex.capture(rgx, text)) |> Result.getWithDefault(Nil)

    // ---- JSON の読み方 ----

    def objectFields(json: Json): Option[Map[String, Json]] = match json {
        case Json.JObject(fields) => Some(fields)
        case _                    => None
    }

    def typeOf(fields: Map[String, Json]): Option[String] =
        Map.get("type", fields) |> Option.flatMap(EntryValue.asString)

    def children(fields: Map[String, Json]): List[Json] = match Map.get("content", fields) {
        case Some(Json.JArray(items)) => Vector.toList(items)
        case _                        => Nil
    }

    def childrenText(fields: Map[String, Json]): String =
        children(fields) |> List.filterMap(objectFields) |> List.filterMap(child -> Map.get("text", child) |> Option.flatMap(EntryValue.asString)) |> List.join("")

    def marksOf(fields: Map[String, Json]): List[Map[String, Json]] = match Map.get("marks", fields) {
        case Some(Json.JArray(items)) => items |> Vector.toList |> List.filterMap(objectFields)
        case _                        => Nil
    }

    def attrs(fields: Map[String, Json]): Map[String, Json] = match Map.get("attrs", fields) {
        case Some(Json.JObject(found)) => found
        case _                         => Map.empty()
    }

    def attrString(name: String, fields: Map[String, Json]): Option[String] =
        Map.get(name, attrs(fields)) |> Option.flatMap(EntryValue.asString)

    def attrInt(name: String, fields: Map[String, Json]): Option[Int32] =
        Map.get(name, attrs(fields)) |> Option.flatMap(EntryValue.asInt32)

    def attrBool(name: String, fields: Map[String, Json]): Option[Bool] =
        Map.get(name, attrs(fields)) |> Option.flatMap(EntryValue.asBool)

}
