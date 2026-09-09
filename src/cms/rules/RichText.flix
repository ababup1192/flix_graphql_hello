///
/// richText の中身。ProseMirror の doc 形式（TipTap 互換）を正として保存し、コンテンツ API で HTML・平文・目次・抜粋にする。全部純粋。
///
/// 形: `{ type: "doc", content: [node] }`。node は `{ type, attrs?, content?, marks?, text? }`。
/// 許すノードとマークはホワイトリストで、知らない物は invalid にする（後から足すのは易しく、外すのは既存の entry が壊れる）。
///
/// HTML には class を付けない。サイト側が `.prose h2` のように親で当てる。種類の区別が要る所（callout / embed / gallery / linkCard / codeBlock の fileName と mermaid / 数式 / タスクの checked）は data 属性。
///
/// ノードの一覧:
/// - container: paragraph / heading(level, id) / bulletList / orderedList / listItem(checked) / blockquote / codeBlock(language, fileName, highlightLines) /
///   table / tableRow / tableCell / tableHeader / callout(kind) / gallery(columns。中は image だけ) / details(summary)
/// - leaf: text(marks) / hardBreak / horizontalRule / image(assetId, alt, caption, width, height) / embed(url) / linkCard(url) /
///   mathBlock(tex) / video(assetId, caption, poster)
/// - mark: bold / italic / strike / underline / code / link(href | entryId) / math（text が TeX。他のマークと混ぜない）/ sub / sup（重ねない）/ highlight
///
/// 入れ子は許さない: 表のセルの中は段落だけ、引用の中に引用は入らない。リストの入れ子だけは Markdown で往復するので残す。
///
/// 数式は TeX のまま持ち、HTML は data-math の span / div（描画は KaTeX をサイト側で）。codeBlock の language が mermaid なら pre に data-diagram（描画は Mermaid をサイト側で）。
///
mod RichText {

    use Util.Json.Json

    /// 子（content）を持てるノード。table > tableRow > tableCell / tableHeader > paragraph。callout と details の中は段落など。gallery の中は image だけ。
    pub def containerNodes(): List[String] =
        "paragraph" :: "heading" :: "bulletList" :: "orderedList" :: "listItem" :: "blockquote" :: "codeBlock" ::
        "table" :: "tableRow" :: "tableCell" :: "tableHeader" :: "callout" :: "gallery" :: "details" :: Nil

    /// 子を持たないノード。image と video は attrs.assetId で asset を、embed は attrs.url で外部の動画や投稿を、linkCard は attrs.url で任意のページを指す。mathBlock は attrs.tex。
    pub def leafNodes(): List[String] = "text" :: "hardBreak" :: "horizontalRule" :: "image" :: "embed" :: "linkCard" :: "mathBlock" :: "video" :: Nil

    /// codeBlock の language のうち、図として描く物。HTML の pre に data-diagram が付く。
    pub def diagramLanguage(): String = "mermaid"

    /// gallery の attrs.columns の下限。attrs.columns が無い時の値でもある。
    pub def minGalleryColumns(): Int32 = 2

    /// gallery の attrs.columns の上限。
    pub def maxGalleryColumns(): Int32 = 4

    /// text に付けられるマーク。link は attrs.href（外部）か attrs.entryId（この CMS の entry）。math は text を TeX として持つ。
    ///
    /// 文字に付けられる印。**中身であって飾りではない物だけ**。
    ///
    /// WhyNot: 文字色と文字サイズを入れない。ヘッドレス CMS の役割は中身で、見た目はサイトが決める。
    /// 本文に色や大きさを埋めると、サイトのデザインより本文が強くなり、リニューアルと
    /// 暗いテーマで壊れる（白い背景で選んだ濃紺は暗い背景で読めない）。
    /// 「注意」「強調」の意図は callout と highlight で持つ。
    ///
    pub def markNames(): List[String] =
        "bold" :: "italic" :: "strike" :: "underline" :: "code" :: "link" :: "math" :: "sub" :: "sup" :: "highlight" :: Nil

    /// callout の種類。html では data-kind に出る。
    pub def calloutKinds(): List[String] = "note" :: "tip" :: "warning" :: Nil

    ///
    /// 表のセルの寄せ。html では style の text-align、Markdown では区切り行の `:`。
    /// **列の属性**なので、画面は列の全セルに同じ値を入れる（Markdown の区切り行が列に 1 つしか持てない）。
    ///
    pub def cellAligns(): List[String] = "left" :: "center" :: "right" :: Nil

    /// heading の level の範囲。
    pub def maxHeadingLevel(): Int32 = 4

    ///
    /// 見出し 1 つ。目次用。
    ///
    /// - level: 1 〜 4
    /// - text: 見出しの平文
    /// - id: html の見出しに付く id と同じ。doc の attrs.id があればそれ、無ければ出現順の `h-1`, `h-2`, ...
    ///
    pub type alias Heading = { level = Int32, text = String, id = String }

    ///
    /// html の image に埋める asset の情報。
    ///
    pub type alias ImageRef = { url = String, width = Option[Int32], height = Option[Int32] }

    ///
    /// 埋め込みの提供元。url から決まる。
    ///
    pub enum EmbedProvider with Eq, Order, ToString {
        case YouTube
        case Vimeo
        case X
    }

    ///
    /// doc の形か（type が "doc" のオブジェクト）。中身までは見ない。
    ///
    pub def isDoc(json: Json): Bool = match json {
        case Json.JObject(fields) => typeOf(fields) == Some("doc")
        case _                    => false
    }

    // ---- 検査 ----

    ///
    /// ホワイトリストで検査する。path は違反の場所（"fields.body" から始まり、".content[0]" と伸びる）。
    ///
    pub def validate(path: String, doc: Json): List[Violation] = match doc {
        case Json.JObject(fields) if typeOf(fields) == Some("doc") => checkChildren(path, fields)
        case _ => Violation.Violation(path, "richText は { type: \"doc\", content: [...] } の形にしてください") :: Nil
    }

    def checkChildren(path: String, fields: Map[String, Json]): List[Violation] = match Map.get("content", fields) {
        case None                     => Nil
        case Some(Json.JArray(items)) => items |> Vector.toList |> List.zipWithIndex |> List.flatMap(match (index, item) -> checkNode("${path}.content[${index}]", item))
        case Some(_)                  => Violation.Violation("${path}.content", "配列にしてください") :: Nil
    }

    def checkNode(path: String, node: Json): List[Violation] = match node {
        case Json.JObject(fields) => match typeOf(fields) {
            case None => Violation.Violation(path, "ノードに type がありません") :: Nil
            case Some("text") => checkText(path, fields)
            case Some("heading") => checkHeading(path, fields) ::: checkChildren(path, fields)
            case Some("codeBlock") => checkCodeBlock(path, fields) ::: checkChildren(path, fields)
            case Some("callout") => checkCallout(path, fields) ::: checkChildren(path, fields)
            case Some("image") => checkImage(path, fields)
            case Some("embed") => checkEmbed(path, fields)
            case Some("gallery") => checkGallery(path, fields)
            case Some("linkCard") => checkLinkCard(path, fields)
            case Some("details") => checkDetails(path, fields) ::: checkChildren(path, fields)
            case Some("listItem") => checkListItem(path, fields) ::: checkChildren(path, fields)
            case Some("tableCell") => checkTableCell(path, fields) ::: checkCellChildren(path, fields) ::: checkChildren(path, fields)
            case Some("tableHeader") => checkTableCell(path, fields) ::: checkCellChildren(path, fields) ::: checkChildren(path, fields)
            case Some("blockquote") => checkQuoteChildren(path, fields) ::: checkChildren(path, fields)
            case Some("mathBlock") => checkMathBlock(path, fields)
            case Some("video") => checkVideo(path, fields)
            case Some(name) if List.memberOf(name, containerNodes()) => checkChildren(path, fields)
            case Some(name) if List.memberOf(name, leafNodes()) => Nil
            case Some(name) => Violation.Violation(path, "知らないノード '${name}' です（${List.join(", ", containerNodes() ::: leafNodes())}）") :: Nil
        }
        case _ => Violation.Violation(path, "ノードはオブジェクトにしてください") :: Nil
    }

    /// text ノード。text は文字列、marks は許可リストの物だけ。math が付く text は TeX なので空でなく、他のマークと混ぜない。
    def checkText(path: String, fields: Map[String, Json]): List[Violation] =
        let textCheck = match Map.get("text", fields) |> Option.flatMap(EntryValue.asString) {
            case Some(_) => Nil
            case None    => Violation.Violation(path, "text ノードには文字列の text が要ります") :: Nil
        };
        let mathCheck = match (hasMathMark(fields), List.length(marksOf(fields)), Map.get("text", fields) |> Option.flatMap(EntryValue.asString) |> Option.map(String.trim)) {
            case (false, _, _)       => Nil
            case (true, 1, Some(tex)) if String.nonEmpty(tex) => Nil
            case _                   => Violation.Violation(path, "math の text は空でない TeX にし、他のマークと混ぜないでください") :: Nil
        };
        let raisedCheck =
            if (List.length(marksOf(fields) |> List.filter(mark -> List.memberOf(typeOf(mark), List#{ Some("sub"), Some("sup") }))) >= 2)
                Violation.Violation(path, "上付きと下付きは同じ文字に重ねないでください") :: Nil
            else Nil;
        textCheck ::: mathCheck ::: raisedCheck ::: (marksOf(fields) |> List.zipWithIndex |> List.flatMap(match (index, mark) -> checkMark("${path}.marks[${index}]", mark)))

    def hasMathMark(fields: Map[String, Json]): Bool = marksOf(fields) |> List.exists(mark -> typeOf(mark) == Some("math"))

    /// link は href（http(s) / mailto）か entryId（entry の id）のどちらか 1 つ。
    def checkMark(path: String, mark: Map[String, Json]): List[Violation] = match typeOf(mark) {
        case Some("link") => match (attrString("href", mark), attrString("entryId", mark)) {
            case (Some(href), None) if isSafeHref(href) => Nil
            case (None, Some(entryId)) if Option.nonEmpty(EntryId.parse(entryId)) => Nil
            case _ => Violation.Violation(path, "link は attrs.href（http(s):// か mailto:）か attrs.entryId（entry の id）のどちらか 1 つにしてください") :: Nil
        }
        case Some(name) if List.memberOf(name, markNames()) => Nil
        case Some(name) => Violation.Violation(path, "知らないマーク '${name}' です（${List.join(", ", markNames())}）") :: Nil
        case None => Violation.Violation(path, "マークに type がありません") :: Nil
    }

    /// heading。level は範囲内、attrs.id は任意で、あれば英数字と `_ -`。
    def checkHeading(path: String, fields: Map[String, Json]): List[Violation] =
        let levelCheck = match attrInt("level", fields) {
            case Some(level) if level >= 1 and level <= maxHeadingLevel() => Nil
            case _ => Violation.Violation(path, "heading の attrs.level は 1 〜 ${maxHeadingLevel()} にしてください") :: Nil
        };
        let idCheck = match Map.get("id", attrs(fields)) {
            case None => Nil
            case Some(Json.JString(id)) if isHeadingId(id) => Nil
            case Some(_) => Violation.Violation(path, "heading の attrs.id は英数字と _ - を 1 〜 64 文字にしてください") :: Nil
        };
        levelCheck ::: idCheck

    /// codeBlock。attrs.language / fileName / highlightLines はどれも任意で、あれば形を見る。
    def checkCodeBlock(path: String, fields: Map[String, Json]): List[Violation] =
        checkOptionalString(path, "language", isLanguage, "codeBlock の attrs.language は小文字英数字と + # - を 1 〜 32 文字にしてください", fields)
            ::: checkOptionalString(path, "fileName", isFileName, "codeBlock の attrs.fileName はパスの文字（英数字・日本語・/ . _ -）を 1 〜 200 文字にしてください", fields)
            ::: checkOptionalString(path, "highlightLines", isHighlightLines, "codeBlock の attrs.highlightLines は 1,3-5 の形にしてください", fields)

    /// 任意の文字列の attr。無ければ通り、あれば文字列で規則に合う事。
    def checkOptionalString(path: String, name: String, isValid: String -> Bool, message: String, fields: Map[String, Json]): List[Violation] =
        match Map.get(name, attrs(fields)) {
            case None => Nil
            case Some(Json.JString(found)) if isValid(found) => Nil
            case Some(_) => Violation.Violation(path, message) :: Nil
        }

    /// callout。attrs.kind は note / tip / warning。
    def checkCallout(path: String, fields: Map[String, Json]): List[Violation] = match attrString("kind", fields) {
        case Some(kind) if List.memberOf(kind, calloutKinds()) => Nil
        case _ => Violation.Violation(path, "callout の attrs.kind は ${List.join(" / ", calloutKinds())} にしてください") :: Nil
    }

    /// 表のセル。attrs.align は任意で、あれば left / center / right。
    ///
    /// 表のセルの中は段落だけ。
    ///
    /// WhyNot: 表・引用・コードブロック・箇条書き・見出し・画像を入れない。**Markdown の表の
    /// セルは inline しか持てない**ので、書き出すと段落の中身以外は黙って消える
    /// （`Markdown.renderCell`）。画面に出ている物と Markdown・HTML に出る物が食い違う。
    ///
    def checkCellChildren(path: String, fields: Map[String, Json]): List[Violation] =
        children(fields) |> List.zipWithIndex |> List.flatMap(match (index, child) ->
            if (nodeType(child) == Some("paragraph")) Nil
            else Violation.Violation("${path}.content[${index}]", "表のセルの中は段落だけにしてください") :: Nil)

    ///
    /// 引用の中に引用は入れない。
    ///
    /// WhyNot: `>>` は Markdown で書けるが、深さに意味を持たせる書き方が定まらない。
    /// 引用の引用は元の出典が二重になるだけで、読む側には 1 段の引用と区別が付かない。
    ///
    def checkQuoteChildren(path: String, fields: Map[String, Json]): List[Violation] =
        children(fields) |> List.zipWithIndex |> List.flatMap(match (index, child) ->
            if (nodeType(child) == Some("blockquote"))
                Violation.Violation("${path}.content[${index}]", "引用の中に引用は入れられません") :: Nil
            else Nil)

    def checkTableCell(path: String, fields: Map[String, Json]): List[Violation] = match Map.get("align", attrs(fields)) {
        case None    => Nil
        case Some(found) =>
            if (EntryValue.asString(found) |> Option.exists(align -> List.memberOf(align, cellAligns()))) Nil
            else Violation.Violation(path, "セルの attrs.align は ${List.join(" / ", cellAligns())} にしてください") :: Nil
    }

    /// image ノード。attrs.assetId は asset の id。alt は任意の文字列。
    def checkImage(path: String, fields: Map[String, Json]): List[Violation] =
        let assetIdCheck = match attrString("assetId", fields) |> Option.flatMap(AssetId.parse) {
            case Some(_) => Nil
            case None    => Violation.Violation(path, "image の attrs.assetId は asset の id にしてください") :: Nil
        };
        assetIdCheck ::: checkOptionalString(path, "alt", _ -> true, "image の attrs.alt は文字列にしてください", fields)

    /// gallery。attrs.columns は任意で 2 〜 4。中は 1 つ以上の image だけ。
    def checkGallery(path: String, fields: Map[String, Json]): List[Violation] =
        let columnsCheck = match Map.get("columns", attrs(fields)) {
            case None => Nil
            case Some(found) if Option.exists(isGalleryColumns, EntryValue.asInt32(found)) => Nil
            case Some(_) => Violation.Violation(path, "gallery の attrs.columns は ${minGalleryColumns()} 〜 ${maxGalleryColumns()} にしてください") :: Nil
        };
        let emptyCheck = if (List.isEmpty(children(fields))) Violation.Violation(path, "gallery には image を 1 つ以上入れてください") :: Nil else Nil;
        columnsCheck ::: emptyCheck ::: (children(fields) |> List.zipWithIndex |> List.flatMap(match (index, child) -> checkGalleryChild("${path}.content[${index}]", child)))

    def checkGalleryChild(path: String, child: Json): List[Violation] = match child {
        case Json.JObject(fields) if typeOf(fields) == Some("image") => checkImage(path, fields)
        case _ => Violation.Violation(path, "gallery の中は image だけにしてください") :: Nil
    }

    /// linkCard。attrs.url は http(s) だけ（mailto: はカードにならない）。
    def checkLinkCard(path: String, fields: Map[String, Json]): List[Violation] = match attrString("url", fields) {
        case Some(url) if isHttpUrl(url) => Nil
        case _ => Violation.Violation(path, "linkCard の attrs.url は http(s):// にしてください") :: Nil
    }

    /// details。attrs.summary は空でない文字列。
    def checkDetails(path: String, fields: Map[String, Json]): List[Violation] = match attrString("summary", fields) {
        case Some(summary) if String.nonEmpty(String.trim(summary)) => Nil
        case _ => Violation.Violation(path, "details の attrs.summary は空でない文字列にしてください") :: Nil
    }

    /// listItem。attrs.checked は任意で、あれば Bool（タスクリストの項目）。
    def checkListItem(path: String, fields: Map[String, Json]): List[Violation] = match Map.get("checked", attrs(fields)) {
        case None                => Nil
        case Some(Json.JBool(_)) => Nil
        case Some(_)             => Violation.Violation(path, "listItem の attrs.checked は true / false にしてください") :: Nil
    }

    /// mathBlock。attrs.tex は空でない文字列。
    def checkMathBlock(path: String, fields: Map[String, Json]): List[Violation] = match attrString("tex", fields) {
        case Some(tex) if String.nonEmpty(String.trim(tex)) => Nil
        case _ => Violation.Violation(path, "mathBlock の attrs.tex は空でない TeX にしてください") :: Nil
    }

    /// video ノード。attrs.assetId は asset の id。caption は任意の文字列、poster は任意で asset の id。
    def checkVideo(path: String, fields: Map[String, Json]): List[Violation] =
        let assetIdCheck = match attrString("assetId", fields) |> Option.flatMap(AssetId.parse) {
            case Some(_) => Nil
            case None    => Violation.Violation(path, "video の attrs.assetId は asset の id にしてください") :: Nil
        };
        assetIdCheck
            ::: checkOptionalString(path, "caption", _ -> true, "video の attrs.caption は文字列にしてください", fields)
            ::: checkOptionalString(path, "poster", poster -> Option.nonEmpty(AssetId.parse(poster)), "video の attrs.poster は asset の id にしてください", fields)

    /// embed ノード。attrs.url が知っている提供元の形でなければ止める（任意の iframe は通さない）。
    def checkEmbed(path: String, fields: Map[String, Json]): List[Violation] = match attrString("url", fields) |> Option.flatMap(embedOf) {
        case Some(_) => Nil
        case None    => Violation.Violation(path, "embed の attrs.url は YouTube / Vimeo / X の投稿の URL にしてください") :: Nil
    }

    /// 見出しの id に許す形。
    pub def isHeadingId(id: String): Bool = String.isMatch(regex = "^[A-Za-z0-9_-]{1,64}$", id)

    /// コードの言語名に許す形（ts / c++ / c# / objective-c）。
    pub def isLanguage(language: String): Bool = String.isMatch(regex = "^[a-z0-9+#-]{1,32}$", language)

    /// link に許す href。javascript: 等を通さない。
    pub def isSafeHref(href: String): Bool = isHttpUrl(href) or String.startsWith(prefix = "mailto:", href)

    /// linkCard に許す url。http(s) だけ。
    pub def isHttpUrl(url: String): Bool = String.startsWith(prefix = "https://", url) or String.startsWith(prefix = "http://", url)

    /// codeBlock のファイル名に許す形。パスの文字（英数字・日本語などの文字・/ . _ -）で、空白と " < > は通らない。
    pub def isFileName(fileName: String): Bool = String.isMatch(regex = "^[\\p{L}\\p{N}_./-]{1,200}$", fileName)

    /// codeBlock の強調行に許す形。`1,3-5` のように行番号か範囲をカンマで並べる。
    pub def isHighlightLines(lines: String): Bool = String.isMatch(regex = "^[0-9]{1,6}(-[0-9]{1,6})?(,[0-9]{1,6}(-[0-9]{1,6})?)*$", lines)

    /// gallery の columns に許す範囲。
    pub def isGalleryColumns(columns: Int32): Bool = columns >= minGalleryColumns() and columns <= maxGalleryColumns()

    ///
    /// 埋め込みの URL から (提供元, id)。知らない形は None。
    ///
    /// - YouTube: `https://www.youtube.com/watch?v=ID`、`https://youtu.be/ID`
    /// - Vimeo: `https://vimeo.com/ID`
    /// - X: `https://x.com/{user}/status/ID`、`https://twitter.com/{user}/status/ID`
    ///
    pub def embedOf(url: String): Option[(EmbedProvider, String)] =
        if (String.isMatch(regex = "^https://(www\\.)?youtube\\.com/watch\\?v=[A-Za-z0-9_-]{6,20}([&#].*)?$", url))
            Some((EmbedProvider.YouTube, url |> afterMarker("v=") |> takeWhileIdChar))
        else if (String.isMatch(regex = "^https://youtu\\.be/[A-Za-z0-9_-]{6,20}([?#].*)?$", url))
            Some((EmbedProvider.YouTube, url |> afterMarker("youtu.be/") |> takeWhileIdChar))
        else if (String.isMatch(regex = "^https://vimeo\\.com/[0-9]{1,20}([?#].*)?$", url))
            Some((EmbedProvider.Vimeo, url |> afterMarker("vimeo.com/") |> takeWhileIdChar))
        else if (String.isMatch(regex = "^https://(x\\.com|twitter\\.com)/[A-Za-z0-9_]{1,15}/status/[0-9]{1,25}([?#].*)?$", url))
            Some((EmbedProvider.X, url |> afterMarker("/status/") |> takeWhileIdChar))
        else None

    def afterMarker(marker: String, text: String): String = match String.indexOf(substr = marker, text) {
        case Some(i) => String.drop(i + String.length(marker), text)
        case None    => ""
    }

    def takeWhileIdChar(text: String): String =
        text |> String.toList |> List.takeWhile(c -> Char.isLetterOrDigit(c) or c == '_' or c == '-') |> List.map(Char.toString) |> List.join("")

    // ---- 取り出し ----

    ///
    /// image と video が指す asset の id（video は poster も）。重複を除く。規則に合わない物は捨てる（検査が先に止める）。
    ///
    pub def assetIds(doc: Json): List[AssetId] =
        nodes(doc) |> List.flatMap(nodeAssetIds) |> List.filterMap(AssetId.parse) |> List.distinct

    /// 1 ノードが指す asset の id の文字列。
    def nodeAssetIds(fields: Map[String, Json]): List[String] = match typeOf(fields) {
        case Some("image") => attrString("assetId", fields) |> Option.toList
        case Some("video") => (attrString("assetId", fields) |> Option.toList) ::: (attrString("poster", fields) |> Option.toList)
        case _             => Nil
    }

    ///
    /// link が指す entry の id。重複を除く。
    ///
    pub def linkedEntryIds(doc: Json): List[EntryId] =
        nodes(doc) |> List.flatMap(marksOf) |> List.filter(mark -> typeOf(mark) == Some("link")) |> List.filterMap(attrString("entryId")) |> List.filterMap(EntryId.parse) |> List.distinct

    ///
    /// 見出しの一覧。出現順。id は html の見出しと同じ。
    ///
    pub def headings(doc: Json): List[Heading] =
        nodes(withHeadingIds(doc))
            |> List.filter(fields -> typeOf(fields) == Some("heading"))
            |> List.map(fields -> {
                level = attrInt("level", fields) |> Option.getWithDefault(1),
                text = childrenText(fields) |> String.trim,
                id = attrString("id", fields) |> Option.getWithDefault("")
            })

    ///
    /// attrs.id の無い heading に出現順の `h-N` を入れた doc。html と headings が同じ id を見るための前処理。
    ///
    def withHeadingIds(doc: Json): Json = fst(numberHeadings(1, doc))

    /// ノードとその子に id を入れる。次に使う番号を一緒に返す。
    def numberHeadings(next: Int32, node: Json): (Json, Int32) = match node {
        case Json.JObject(fields) =>
            let (numbered, afterSelf) =
                if (typeOf(fields) == Some("heading") and Option.isEmpty(attrString("id", fields)))
                    (Map.insert("attrs", Json.JObject(Map.insert("id", Json.JString("h-${next}"), attrs(fields))), fields), next + 1)
                else (fields, next);
            let (childrenNumbered, afterChildren) = List.foldLeft((state, child) -> {
                let (acc, counter) = state;
                let (done, following) = numberHeadings(counter, child);
                (done :: acc, following)
            }, (Nil, afterSelf), children(numbered));
            let content = childrenNumbered |> List.reverse |> List.toVector |> Json.JArray;
            (Json.JObject(if (List.isEmpty(children(numbered))) numbered else Map.insert("content", content, numbered)), afterChildren)
        case other => (other, next)
    }

    ///
    /// 平文。text を繋ぎ、ブロックの終わりと hardBreak で改行する。続く改行は 2 つまで（空行 1 つ）に畳み、先頭と末尾の改行は無い。検索と一覧の抜粋用。
    ///
    pub def toText(doc: Json): String = textOf(doc) |> String.replaceMatches(regex = "\n{3,}", to = "\n\n") |> String.trim

    def textOf(node: Json): String = match node {
        case Json.JObject(fields) => match typeOf(fields) {
            case Some("text")      => Map.get("text", fields) |> Option.flatMap(EntryValue.asString) |> Option.getWithDefault("")
            case Some("hardBreak") => "\n"
            case Some("gallery")   => (children(fields) |> List.filterMap(captionOf) |> List.map(caption -> caption ++ "\n") |> List.join(""))
            case Some("linkCard")  => (attrString("url", fields) |> Option.getWithDefault("")) ++ "\n"
            case Some("details")   => (attrString("summary", fields) |> Option.getWithDefault("")) ++ "\n" ++ childrenText(fields)
            case Some("mathBlock") => (attrString("tex", fields) |> Option.getWithDefault("")) ++ "\n"
            case Some(name) if List.memberOf(name, containerNodes()) => childrenText(fields) ++ "\n"
            case _                 => childrenText(fields)
        }
        case _ => ""
    }

    /// image の空でない caption。
    def captionOf(node: Json): Option[String] = match node {
        case Json.JObject(fields) => attrString("caption", fields) |> Option.filter(String.nonEmpty)
        case _                    => None
    }

    def childrenText(fields: Map[String, Json]): String =
        children(fields) |> List.map(textOf) |> List.join("")

    // ---- 派生値（ブログ向け）----

    ///
    /// 抜粋。平文の改行を空白にし、先頭 length 文字。切れたら末尾に `…`。
    ///
    pub def excerpt(length: Int32, doc: Json): String =
        let flat = toText(doc) |> String.replace(src = "\n", dst = " ") |> String.trim;
        let chars = String.toList(flat);
        if (List.length(chars) <= length) flat
        else (chars |> List.take(length) |> List.map(Char.toString) |> List.join("") |> String.trim) ++ "…"

    ///
    /// 語数。日本語など（ひらがな・カタカナ・漢字・ハングル）は 1 文字 1 語、それ以外は空白で区切った語。
    ///
    pub def wordCount(doc: Json): Int32 =
        let (cjk, latinWords) = countWords(doc);
        cjk + latinWords

    ///
    /// 読了時間（分）。日本語は 1 分 500 文字、それ以外は 1 分 200 語として切り上げ。最低 1 分。
    ///
    pub def readingTimeMinutes(doc: Json): Int32 =
        let (cjk, latinWords) = countWords(doc);
        let minutes = (Int32.toFloat64(cjk) / 500.0 + Int32.toFloat64(latinWords) / 200.0) |> Float64.ceil |> Float64.tryToInt32 |> Option.getWithDefault(1);
        Int32.max(1, minutes)

    /// (日本語などの文字数, それ以外の語数)。
    def countWords(doc: Json): (Int32, Int32) =
        let chars = toText(doc) |> String.toList;
        let cjk = chars |> List.count(isCjk);
        let latinWords = chars |> List.map(c -> if (isCjk(c) or c == '\n') ' ' else c) |> List.map(Char.toString) |> List.join("")
            |> String.splitOn(substr = " ") |> List.count(word -> not String.isEmpty(String.trim(word)));
        (cjk, latinWords)

    /// ひらがな・カタカナ・CJK 統合漢字・全角の記号と英数・ハングル。
    def isCjk(c: Char): Bool =
        let code = Char.toBmpCodePoint(c);
        (code >= 0x3040 and code <= 0x30FF) or (code >= 0x3400 and code <= 0x9FFF) or (code >= 0xFF00 and code <= 0xFFEF) or (code >= 0xAC00 and code <= 0xD7AF)

    // ---- HTML ----

    ///
    /// HTML にする。images は image と video（poster も）の asset id → 配信 URL と寸法。無い asset の image / video は出さない。文字は全部エスケープする。
    /// 見出しには headings と同じ id が付く。空の段落は出さない。
    /// 外部リンクは `target="_blank" rel="noopener noreferrer"`、entry へのリンクは `href="#entry:{id}" data-entry-id`
    /// （サイトが slug に置き換える。json 側の entryId と同じ値）。
    ///
    pub def toHtml(images: Map[AssetId, ImageRef], doc: Json): String = htmlOf(images, withHeadingIds(doc))

    def htmlOf(images: Map[AssetId, ImageRef], node: Json): String = match node {
        case Json.JObject(fields) =>
            let inner = () -> children(fields) |> List.map(htmlOf(images)) |> List.join("");
            match typeOf(fields) {
                case Some("text")           => applyMarks(marksOf(fields), escape(Map.get("text", fields) |> Option.flatMap(EntryValue.asString) |> Option.getWithDefault("")))
                case Some("paragraph")      => { let body = inner(); if (String.isEmpty(String.trim(body))) "" else "<p>${body}</p>" }
                case Some("heading")        =>
                    let level = attrInt("level", fields) |> Option.getWithDefault(1);
                    let id = attrString("id", fields) |> Option.map(found -> " id=\"${escape(found)}\"") |> Option.getWithDefault("");
                    "<h${level}${id}>${inner()}</h${level}>"
                case Some("bulletList")     => "<ul>${inner()}</ul>"
                case Some("orderedList")    => "<ol>${inner()}</ol>"
                case Some("listItem")       =>
                    let checked = Map.get("checked", attrs(fields)) |> Option.flatMap(EntryValue.asBool) |> Option.map(found -> " data-checked=\"${found}\"") |> Option.getWithDefault("");
                    "<li${checked}>${inner()}</li>"
                case Some("blockquote")     => "<blockquote>${inner()}</blockquote>"
                case Some("codeBlock")      =>
                    let language = attrString("language", fields) |> Option.filter(isLanguage) |> Option.map(found -> " class=\"language-${found}\"") |> Option.getWithDefault("");
                    let diagram = attrString("language", fields) |> Option.filter(found -> found == diagramLanguage()) |> Option.map(found -> " data-diagram=\"${found}\"") |> Option.getWithDefault("");
                    let fileName = attrString("fileName", fields) |> Option.filter(isFileName) |> Option.map(found -> " data-file-name=\"${escape(found)}\"") |> Option.getWithDefault("");
                    let highlightLines = attrString("highlightLines", fields) |> Option.filter(isHighlightLines) |> Option.map(found -> " data-highlight-lines=\"${found}\"") |> Option.getWithDefault("");
                    "<pre${diagram}${fileName}${highlightLines}><code${language}>${inner()}</code></pre>"
                case Some("table")          => tableHtml(images, fields)
                case Some("tableRow")       => "<tr>${inner()}</tr>"
                case Some("tableCell")      => "<td${spanAttrs(fields)}${alignAttr(fields)}>${inner()}</td>"
                case Some("tableHeader")    => "<th${spanAttrs(fields)}${alignAttr(fields)}>${inner()}</th>"
                case Some("callout")        => "<aside data-kind=\"${escape(attrString("kind", fields) |> Option.getWithDefault("note"))}\">${inner()}</aside>"
                case Some("horizontalRule") => "<hr>"
                case Some("hardBreak")      => "<br>"
                case Some("image")          => imageHtml(images, fields)
                case Some("embed")          => embedHtml(fields)
                case Some("gallery")        => galleryHtml(images, fields)
                case Some("linkCard")       => linkCardHtml(fields)
                case Some("details")        => "<details><summary>${escape(attrString("summary", fields) |> Option.getWithDefault(""))}</summary>${inner()}</details>"
                case Some("mathBlock")      => "<div data-math=\"block\">${escape(attrString("tex", fields) |> Option.getWithDefault(""))}</div>"
                case Some("video")          => videoHtml(images, fields)
                case _                      => inner()
            }
        case _ => ""
    }

    /// image。caption があれば figure で包む。
    def imageHtml(images: Map[AssetId, ImageRef], fields: Map[String, Json]): String =
        match imageParts(images, fields) {
            case Some((img, Some(caption))) => "<figure>${img}<figcaption>${caption}</figcaption></figure>"
            case Some((img, None))          => img
            case None                       => ""
        }

    /// image の img タグと、エスケープ済みの caption。asset が無ければ None。
    def imageParts(images: Map[AssetId, ImageRef], fields: Map[String, Json]): Option[(String, Option[String])] =
        attrString("assetId", fields) |> Option.flatMap(AssetId.parse) |> Option.flatMap(id -> Map.get(id, images)) |> Option.map(image -> {
            let size = match (image#width, image#height) {
                case (Some(width), Some(height)) => " width=\"${width}\" height=\"${height}\""
                case _                           => ""
            };
            let img = "<img src=\"${escape(image#url)}\" alt=\"${escape(attrString("alt", fields) |> Option.getWithDefault(""))}\"${size}>";
            (img, attrString("caption", fields) |> Option.filter(String.nonEmpty) |> Option.map(escape))
        })

    /// video。figure の中の video。src は asset の URL、poster は poster の asset の URL（無ければ属性ごと出ない）。asset が無ければ出ない。
    /// 変換はしないので、寸法は付けない。
    def videoHtml(images: Map[AssetId, ImageRef], fields: Map[String, Json]): String =
        match attrString("assetId", fields) |> Option.flatMap(AssetId.parse) |> Option.flatMap(id -> Map.get(id, images)) {
            case Some(source) =>
                let poster = attrString("poster", fields) |> Option.flatMap(AssetId.parse) |> Option.flatMap(id -> Map.get(id, images)) |> Option.map(found -> " poster=\"${escape(found#url)}\"") |> Option.getWithDefault("");
                let caption = attrString("caption", fields) |> Option.filter(String.nonEmpty) |> Option.map(found -> "<figcaption>${escape(found)}</figcaption>") |> Option.getWithDefault("");
                "<figure><video controls src=\"${escape(source#url)}\"${poster}></video>${caption}</figure>"
            case None => ""
        }

    /// gallery。data-gallery に columns。中の image は並べる箱になるので caption が無くても figure。
    def galleryHtml(images: Map[AssetId, ImageRef], fields: Map[String, Json]): String =
        let columns = attrInt("columns", fields) |> Option.filter(isGalleryColumns) |> Option.getWithDefault(minGalleryColumns());
        let items = children(fields) |> List.filterMap(child -> match child {
            case Json.JObject(image) if typeOf(image) == Some("image") => imageParts(images, image)
            case _ => None
        }) |> List.map(match (img, caption) -> "<figure>${img}${caption |> Option.map(found -> "<figcaption>${found}</figcaption>") |> Option.getWithDefault("")}</figure>") |> List.join("");
        "<div data-gallery=\"${columns}\">${items}</div>"

    /// linkCard。url だけの a。OGP の取得と見た目はサイト側。
    def linkCardHtml(fields: Map[String, Json]): String = match attrString("url", fields) |> Option.filter(isHttpUrl) {
        case Some(url) => "<a data-link-card href=\"${escape(url)}\">${escape(url)}</a>"
        case None      => ""
    }

    /// embed。提供元ごとの固定の形。X はサイト側で widgets.js を読めば埋め込みになり、読まなければリンクとして残る。
    def embedHtml(fields: Map[String, Json]): String =
        match attrString("url", fields) |> Option.flatMap(url -> embedOf(url) |> Option.map(found -> (url, found))) {
            case Some((_, (EmbedProvider.YouTube, id))) =>
                "<figure data-embed=\"youtube\"><iframe src=\"https://www.youtube.com/embed/${id}\" loading=\"lazy\" allowfullscreen allow=\"accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture\"></iframe></figure>"
            case Some((_, (EmbedProvider.Vimeo, id))) =>
                "<figure data-embed=\"vimeo\"><iframe src=\"https://player.vimeo.com/video/${id}\" loading=\"lazy\" allowfullscreen allow=\"autoplay; fullscreen; picture-in-picture\"></iframe></figure>"
            case Some((url, (EmbedProvider.X, _))) =>
                "<figure data-embed=\"x\"><blockquote class=\"twitter-tweet\"><a href=\"${escape(url)}\">${escape(url)}</a></blockquote></figure>"
            case None => ""
        }

    /// マークを外側から順に巻く（先頭のマークが一番外）。
    def applyMarks(marks: List[Map[String, Json]], text: String): String =
        List.foldRight((mark, acc) -> match typeOf(mark) {
            case Some("bold")      => "<strong>${acc}</strong>"
            case Some("italic")    => "<em>${acc}</em>"
            case Some("strike")    => "<s>${acc}</s>"
            case Some("underline") => "<u>${acc}</u>"
            case Some("code")      => "<code>${acc}</code>"
            case Some("sub")       => "<sub>${acc}</sub>"
            case Some("sup")       => "<sup>${acc}</sup>"
            // 色はサイトが決める。**役割だけを渡す。**
            case Some("highlight") => "<mark>${acc}</mark>"
            case Some("math")      => "<span data-math=\"inline\">${acc}</span>"
            case Some("link")      => match (attrString("href", mark), attrString("entryId", mark) |> Option.flatMap(EntryId.parse)) {
                case (Some(href), _) if isSafeHref(href) => "<a href=\"${escape(href)}\" target=\"_blank\" rel=\"noopener noreferrer\">${acc}</a>"
                case (_, Some(entryId)) => "<a href=\"#entry:${EntryId.text(entryId)}\" data-entry-id=\"${EntryId.text(entryId)}\">${acc}</a>"
                case _ => acc
            }
            case _ => acc
        }, text, marks)

    ///
    /// HTML の特殊文字をエスケープする。属性値にもそのまま使える。
    ///
    pub def escape(text: String): String =
        text
            |> String.replace(src = "&", dst = "&amp;")
            |> String.replace(src = "<", dst = "&lt;")
            |> String.replace(src = ">", dst = "&gt;")
            |> String.replace(src = "\"", dst = "&quot;")
            |> String.replace(src = "'", dst = "&#39;")

    // ---- JSON の読み方 ----

    /// doc の全ノード（自分を含む）を深さ優先で並べる。
    def nodes(node: Json): List[Map[String, Json]] = match node {
        case Json.JObject(fields) => fields :: (children(fields) |> List.flatMap(nodes))
        case _                    => Nil
    }

    def typeOf(fields: Map[String, Json]): Option[String] =
        Map.get("type", fields) |> Option.flatMap(EntryValue.asString)

    def nodeType(node: Json): Option[String] = match node {
        case Json.JObject(fields) => typeOf(fields)
        case _                    => None
    }

    def children(fields: Map[String, Json]): List[Json] = match Map.get("content", fields) {
        case Some(Json.JArray(items)) => Vector.toList(items)
        case _                        => Nil
    }

    def marksOf(fields: Map[String, Json]): List[Map[String, Json]] = match Map.get("marks", fields) {
        case Some(Json.JArray(items)) => items |> Vector.toList |> List.filterMap(item -> match item { case Json.JObject(mark) => Some(mark) case _ => None })
        case _                        => Nil
    }

    def attrs(fields: Map[String, Json]): Map[String, Json] = match Map.get("attrs", fields) {
        case Some(Json.JObject(found)) => found
        case _                         => Map.empty()
    }

    def attrString(name: String, fields: Map[String, Json]): Option[String] =
        Map.get(name, attrs(fields)) |> Option.flatMap(EntryValue.asString)

    ///
    /// 表。**見出しだけの先頭行は thead、残りは tbody に入れる。**
    /// tr を table の直下に置くと HTML として不正で、読む側が thead / tbody で見分けられない
    /// （サイト側の CSS が `thead th` で書けない）。
    ///
    def tableHtml(images: Map[AssetId, ImageRef], fields: Map[String, Json]): String =
        let rows = children(fields);
        let render = list -> list |> List.map(htmlOf(images)) |> List.join("");
        match rows {
            case Nil          => "<table></table>"
            case head :: rest =>
                if (isHeaderRow(head)) {
                    let body = if (List.isEmpty(rest)) "" else "<tbody>${render(rest)}</tbody>";
                    "<table><thead>${htmlOf(images, head)}</thead>${body}</table>"
                } else {
                    "<table><tbody>${render(rows)}</tbody></table>"
                }
        }

    /// セルが 1 つ以上あって、全部が tableHeader の行。
    def isHeaderRow(row: Json): Bool = match row {
        case Json.JObject(rowFields) =>
            let cells = children(rowFields);
            not List.isEmpty(cells) and List.forAll(isHeaderCell, cells)
        case _ => false
    }

    def isHeaderCell(cell: Json): Bool = match cell {
        case Json.JObject(cellFields) => typeOf(cellFields) == Some("tableHeader")
        case _                        => false
    }

    ///
    /// セルの結合。**2 以上の時だけ出す。**
    /// エディタは結合していないセルにも colspan / rowspan を 1 で付けるので、そのまま出すと
    /// 全セルに意味の無い属性が並ぶ。落とすと、API や取り込みが入れた結合が消えて表が崩れる。
    ///
    ///
    /// セルの寄せ。**style で出す**（属性の align は HTML5 で廃止）。
    /// colgroup には出せない（CSS の text-align は col から効かない）ので、セルごとに書く。
    ///
    def alignAttr(fields: Map[String, Json]): String =
        attrString("align", fields) |> Option.filter(align -> List.memberOf(align, cellAligns()))
            |> Option.map(align -> " style=\"text-align: ${align}\"") |> Option.getWithDefault("")

    def spanAttrs(fields: Map[String, Json]): String =
        spanAttr("colspan", fields) ++ spanAttr("rowspan", fields)

    def spanAttr(name: String, fields: Map[String, Json]): String =
        attrInt(name, fields) |> Option.filter(count -> count > 1)
            |> Option.map(count -> " ${name}=\"${count}\"") |> Option.getWithDefault("")

    def attrInt(name: String, fields: Map[String, Json]): Option[Int32] =
        Map.get(name, attrs(fields)) |> Option.flatMap(EntryValue.asInt32)

}
