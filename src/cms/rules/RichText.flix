///
/// richText の中身。ProseMirror の doc 形式（TipTap 互換）を正として保存し、コンテンツ API で HTML・平文・目次・抜粋にする。全部純粋。
///
/// 形: `{ type: "doc", content: [node] }`。node は `{ type, attrs?, content?, marks?, text? }`。
/// 許すノードとマークはホワイトリストで、知らない物は invalid にする（後から足すのは易しく、外すのは既存の entry が壊れる）。
///
/// HTML には class を付けない。サイト側が `.prose h2` のように親で当てる。種類の区別が要る所（callout / embed）は data 属性。
///
mod RichText {

    use Util.Json.Json

    /// 子（content）を持てるノード。table > tableRow > tableCell / tableHeader > paragraph。callout の中は段落など。
    pub def containerNodes(): List[String] =
        "paragraph" :: "heading" :: "bulletList" :: "orderedList" :: "listItem" :: "blockquote" :: "codeBlock" ::
        "table" :: "tableRow" :: "tableCell" :: "tableHeader" :: "callout" :: Nil

    /// 子を持たないノード。image は attrs.assetId で asset を、embed は attrs.url で外部の動画や投稿を指す。
    pub def leafNodes(): List[String] = "text" :: "hardBreak" :: "horizontalRule" :: "image" :: "embed" :: Nil

    /// text に付けられるマーク。link は attrs.href（外部）か attrs.entryId（この CMS の entry）。
    pub def markNames(): List[String] = "bold" :: "italic" :: "strike" :: "underline" :: "code" :: "link" :: Nil

    /// callout の種類。html では data-kind に出る。
    pub def calloutKinds(): List[String] = "note" :: "tip" :: "warning" :: Nil

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
            case Some(name) if List.memberOf(name, containerNodes()) => checkChildren(path, fields)
            case Some(name) if List.memberOf(name, leafNodes()) => Nil
            case Some(name) => Violation.Violation(path, "知らないノード '${name}' です（${List.join(", ", containerNodes() ::: leafNodes())}）") :: Nil
        }
        case _ => Violation.Violation(path, "ノードはオブジェクトにしてください") :: Nil
    }

    /// text ノード。text は文字列、marks は許可リストの物だけ。
    def checkText(path: String, fields: Map[String, Json]): List[Violation] =
        let textCheck = match Map.get("text", fields) |> Option.flatMap(EntryValue.asString) {
            case Some(_) => Nil
            case None    => Violation.Violation(path, "text ノードには文字列の text が要ります") :: Nil
        };
        textCheck ::: (marksOf(fields) |> List.zipWithIndex |> List.flatMap(match (index, mark) -> checkMark("${path}.marks[${index}]", mark)))

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

    /// codeBlock。attrs.language は任意で、あれば小文字英数字と `+ # -`。
    def checkCodeBlock(path: String, fields: Map[String, Json]): List[Violation] = match Map.get("language", attrs(fields)) {
        case None => Nil
        case Some(Json.JString(language)) if isLanguage(language) => Nil
        case Some(_) => Violation.Violation(path, "codeBlock の attrs.language は小文字英数字と + # - を 1 〜 32 文字にしてください") :: Nil
    }

    /// callout。attrs.kind は note / tip / warning。
    def checkCallout(path: String, fields: Map[String, Json]): List[Violation] = match attrString("kind", fields) {
        case Some(kind) if List.memberOf(kind, calloutKinds()) => Nil
        case _ => Violation.Violation(path, "callout の attrs.kind は ${List.join(" / ", calloutKinds())} にしてください") :: Nil
    }

    /// image ノード。attrs.assetId は asset の id。alt と caption は任意の文字列。
    def checkImage(path: String, fields: Map[String, Json]): List[Violation] = match attrString("assetId", fields) |> Option.flatMap(AssetId.parse) {
        case Some(_) => Nil
        case None    => Violation.Violation(path, "image の attrs.assetId は asset の id にしてください") :: Nil
    }

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
    pub def isSafeHref(href: String): Bool =
        String.startsWith(prefix = "https://", href) or String.startsWith(prefix = "http://", href) or String.startsWith(prefix = "mailto:", href)

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
    /// image が指す asset の id。重複を除く。規則に合わない物は捨てる（検査が先に止める）。
    ///
    pub def assetIds(doc: Json): List[AssetId] =
        nodes(doc) |> List.filter(fields -> typeOf(fields) == Some("image")) |> List.filterMap(attrString("assetId")) |> List.filterMap(AssetId.parse) |> List.distinct

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
    /// HTML にする。images は image の asset id → 配信 URL と寸法。無い asset の image は出さない。文字は全部エスケープする。
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
                case Some("listItem")       => "<li>${inner()}</li>"
                case Some("blockquote")     => "<blockquote>${inner()}</blockquote>"
                case Some("codeBlock")      =>
                    let language = attrString("language", fields) |> Option.filter(isLanguage) |> Option.map(found -> " class=\"language-${found}\"") |> Option.getWithDefault("");
                    "<pre><code${language}>${inner()}</code></pre>"
                case Some("table")          => "<table>${inner()}</table>"
                case Some("tableRow")       => "<tr>${inner()}</tr>"
                case Some("tableCell")      => "<td>${inner()}</td>"
                case Some("tableHeader")    => "<th>${inner()}</th>"
                case Some("callout")        => "<aside data-kind=\"${escape(attrString("kind", fields) |> Option.getWithDefault("note"))}\">${inner()}</aside>"
                case Some("horizontalRule") => "<hr>"
                case Some("hardBreak")      => "<br>"
                case Some("image")          => imageHtml(images, fields)
                case Some("embed")          => embedHtml(fields)
                case _                      => inner()
            }
        case _ => ""
    }

    /// image。caption があれば figure で包む。
    def imageHtml(images: Map[AssetId, ImageRef], fields: Map[String, Json]): String =
        match attrString("assetId", fields) |> Option.flatMap(AssetId.parse) |> Option.flatMap(id -> Map.get(id, images)) {
            case Some(image) =>
                let size = match (image#width, image#height) {
                    case (Some(width), Some(height)) => " width=\"${width}\" height=\"${height}\""
                    case _                           => ""
                };
                let img = "<img src=\"${escape(image#url)}\" alt=\"${escape(attrString("alt", fields) |> Option.getWithDefault(""))}\"${size}>";
                match attrString("caption", fields) |> Option.filter(caption -> not String.isEmpty(caption)) {
                    case Some(caption) => "<figure>${img}<figcaption>${escape(caption)}</figcaption></figure>"
                    case None          => img
                }
            case None => ""
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
