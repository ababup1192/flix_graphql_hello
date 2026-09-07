///
/// richText の doc（ProseMirror 形式。RichText が正）と Markdown の双方向変換。全部純粋。
///
/// 方言は GFM + 決め事: 見出しの id は `## 見出し {#id}`、callout は GitHub alerts（`> [!NOTE]`）、image は `![alt](asset:ID "caption"){width=W height=H}`、
/// gallery は 1 行に image を空白区切りで 2 つ以上（枚数と違う columns は行末に `{columns=N}`）、embed と linkCard は URL だけの段落（提供元が判れば embed）、
/// codeBlock は ```` ```言語:ファイル名 {1,3-5} ````、details は `<details><summary>…</summary>` から `</details>` の行まで、
/// entry へのリンクは `[text](entry:ID)`、underline は `<u>…</u>`。入れ子は 2 空白、番号は 1 から振り直す。
/// 数式は `$…$`（math マーク。TeX はそのまま）と `$$` の行で囲む mathBlock、text の `$` は `\$`。タスクリストは `- [ ]` `- [x]`（orderedList でも `1. [ ]`）。
/// video は `@[video](asset:ID "caption"){poster=asset:ID}`。Mermaid は language が mermaid の codeBlock で、Markdown では普通のフェンス。
/// 読む時は少し広く受け（`*` の箇条書き、`1)`、`***`、`__` と `*`、行末 2 空白、`![caption](asset:ID)`、summary の無い `<details>`、`- [X]`）、
/// 読めない物は段落の text に落として必ず RichText.validate に通る doc を返す。
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
        case Blockquote(List[Block])
        case CodeBlock(CodeInfo, String)
        case Table(List[List[Cell]])
        case Callout(CalloutKind, List[Block])
        case HorizontalRule
        case Image(Picture)
        case Gallery(Int32, List[Picture])
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

    /// codeBlock のフェンスに書く物。(言語, ファイル名, 強調する行)。
    enum CodeInfo {
        case CodeInfo(Option[String], Option[String], Option[String])
    }

    /// image 1 つ。(asset の id, alt, caption, (幅, 高さ))。gallery の中でも同じ。
    enum Picture {
        case Picture(String, Option[String], Option[String], Option[(Int32, Int32)])
    }

    /// summary の無い details に入れる summary。
    def defaultSummary(): String = "詳細"

    /// 表のセル。(tableHeader か, 中身)。
    enum Cell {
        case Cell(Bool, List[Block])
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
        case Some("blockquote")     => Some(Block.Blockquote(blocksOf(children(fields))))
        case Some("codeBlock")      => Some(Block.CodeBlock(CodeInfo.CodeInfo(attrString("language", fields), attrString("fileName", fields), attrString("highlightLines", fields)), childrenText(fields)))
        case Some("table")          => Some(Block.Table(children(fields) |> List.filterMap(rowOf)))
        case Some("callout")        => attrString("kind", fields) |> Option.flatMap(calloutKindOf) |> Option.map(kind -> Block.Callout(kind, blocksOf(children(fields))))
        case Some("horizontalRule") => Some(Block.HorizontalRule)
        case Some("image")          => pictureOf(fields) |> Option.map(Block.Image)
        case Some("gallery")        => Some(Block.Gallery(attrInt("columns", fields) |> Option.getWithDefault(RichText.minGalleryColumns()) |> clampColumns, children(fields) |> List.filterMap(objectFields) |> List.filterMap(pictureOf)))
        case Some("embed")          => attrString("url", fields) |> Option.map(Block.Embed)
        case Some("linkCard")       => attrString("url", fields) |> Option.map(Block.LinkCard)
        case Some("details")        => Some(Block.Details(attrString("summary", fields) |> Option.filter(String.nonEmpty) |> Option.getWithDefault(defaultSummary()), blocksOf(children(fields))))
        case Some("mathBlock")      => attrString("tex", fields) |> Option.map(Block.MathBlock)
        case Some("video")          => attrString("assetId", fields) |> Option.map(assetId -> Block.Video(Clip.Clip(assetId, attrString("caption", fields) |> Option.filter(String.nonEmpty), attrString("poster", fields))))
        case _                      => None
    })

    def pictureOf(fields: Map[String, Json]): Option[Picture] =
        attrString("assetId", fields) |> Option.map(assetId -> Picture.Picture(assetId, attrString("alt", fields) |> Option.filter(String.nonEmpty), attrString("caption", fields) |> Option.filter(String.nonEmpty), imageSizeOf(fields)))

    def imageSizeOf(fields: Map[String, Json]): Option[(Int32, Int32)] =
        attrInt("width", fields) |> Option.flatMap(width -> attrInt("height", fields) |> Option.map(height -> (width, height)))

    def listItemsOf(fields: Map[String, Json]): List[ListItem] =
        children(fields) |> List.filterMap(objectFields) |> List.filter(item -> typeOf(item) == Some("listItem"))
            |> List.map(item -> ListItem.ListItem(Map.get("checked", attrs(item)) |> Option.flatMap(EntryValue.asBool), blocksOf(children(item))))

    def rowOf(node: Json): Option[List[Cell]] =
        objectFields(node) |> Option.filter(fields -> typeOf(fields) == Some("tableRow")) |> Option.map(fields -> children(fields) |> List.filterMap(cellOf))

    def cellOf(node: Json): Option[Cell] = objectFields(node) |> Option.flatMap(fields -> match typeOf(fields) {
        case Some("tableHeader") => Some(Cell.Cell(true, blocksOf(children(fields))))
        case Some("tableCell")   => Some(Cell.Cell(false, blocksOf(children(fields))))
        case _                   => None
    })

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

    def clampColumns(columns: Int32): Int32 = Int32.max(RichText.minGalleryColumns(), Int32.min(columns, RichText.maxGalleryColumns()))

    /// {columns=N} を書かない時の columns。枚数を 4 で丸めた物。
    def defaultColumns(pictures: List[Picture]): Int32 = clampColumns(List.length(pictures))

    // ---- 木 → doc（JSON）----

    def blockJson(block: Block): Json = match block {
        case Block.Paragraph(inlines)              => objectNode("paragraph", Nil, inlines |> List.map(inlineJson))
        case Block.Heading(level, id, inlines)     => objectNode("heading", ("level", intJson(level)) :: (id |> Option.map(found -> ("id", Json.JString(found))) |> Option.toList), inlines |> List.map(inlineJson))
        case Block.BulletList(items)               => objectNode("bulletList", Nil, items |> List.map(listItemJson))
        case Block.OrderedList(items)              => objectNode("orderedList", Nil, items |> List.map(listItemJson))
        case Block.Blockquote(blocks)              => objectNode("blockquote", Nil, blocks |> List.map(blockJson))
        case Block.CodeBlock(info, code)           => objectNode("codeBlock", codeInfoAttrs(info), textNode(Nil, code) :: Nil)
        case Block.Table(rows)                     => objectNode("table", Nil, rows |> List.map(cells -> objectNode("tableRow", Nil, cells |> List.map(cellJson))))
        case Block.Callout(kind, blocks)           => objectNode("callout", ("kind", Json.JString(String.toLowerCase(calloutLabel(kind)))) :: Nil, blocks |> List.map(blockJson))
        case Block.HorizontalRule                  => leafNode("horizontalRule", Nil)
        case Block.Image(picture)                  => pictureJson(picture)
        case Block.Gallery(columns, pictures)      => objectNode("gallery", ("columns", intJson(columns)) :: Nil, pictures |> List.map(pictureJson))
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

    def codeInfoAttrs(info: CodeInfo): List[(String, Json)] =
        let CodeInfo.CodeInfo(language, fileName, highlightLines) = info;
        (language |> Option.map(found -> ("language", Json.JString(found))) |> Option.toList)
            ::: (fileName |> Option.map(found -> ("fileName", Json.JString(found))) |> Option.toList)
            ::: (highlightLines |> Option.map(found -> ("highlightLines", Json.JString(found))) |> Option.toList)

    def pictureJson(picture: Picture): Json =
        let Picture.Picture(assetId, alt, caption, size) = picture;
        leafNode("image",
            (("assetId", Json.JString(assetId)) :: Nil)
                ::: (alt |> Option.map(found -> ("alt", Json.JString(found))) |> Option.toList)
                ::: (caption |> Option.map(found -> ("caption", Json.JString(found))) |> Option.toList)
                ::: (size |> Option.map(match (width, height) -> ("width", intJson(width)) :: ("height", intJson(height)) :: Nil) |> Option.getWithDefault(Nil)))

    def listItemJson(item: ListItem): Json =
        let ListItem.ListItem(checked, blocks) = item;
        objectNode("listItem", checked |> Option.map(found -> ("checked", Json.JBool(found))) |> Option.toList, blocks |> List.map(blockJson))

    def cellJson(cell: Cell): Json =
        let Cell.Cell(isHeader, blocks) = cell;
        objectNode(if (isHeader) "tableHeader" else "tableCell", Nil, blocks |> List.map(blockJson))

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
        case Block.Blockquote(blocks)            => Some(renderBlocks(blocks) |> prefixLines(">"))
        case Block.Callout(kind, blocks)         => Some(("[!${calloutLabel(kind)}]" :: (Some(renderBlocks(blocks)) |> Option.filter(String.nonEmpty) |> Option.toList)) |> List.join("\n") |> prefixLines(">"))
        case Block.CodeBlock(info, code)         => Some(renderCodeBlock(info, code))
        case Block.Table(rows)                   => Some(renderTable(rows))
        case Block.HorizontalRule                => Some("---")
        case Block.Image(picture)                => Some(renderPicture(picture))
        case Block.Gallery(columns, pictures)    => Some(renderGallery(columns, pictures))
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

    /// `![alt](asset:ID "caption"){width=W height=H}`。caption は title の位置。alt だけの時は空の title を書く（title が無い形は caption と読むため）。
    def renderPicture(picture: Picture): String =
        let Picture.Picture(assetId, alt, caption, size) = picture;
        let title = match (alt, caption) {
            case (_, Some(found)) => " \"${escapeTitle(found)}\""
            case (Some(_), None)  => " \"\""
            case (None, None)     => ""
        };
        "![${alt |> Option.map(escape) |> Option.getWithDefault("")}](asset:${assetId}${title})${size |> Option.map(match (width, height) -> "{width=${width} height=${height}}") |> Option.getWithDefault("")}"

    /// title の中では `"` も逃がす。
    def escapeTitle(text: String): String = escape(text) |> String.replace(src = "\"", dst = "\\\"")

    /// image を空白で並べる。columns が枚数から決まる物と違う時だけ `{columns=N}` を足す。
    def renderGallery(columns: Int32, pictures: List[Picture]): String =
        let suffix = if (columns == defaultColumns(pictures)) "" else " {columns=${columns}}";
        (pictures |> List.map(renderPicture) |> List.join(" ")) ++ suffix

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

    /// 中身に ``` で始まる行があれば ```` で囲む。フェンスは ```` ```言語:ファイル名 {行} ````（無い物は書かない）。
    def renderCodeBlock(info: CodeInfo, code: String): String =
        let CodeInfo.CodeInfo(language, fileName, highlightLines) = info;
        let fence = if (code |> String.splitOn(substr = "\n") |> List.exists(String.startsWith(prefix = "```"))) "````" else "```";
        let header = (language |> Option.getWithDefault("")) ++ (fileName |> Option.map(found -> ":${found}") |> Option.getWithDefault("")) ++ (highlightLines |> Option.map(found -> " {${found}}") |> Option.getWithDefault(""));
        "${fence}${header}\n${code}\n${fence}"

    /// GFM の表。1 行目の次に区切り行。列数は 1 行目に合わせる。
    def renderTable(rows: List[List[Cell]]): String =
        let columns = rows |> List.head |> Option.map(List.length) |> Option.getWithDefault(1);
        let separator = "| ${List.repeat(columns, "---") |> List.join(" | ")} |";
        match rows |> List.map(renderRow) {
            case first :: rest => (first :: separator :: rest) |> List.join("\n")
            case Nil           => separator
        }

    def renderRow(cells: List[Cell]): String = "| ${cells |> List.map(renderCell) |> List.join(" | ")} |"

    /// セルは 1 行。段落と見出しの中身だけを空白で繋ぎ、改行は <br> に。
    def renderCell(cell: Cell): String =
        let Cell.Cell(_, blocks) = cell;
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
    }

    ///
    /// text の中で Markdown の記号になる文字（* _ [ ] ` \ # | < > ~ $）を \ で逃がす。読む時に戻る。
    ///
    def escape(text: String): String =
        text |> String.toList |> List.map(c -> if (isMarkdownSpecial(c)) "\\${c}" else Char.toString(c)) |> List.join("")

    def isMarkdownSpecial(c: Char): Bool =
        c == '*' or c == '_' or c == '[' or c == ']' or c == '`' or c == '\\' or c == '#' or c == '|' or c == '<' or c == '>' or c == '~' or c == '$'

    ///
    /// 段落の各行が箇条書き・番号・罫線に見えないようにする（`- a` → `\- a`、`1. a` → `1\. a`、`---` → `\---`）。
    /// escape が逃がさない `-` `+` と数字だけ。
    ///
    def guardLineStarts(text: String): String =
        text |> String.splitOn(substr = "\n") |> List.map(guardLineStart) |> List.join("\n")

    def guardLineStart(line: String): String =
        if (String.isMatch(regex = "^[-+](\\s.*)?$", line) or String.isMatch(regex = "^-{3,}\\s*$", line)) "\\${line}"
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
        case Fence(Int32, CodeInfo)
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
        case LineKind.Fence(length, info)      => parseFence(length, info, rest)
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

    /// ```` ```言語:ファイル名 {行} ````。言語・ファイル名・行は規則に合わなければ無い物にする。
    def fenceKind(line: String): Option[LineKind] = match captures("^\\s{0,3}(`{3,})([^\\s:{`]*)(?::(\\S+))?\\s*(?:\\{([^}\\s]*)\\})?\\s*$", line) {
        case fence :: language :: fileName :: highlightLines :: Nil =>
            Some(LineKind.Fence(String.length(fence), CodeInfo.CodeInfo(
                Some(language) |> Option.filter(RichText.isLanguage),
                Some(fileName) |> Option.filter(RichText.isFileName),
                Some(highlightLines) |> Option.filter(RichText.isHighlightLines))))
        case _ => None
    }

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

    /// ``` から閉じる ``` まで。閉じなければ末尾まで。
    def parseFence(length: Int32, info: CodeInfo, rest: List[String]): (Option[Block], List[String]) =
        let closes = line -> String.isMatch(regex = "^\\s{0,3}`{${length},}\\s*$", line);
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
            case None       => Block.Blockquote(parseBlocks(inner))
        }
        case Nil => Block.Blockquote(Nil)
    }

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

    /// 1 行目が tableHeader、2 行目（区切り）は読み飛ばし、`|` を含む行が続く間が表。
    def parseTable(lines: List[String]): (Option[Block], List[String]) =
        let (rowLines, after) = List.span(line -> not isBlank(line) and String.contains(substr = "|", line), lines);
        let rows = match rowLines {
            case header :: _ :: body => (splitCells(header) |> List.map(text -> Cell.Cell(true, cellBlocks(text)))) :: (body |> List.map(line -> splitCells(line) |> List.map(text -> Cell.Cell(false, cellBlocks(text)))))
            case header :: Nil       => (splitCells(header) |> List.map(text -> Cell.Cell(true, cellBlocks(text)))) :: Nil
            case Nil                 => Nil
        };
        (Some(Block.Table(rows)), after)

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

    /// image だけの段落。1 つなら image、空白区切りで 2 つ以上なら gallery（行末の `{columns=N}` は 2 〜 4 に丸める）。文字が混ざれば None。
    def picturesBlock(text: String): Option[Block] =
        let (pictures, rest) = takePictures(text, Nil);
        match (pictures, columnsSuffix(rest)) {
            case (picture :: Nil, Some(None))    => Some(Block.Image(picture))
            case (_ :: _ :: _, Some(columns))    => Some(Block.Gallery(columns |> Option.map(clampColumns) |> Option.getWithDefault(defaultColumns(pictures)), pictures))
            case _                               => None
        }

    /// 先頭から image を読めるだけ読む。(image の列, 残り)。image と image の間は空白。
    def takePictures(text: String, acc: List[Picture]): (List[Picture], String) = match takePicture(text) {
        case Some((picture, rest)) =>
            if (String.isMatch(regex = "^\\s+!\\[[\\s\\S]*$", rest)) takePictures(String.trimLeft(rest), picture :: acc)
            else (List.reverse(picture :: acc), rest)
        case None => (List.reverse(acc), text)
    }

    /// 残りが空なら Some(None)、`{columns=N}` なら Some(Some(N))、他は None。
    def columnsSuffix(rest: String): Option[Option[Int32]] = match captures("^\\s*(?:\\{columns=([0-9]{1,9})\\})?\\s*$", rest) {
        case "" :: Nil      => Some(None)
        case columns :: Nil => Some(Int32.fromString(columns))
        case _              => None
    }

    ///
    /// `![alt](asset:ID "caption"){width=W height=H}` を 1 つ。title が無い `![caption](asset:ID)` は caption と読む。
    /// (image, 残りの文字)。
    ///
    def takePicture(text: String): Option[(Picture, String)] =
        match captures("^!\\[((?:[^\\]\\\\]|\\\\.)*)\\]\\(asset:([A-Za-z0-9_-]{1,64})( \"((?:[^\"\\\\]|\\\\.)*)\")?\\)(?:\\{width=([0-9]{1,9}) height=([0-9]{1,9})\\})?([\\s\\S]*)$", text) {
            case bracket :: assetId :: titlePart :: title :: width :: height :: rest :: Nil =>
                let size = Int32.fromString(width) |> Option.flatMap(w -> Int32.fromString(height) |> Option.map(h -> (w, h)));
                let picture =
                    if (String.isEmpty(titlePart)) Picture.Picture(assetId, None, Some(unescape(bracket)) |> Option.filter(String.nonEmpty), size)
                    else Picture.Picture(assetId, Some(unescape(bracket)) |> Option.filter(String.nonEmpty), Some(unescape(title)) |> Option.filter(String.nonEmpty), size);
                Some((picture, rest))
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
        case '['  => linkStep(marks, text, pos)
        case ' '  => spaceStep(text, pos)
        case '*'  => delimiterStep(marks, text, pos)
        case '_'  => delimiterStep(marks, text, pos)
        case '~'  => delimiterStep(marks, text, pos)
        case c    => Step.Literal(c, pos + 1)
    }

    /// `\` + 改行は hardBreak、`\` + 記号はその記号、他は `\` のまま。
    def backslashStep(text: String, pos: Int32): Step = match String.nth(pos + 1, text) {
        case Some('\n')                       => Step.Break(pos + 2)
        case Some(next) if isAsciiPunct(next) => Step.Literal(next, pos + 2)
        case _                                => Step.Literal('\\', pos + 1)
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

    /// `[text](target)`。閉じないか target に空白があれば `[` の文字。`![` は image の書き方なので link にしない。
    def linkStep(marks: List[Mark], text: String, pos: Int32): Step =
        let found = (if (String.nth(pos - 1, text) == Some('!')) None else String.indexOfLeftWithOffset(substr = "](", offset = pos + 1, text))
            |> Option.flatMap(labelEnd -> closingParen(text, labelEnd + 2) |> Option.map(targetEnd -> (labelEnd, targetEnd)))
            |> Option.filter(match (labelEnd, targetEnd) -> not String.exists(Char.isWhitespace, String.slice(start = labelEnd + 2, end = targetEnd, text)));
        match found {
            case Some((labelEnd, targetEnd)) =>
                let target = linkTarget(String.slice(start = labelEnd + 2, end = targetEnd, text));
                Step.Nested(scanInlines(marks ::: (Mark.Link(target) :: Nil), String.slice(start = pos + 1, end = labelEnd, text)), targetEnd + 1)
            case None => Step.Literal('[', pos + 1)
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

    /// `**` `__` `~~` `*` `_`。閉じが無ければ文字。`_` は単語の途中では開かない。
    def delimiterStep(marks: List[Mark], text: String, pos: Int32): Step =
        List#{ ("**", Mark.Bold), ("__", Mark.Bold), ("~~", Mark.Strike), ("*", Mark.Italic), ("_", Mark.Italic) }
            |> List.findMap(match (delimiter, mark) -> delimited(marks, text, pos, delimiter, mark))
            |> Option.getWithDefault(Step.Literal(String.charAt(pos, text), pos + 1))

    def delimited(marks: List[Mark], text: String, pos: Int32, delimiter: String, mark: Mark): Option[Step] =
        let width = String.length(delimiter);
        let intraword = String.startsWith(prefix = "_", delimiter) and (String.nth(pos - 1, text) |> Option.exists(Char.isLetterOrDigit));
        if (not hasAt(delimiter, pos, text) or intraword) None
        else findCloser(delimiter, text, pos + width)
            |> Option.filter(end -> end > pos + width)
            |> Option.map(end -> Step.Nested(scanInlines(marks ::: (mark :: Nil), String.slice(start = pos + width, end = end, text)), end + width))

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

}
