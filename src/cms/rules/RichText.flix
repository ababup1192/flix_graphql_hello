///
/// richText の中身。ProseMirror の doc 形式（TipTap 互換）を正として保存し、コンテンツ API で HTML と平文にする。全部純粋。
///
/// 形: `{ type: "doc", content: [node] }`。node は `{ type, attrs?, content?, marks?, text? }`。
/// 許すノードとマークはホワイトリストで、知らない物は invalid にする（後から足すのは易しく、外すのは既存の entry が壊れる）。
///
mod RichText {

    use Util.Json.Json

    /// 子（content）を持てるノード。
    pub def containerNodes(): List[String] =
        "paragraph" :: "heading" :: "bulletList" :: "orderedList" :: "listItem" :: "blockquote" :: "codeBlock" :: Nil

    /// 子を持たないノード。image は attrs.assetId で asset を指す。
    pub def leafNodes(): List[String] = "text" :: "hardBreak" :: "horizontalRule" :: "image" :: Nil

    /// text に付けられるマーク。link は attrs.href。
    pub def markNames(): List[String] = "bold" :: "italic" :: "strike" :: "underline" :: "code" :: "link" :: Nil

    /// heading の level の範囲。
    pub def maxHeadingLevel(): Int32 = 4

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
            case Some("image") => checkImage(path, fields)
            case Some(name) if List.memberOf(name, containerNodes()) => checkChildren(path, fields)
            case Some(name) if List.memberOf(name, leafNodes()) => Nil
            case Some(name) => Violation.Violation(path, "知らないノード '${name}' です（${List.join(", ", containerNodes() ::: leafNodes())}）") :: Nil
        }
        case _ => Violation.Violation(path, "ノードはオブジェクトにしてください") :: Nil
    }

    /// text ノード。text は文字列、marks は許可リストの物だけ、link には http(s) / mailto の href。
    def checkText(path: String, fields: Map[String, Json]): List[Violation] =
        let textCheck = match Map.get("text", fields) |> Option.flatMap(EntryValue.asString) {
            case Some(_) => Nil
            case None    => Violation.Violation(path, "text ノードには文字列の text が要ります") :: Nil
        };
        textCheck ::: (marksOf(fields) |> List.zipWithIndex |> List.flatMap(match (index, mark) -> checkMark("${path}.marks[${index}]", mark)))

    def checkMark(path: String, mark: Map[String, Json]): List[Violation] = match typeOf(mark) {
        case Some("link") => match attrString("href", mark) {
            case Some(href) if isSafeHref(href) => Nil
            case _ => Violation.Violation(path, "link の href は http(s):// か mailto: で始めてください") :: Nil
        }
        case Some(name) if List.memberOf(name, markNames()) => Nil
        case Some(name) => Violation.Violation(path, "知らないマーク '${name}' です（${List.join(", ", markNames())}）") :: Nil
        case None => Violation.Violation(path, "マークに type がありません") :: Nil
    }

    def checkHeading(path: String, fields: Map[String, Json]): List[Violation] = match attrInt("level", fields) {
        case Some(level) if level >= 1 and level <= maxHeadingLevel() => Nil
        case _ => Violation.Violation(path, "heading の attrs.level は 1 〜 ${maxHeadingLevel()} にしてください") :: Nil
    }

    /// image ノード。attrs.assetId は asset の id。alt は任意の文字列。
    def checkImage(path: String, fields: Map[String, Json]): List[Violation] = match attrString("assetId", fields) |> Option.flatMap(AssetId.parse) {
        case Some(_) => Nil
        case None    => Violation.Violation(path, "image の attrs.assetId は asset の id にしてください") :: Nil
    }

    /// link に許す href。javascript: 等を通さない。
    pub def isSafeHref(href: String): Bool =
        String.startsWith(prefix = "https://", href) or String.startsWith(prefix = "http://", href) or String.startsWith(prefix = "mailto:", href)

    // ---- 取り出し ----

    ///
    /// image が指す asset の id。重複を除く。規則に合わない物は捨てる（検査が先に止める）。
    ///
    pub def assetIds(doc: Json): List[AssetId] =
        nodes(doc) |> List.filter(fields -> typeOf(fields) == Some("image")) |> List.filterMap(attrString("assetId")) |> List.filterMap(AssetId.parse) |> List.distinct

    ///
    /// 平文。text を繋ぎ、ブロックの終わりと hardBreak で改行する。検索と一覧の抜粋用。
    ///
    pub def toText(doc: Json): String = textOf(doc) |> String.trim

    def textOf(node: Json): String = match node {
        case Json.JObject(fields) => match typeOf(fields) {
            case Some("text")      => Map.get("text", fields) |> Option.flatMap(EntryValue.asString) |> Option.getWithDefault("")
            case Some("hardBreak") => "\n"
            case Some(name) if List.memberOf(name, containerNodes()) => childrenText(fields) ++ "\n"
            case _                 => childrenText(fields)
        }
        case _ => ""
    }

    def childrenText(fields: Map[String, Json]): String =
        children(fields) |> List.map(textOf) |> List.join("")

    // ---- HTML ----

    ///
    /// HTML にする。urls は image の asset id → 配信 URL。無い asset の image は出さない。文字は全部エスケープする。
    ///
    pub def toHtml(urls: Map[AssetId, String], doc: Json): String = htmlOf(urls, doc)

    def htmlOf(urls: Map[AssetId, String], node: Json): String = match node {
        case Json.JObject(fields) =>
            let inner = () -> children(fields) |> List.map(htmlOf(urls)) |> List.join("");
            match typeOf(fields) {
                case Some("text")           => applyMarks(marksOf(fields), escape(Map.get("text", fields) |> Option.flatMap(EntryValue.asString) |> Option.getWithDefault("")))
                case Some("paragraph")      => "<p>${inner()}</p>"
                case Some("heading")        => { let level = attrInt("level", fields) |> Option.getWithDefault(1); "<h${level}>${inner()}</h${level}>" }
                case Some("bulletList")     => "<ul>${inner()}</ul>"
                case Some("orderedList")    => "<ol>${inner()}</ol>"
                case Some("listItem")       => "<li>${inner()}</li>"
                case Some("blockquote")     => "<blockquote>${inner()}</blockquote>"
                case Some("codeBlock")      => "<pre><code>${inner()}</code></pre>"
                case Some("horizontalRule") => "<hr>"
                case Some("hardBreak")      => "<br>"
                case Some("image")          => imageHtml(urls, fields)
                case _                      => inner()
            }
        case _ => ""
    }

    def imageHtml(urls: Map[AssetId, String], fields: Map[String, Json]): String =
        match attrString("assetId", fields) |> Option.flatMap(AssetId.parse) |> Option.flatMap(id -> Map.get(id, urls)) {
            case Some(url) => "<img src=\"${escape(url)}\" alt=\"${escape(attrString("alt", fields) |> Option.getWithDefault(""))}\">"
            case None      => ""
        }

    /// マークを外側から順に巻く（先頭のマークが一番外）。
    def applyMarks(marks: List[Map[String, Json]], text: String): String =
        List.foldRight((mark, acc) -> match typeOf(mark) {
            case Some("bold")      => "<strong>${acc}</strong>"
            case Some("italic")    => "<em>${acc}</em>"
            case Some("strike")    => "<s>${acc}</s>"
            case Some("underline") => "<u>${acc}</u>"
            case Some("code")      => "<code>${acc}</code>"
            case Some("link")      => match attrString("href", mark) {
                case Some(href) if isSafeHref(href) => "<a href=\"${escape(href)}\" rel=\"noopener\">${acc}</a>"
                case _                              => acc
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

    def attrInt(name: String, fields: Map[String, Json]): Option[Int32] =
        Map.get(name, attrs(fields)) |> Option.flatMap(EntryValue.asInt32)

}
