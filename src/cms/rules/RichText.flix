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

    /// codeBlock。attrs.language は任意で、あれば小文字英数字と `+ # -`。
    def checkCodeBlock(path: String, fields: Map[String, Json]): List[Violation] = match Map.get("language", attrs(fields)) {
        case None => Nil
        case Some(Json.JString(language)) if isLanguage(language) => Nil
        case Some(_) => Violation.Violation(path, "codeBlock の attrs.language は小文字英数字と + # - を 1 〜 32 文字にしてください") :: Nil
    }

    /// 見出しの id に許す形。
    pub def isHeadingId(id: String): Bool = String.isMatch(regex = "^[A-Za-z0-9_-]{1,64}$", id)

    /// コードの言語名に許す形（ts / c++ / c# / objective-c）。
    pub def isLanguage(language: String): Bool = String.isMatch(regex = "^[a-z0-9+#-]{1,32}$", language)

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
    /// HTML にする。images は image の asset id → 配信 URL と寸法。無い asset の image は出さない。文字は全部エスケープする。
    /// 見出しには headings と同じ id が付く。class は付けない（サイト側が `.prose h2` のように親で当てる）。
    ///
    pub def toHtml(images: Map[AssetId, ImageRef], doc: Json): String = htmlOf(images, withHeadingIds(doc))

    def htmlOf(urls: Map[AssetId, ImageRef], node: Json): String = match node {
        case Json.JObject(fields) =>
            let inner = () -> children(fields) |> List.map(htmlOf(urls)) |> List.join("");
            match typeOf(fields) {
                case Some("text")           => applyMarks(marksOf(fields), escape(Map.get("text", fields) |> Option.flatMap(EntryValue.asString) |> Option.getWithDefault("")))
                case Some("paragraph")      => "<p>${inner()}</p>"
                case Some("heading")        =>
                    let level = attrInt("level", fields) |> Option.getWithDefault(1);
                    let id = attrString("id", fields) |> Option.map(found -> " id=\"${escape(found)}\"") |> Option.getWithDefault("");
                    "<h${level}${id}>${inner()}</h${level}>"
                case Some("bulletList")     => "<ul>${inner()}</ul>"
                case Some("orderedList")    => "<ol>${inner()}</ol>"
                case Some("listItem")       => "<li>${inner()}</li>"
                case Some("blockquote")     => "<blockquote>${inner()}</blockquote>"
                case Some("codeBlock")      =>
                    let language = attrString("language", fields) |> Option.filter(isLanguage) |> Option.map(found -> " class=\"language-${found}\"") |> Option.getWithDefault("");
                    "<pre><code${language}>${inner()}</code></pre>"
                case Some("horizontalRule") => "<hr>"
                case Some("hardBreak")      => "<br>"
                case Some("image")          => imageHtml(urls, fields)
                case _                      => inner()
            }
        case _ => ""
    }

    def imageHtml(images: Map[AssetId, ImageRef], fields: Map[String, Json]): String =
        match attrString("assetId", fields) |> Option.flatMap(AssetId.parse) |> Option.flatMap(id -> Map.get(id, images)) {
            case Some(image) =>
                let size = match (image#width, image#height) {
                    case (Some(width), Some(height)) => " width=\"${width}\" height=\"${height}\""
                    case _                           => ""
                };
                "<img src=\"${escape(image#url)}\" alt=\"${escape(attrString("alt", fields) |> Option.getWithDefault(""))}\"${size}>"
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
