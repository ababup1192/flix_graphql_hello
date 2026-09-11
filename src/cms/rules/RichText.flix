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
///   table / tableRow / tableCell / tableHeader / callout(kind) / image（中は imageItem）/ imageItem /
///   gallery（読む側だけの互換。中は古い形の image だけ）/ details(summary) / quoteCite（blockquote の最後の子だけ）
/// - leaf: text(marks) / hardBreak / horizontalRule / embed(url) / linkCard(url) / mathBlock(tex) / video(assetId, caption, poster)
/// - image は 1 枚でも複数枚でも同じノードで、content は `imageItem` の 1 つ以上の並び。
///   imageItem が 1 枚ぶんで、attrs(assetId, alt, width, height, source, sourceUrl, href, size, align) と、content にその画像のキャプション。
///   キャプションも縮小も配置も 1 枚ぶんの物なので imageItem が持ち、image 自体は attrs を持たない。列数は持たない（枚数から決まる）
/// - キャプション（imageItem の content）は text with marks。マークは captionMarkNames の物だけ、hardBreak は無し
/// - 古い doc は読む側だけで受け付ける: attrs.assetId を持つ image は 1 枚の image と同じ（content はその画像のキャプション）、
///   attrs.caption は content が無い時のキャプション、gallery は中の image を並べた image と同じ（attrs.columns は捨てる）
/// - 引用の出典も同じ形で、blockquote の content の最後に置く quoteCite の中身（text with marks。マークは captionMarkNames の物だけ）。
///   古い doc の attrs.cite / citeUrl は読む側だけで受け付ける（quoteCite が無い時に text 1 つ、citeUrl があればその文字に link マークを掛けた物として扱う）
/// - mark: bold / italic / strike / underline / code / link(href | entryId) / math（text が TeX。他のマークと混ぜない）/ sub / sup（重ねない）/ highlight
///
/// 入れ子は許さない: 表のセルの中は段落だけ、引用の中に引用は入らない。リストの入れ子だけは Markdown で往復するので残す。
///
/// 数式は TeX のまま持ち、HTML は data-math の span / div（描画は KaTeX をサイト側で）。codeBlock の language が mermaid なら pre に data-diagram（描画は Mermaid をサイト側で）。
///
mod RichText {

    use Util.Json.Json

    /// 子（content）を持てるノード。table > tableRow > tableCell / tableHeader > paragraph。callout と details の中は段落など。
    /// image の中は imageItem で、imageItem の中は text。gallery（古い形）の中は image だけ。
    /// quoteCite は blockquote の最後の子だけで、中は text。
    pub def containerNodes(): List[String] =
        "paragraph" :: "heading" :: "bulletList" :: "orderedList" :: "listItem" :: "blockquote" :: "quoteCite" :: "codeBlock" ::
        "table" :: "tableRow" :: "tableCell" :: "tableHeader" :: "callout" :: "image" :: "imageItem" :: "gallery" :: "details" :: Nil

    /// 子を持たないノード。video は attrs.assetId で asset を、embed は attrs.url で外部の動画や投稿を、linkCard は attrs.url で任意のページを指す。mathBlock は attrs.tex。
    pub def leafNodes(): List[String] = "text" :: "hardBreak" :: "horizontalRule" :: "embed" :: "linkCard" :: "mathBlock" :: "video" :: Nil

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

    ///
    /// image のキャプションと引用の出典（content の text）に付けられるマーク。
    ///
    /// WhyNot: underline / math / sub / sup / highlight を入れない。Markdown ではキャプションを `*…*` の 1 行に写すので、
    /// 行の中で閉じられる印だけに絞る。要る時に足すのは易しく、外すのは既存の entry が壊れる。
    ///
    pub def captionMarkNames(): List[String] = "bold" :: "italic" :: "strike" :: "code" :: "link" :: Nil

    /// callout の種類。html では data-kind に出る。
    pub def calloutKinds(): List[String] = "note" :: "tip" :: "warning" :: Nil

    ///
    /// 表のセルの寄せ。html では style の text-align、Markdown では区切り行の `:`。
    /// **列の属性**なので、画面は列の全セルに同じ値を入れる（Markdown の区切り行が列に 1 つしか持てない）。
    ///
    pub def cellAligns(): List[String] = "left" :: "center" :: "right" :: Nil

    ///
    /// image の attrs.size に許す値。無ければ本文の幅いっぱい。html では figure（無ければ img）の data-size。
    ///
    /// WhyNot: 段階を 1 つしか持たない。幅の数値や 3 段階にすると、見た目の決めが本文に埋まり、
    /// サイトのリニューアルと狭い画面で崩れる（文字色を持たないのと同じ理由）。「小さくしたい」の意図だけを渡す。
    ///
    pub def imageSizes(): List[String] = "small" :: Nil

    ///
    /// image の attrs.align に許す値。無ければ中央。html では figure（無ければ img）の data-align。
    ///
    /// WhyNot: "center" を値に持たない。既定が中央なので、値があると「無い」と「center」の 2 通りが同じ見た目になり、往復で揺れる。
    ///
    pub def imageAligns(): List[String] = "left" :: "right" :: Nil

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
            case Some("imageItem") => Violation.Violation(path, "imageItem は image の中にだけ置けます") :: Nil
            case Some("embed") => checkEmbed(path, fields)
            case Some("gallery") => checkGallery(path, fields)
            case Some("linkCard") => checkLinkCard(path, fields)
            case Some("details") => checkDetails(path, fields) ::: checkChildren(path, fields)
            case Some("listItem") => checkListItem(path, fields) ::: checkChildren(path, fields)
            case Some("tableCell") => checkTableCell(path, fields) ::: checkCellChildren(path, fields) ::: checkChildren(path, fields)
            case Some("tableHeader") => checkTableCell(path, fields) ::: checkCellChildren(path, fields) ::: checkChildren(path, fields)
            case Some("blockquote") => checkQuoteCite(path, fields) ::: checkQuoteChildren(path, fields)
            case Some("quoteCite") => Violation.Violation(path, "出典（quoteCite）は引用（blockquote）の最後の子にだけ置けます") :: Nil
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

    /// codeBlock。attrs.language / fileName / highlightLines / wrap はどれも任意で、あれば形を見る。
    def checkCodeBlock(path: String, fields: Map[String, Json]): List[Violation] =
        checkOptionalString(path, "language", isLanguage, "codeBlock の attrs.language は小文字英数字と + # - を 1 〜 32 文字にしてください", fields)
            ::: checkOptionalString(path, "fileName", isFileName, "codeBlock の attrs.fileName はパスの文字（英数字・日本語・/ . _ -）を 1 〜 200 文字にしてください", fields)
            ::: checkOptionalString(path, "highlightLines", isHighlightLines, "codeBlock の attrs.highlightLines は 1,3-5 の形にしてください", fields)
            ::: checkOptionalBool(path, "wrap", "codeBlock の attrs.wrap は true / false にしてください", fields)

    /// 任意の真偽値の attr。無ければ通り、あれば真偽値である事。
    def checkOptionalBool(path: String, name: String, message: String, fields: Map[String, Json]): List[Violation] =
        match Map.get(name, attrs(fields)) {
            case None              => Nil
            case Some(Json.JBool(_)) => Nil
            case Some(_)           => Violation.Violation(path, message) :: Nil
        }

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
    /// 引用の子。最後の 1 つだけ quoteCite（出典）になれて、中は text だけ。他は普通のブロックで、引用の中に引用は入れない。
    ///
    /// WhyNot: `>>` は Markdown で書けるが、深さに意味を持たせる書き方が定まらない。
    /// 引用の引用は元の出典が二重になるだけで、読む側には 1 段の引用と区別が付かない。
    ///
    def checkQuoteChildren(path: String, fields: Map[String, Json]): List[Violation] =
        let lastIndex = List.length(children(fields)) - 1;
        children(fields) |> List.zipWithIndex |> List.flatMap(match (index, child) ->
            let childPath = "${path}.content[${index}]";
            match nodeType(child) {
                case Some("quoteCite") =>
                    if (index == lastIndex) checkQuoteCiteChild(childPath, child)
                    else Violation.Violation(childPath, "出典（quoteCite）は引用の最後に置いてください") :: Nil
                case Some("blockquote") => Violation.Violation(childPath, "引用の中に引用は入れられません") :: Nil
                case _                  => checkNode(childPath, child)
            })

    /// quoteCite の中身。image のキャプションと同じで、text だけ・マークは captionMarkNames の物だけ。
    def checkQuoteCiteChild(path: String, child: Json): List[Violation] = match child {
        case Json.JObject(fields) => checkInlineChildren("引用の出典", path, fields)
        case _                    => Violation.Violation(path, "ノードはオブジェクトにしてください") :: Nil
    }

    def checkTableCell(path: String, fields: Map[String, Json]): List[Violation] = match Map.get("align", attrs(fields)) {
        case None    => Nil
        case Some(found) =>
            if (EntryValue.asString(found) |> Option.exists(align -> List.memberOf(align, cellAligns()))) Nil
            else Violation.Violation(path, "セルの attrs.align は ${List.join(" / ", cellAligns())} にしてください") :: Nil
    }

    ///
    /// image ノード。content は imageItem の 1 つ以上の並び。
    /// attrs.assetId のある古い形は 1 枚の image として読む側だけで受ける。
    ///
    def checkImage(path: String, fields: Map[String, Json]): List[Violation] =
        if (Option.nonEmpty(attrString("assetId", fields))) checkPicture("image", path, fields)
        else checkImageChildren(path, fields)

    /// image の子。imageItem が 1 つ以上。
    def checkImageChildren(path: String, fields: Map[String, Json]): List[Violation] =
        let emptyCheck =
            if (List.isEmpty(children(fields)))
                Violation.Violation(path, "image には画像（imageItem）を 1 つ以上入れてください") :: Nil
            else Nil;
        emptyCheck ::: (children(fields) |> List.zipWithIndex |> List.flatMap(match (index, child) ->
            let childPath = "${path}.content[${index}]";
            match child {
                case Json.JObject(item) if typeOf(item) == Some("imageItem") => checkPicture("imageItem", childPath, item)
                case _ => Violation.Violation(childPath, "image の中は imageItem だけにしてください") :: Nil
            }))

    ///
    /// 画像 1 枚ぶん（imageItem と、古い形の image と gallery の中の image）。
    /// attrs.assetId は asset の id。alt / caption / source は任意の文字列、sourceUrl / href は任意で http(s)、size / align は任意で決まった値。
    /// content はキャプションで、text（captionMarkNames のマークだけ）の並び。what は違反の文に出すノードの名前。
    ///
    def checkPicture(what: String, path: String, fields: Map[String, Json]): List[Violation] =
        let assetIdCheck = match attrString("assetId", fields) |> Option.flatMap(AssetId.parse) {
            case Some(_) => Nil
            case None    => Violation.Violation(path, "${what} の attrs.assetId は asset の id にしてください") :: Nil
        };
        assetIdCheck
            ::: checkInlineChildren("画像のキャプション", path, fields)
            ::: checkOptionalString(path, "alt", _ -> true, "${what} の attrs.alt は文字列にしてください", fields)
            ::: checkOptionalString(path, "caption", _ -> true, "${what} の attrs.caption は文字列にしてください", fields)
            ::: checkOptionalString(path, "source", _ -> true, "${what} の attrs.source は文字列にしてください", fields)
            ::: checkOptionalString(path, "sourceUrl", isOptionalHttpUrl, "${what} の attrs.sourceUrl は http(s):// にしてください", fields)
            ::: checkOptionalString(path, "href", isOptionalHttpUrl, "${what} の attrs.href は http(s):// にしてください", fields)
            ::: checkOptionalString(path, "size", isOptionalOneOf(imageSizes()), "${what} の attrs.size は ${List.join(" / ", imageSizes())} にしてください", fields)
            ::: checkOptionalString(path, "align", isOptionalOneOf(imageAligns()), "${what} の attrs.align は ${List.join(" / ", imageAligns())} にしてください", fields)

    /// image のキャプションと引用の出典。content の子は text だけで、マークは captionMarkNames の物だけ。what は違反の文に出す物の名前。
    def checkInlineChildren(what: String, path: String, fields: Map[String, Json]): List[Violation] =
        children(fields) |> List.zipWithIndex |> List.flatMap(match (index, child) -> checkInlineChild(what, "${path}.content[${index}]", child))

    def checkInlineChild(what: String, path: String, child: Json): List[Violation] = match child {
        case Json.JObject(fields) if typeOf(fields) == Some("text") =>
            checkText(path, fields)
                ::: (marksOf(fields) |> List.filterMap(typeOf) |> List.filter(name -> not List.memberOf(name, captionMarkNames()))
                    |> List.map(name -> Violation.Violation(path, "${what}に '${name}' は付けられません（${List.join(", ", captionMarkNames())}）")))
        case _ => Violation.Violation(path, "${what}（content）は text だけにしてください") :: Nil
    }

    /// 空文字は「無い」と同じなので通す。
    def isOptionalOneOf(allowed: List[String], value: String): Bool = String.isEmpty(value) or List.memberOf(value, allowed)

    /// blockquote の旧い出典。attrs.cite は任意の文字列、citeUrl は任意で http(s)。書き出しは quoteCite だけで、これは読む側の互換。
    def checkQuoteCite(path: String, fields: Map[String, Json]): List[Violation] =
        checkOptionalString(path, "cite", _ -> true, "blockquote の attrs.cite は文字列にしてください", fields)
            ::: checkOptionalString(path, "citeUrl", isOptionalHttpUrl, "blockquote の attrs.citeUrl は http(s):// にしてください", fields)

    /// 空文字は「無い」と同じなので通す。
    def isOptionalHttpUrl(url: String): Bool = String.isEmpty(url) or isHttpUrl(url)

    /// gallery（読む側だけの互換）。attrs.columns は任意で 2 〜 4。中は 1 つ以上の image だけ。
    def checkGallery(path: String, fields: Map[String, Json]): List[Violation] =
        let columnsCheck = match Map.get("columns", attrs(fields)) {
            case None => Nil
            case Some(found) if Option.exists(isGalleryColumns, EntryValue.asInt32(found)) => Nil
            case Some(_) => Violation.Violation(path, "gallery の attrs.columns は ${minGalleryColumns()} 〜 ${maxGalleryColumns()} にしてください") :: Nil
        };
        let emptyCheck = if (List.isEmpty(children(fields))) Violation.Violation(path, "gallery には image を 1 つ以上入れてください") :: Nil else Nil;
        columnsCheck ::: emptyCheck ::: (children(fields) |> List.zipWithIndex |> List.flatMap(match (index, child) -> checkGalleryChild("${path}.content[${index}]", child)))

    def checkGalleryChild(path: String, child: Json): List[Violation] = match child {
        case Json.JObject(fields) if typeOf(fields) == Some("image") => checkPicture("image", path, fields)
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

    ///
    /// linkCard が指す url（http(s) だけ）。重複を除く。公開の HTML の `cards` を表から引くのに使う。
    ///
    pub def linkCardUrls(doc: Json): List[String] =
        nodes(doc) |> List.filterMap(fields -> if (typeOf(fields) == Some("linkCard")) attrString("url", fields) |> Option.filter(isHttpUrl) else None) |> List.distinct

    /// 1 ノードが指す asset の id の文字列。
    def nodeAssetIds(fields: Map[String, Json]): List[String] = match typeOf(fields) {
        case Some("image")     => attrString("assetId", fields) |> Option.toList
        case Some("imageItem") => attrString("assetId", fields) |> Option.toList
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
            case Some("image")     => picturesText(fields)
            case Some("gallery")   => picturesText(fields)
            case Some("blockquote") =>
                (quoteBody(fields) |> List.map(textOf) |> List.join(""))
                    ++ (quoteCiteText(fields) |> Option.map(cite -> "— ${cite}\n") |> Option.getWithDefault(""))
                    ++ "\n"
            case Some("linkCard")  => (attrString("url", fields) |> Option.getWithDefault("")) ++ "\n"
            case Some("details")   => (attrString("summary", fields) |> Option.getWithDefault("")) ++ "\n" ++ childrenText(fields)
            case Some("mathBlock") => (attrString("tex", fields) |> Option.getWithDefault("")) ++ "\n"
            case Some(name) if List.memberOf(name, containerNodes()) => childrenText(fields) ++ "\n"
            case _                 => childrenText(fields)
        }
        case _ => ""
    }

    ///
    /// image（と古い gallery）の平文。2 枚以上の時だけ、画像ごとのキャプションを 1 行ずつ出す。
    ///
    /// WhyNot: 1 枚の時に出さない。単独の画像のキャプションは本文の続きではなく、抜粋に混ざると文が途切れて読める。
    ///
    def picturesText(fields: Map[String, Json]): String =
        let items = pictureItems(fields);
        if (List.length(items) <= 1) ""
        else items |> List.filterMap(pictureText) |> List.map(caption -> caption ++ "\n") |> List.join("")

    /// 画像 1 枚の caption（平文）と source を空白 1 つで繋いだ物。どちらも無ければ None。
    def pictureText(fields: Map[String, Json]): Option[String] =
        joinNonEmpty(captionText(fields), nonEmptyAttr("source", fields))

    ///
    /// image の画像の並び。imageItem の並びで、古い形（attrs.assetId のある image）はそれ自身が 1 枚、gallery は中の image。
    ///
    def pictureItems(fields: Map[String, Json]): List[Map[String, Json]] =
        if (typeOf(fields) == Some("gallery")) childFields(fields) |> List.filter(child -> typeOf(child) == Some("image"))
        else if (Option.nonEmpty(attrString("assetId", fields))) fields :: Nil
        else childFields(fields) |> List.filter(child -> typeOf(child) == Some("imageItem"))

    def childFields(fields: Map[String, Json]): List[Map[String, Json]] =
        children(fields) |> List.filterMap(child -> match child {
            case Json.JObject(found) => Some(found)
            case _                   => None
        })

    ///
    /// 引用の出典の inline。content の最後の quoteCite があればその子、無ければ旧 attrs.cite / citeUrl を text 1 つに写す
    /// （citeUrl があればその文字に link マークを掛ける）。どちらも無ければ空。
    ///
    def quoteCiteInlines(fields: Map[String, Json]): List[Json] = match quoteCiteNode(fields) {
        case Some(cite) => children(cite)
        case None       => legacyCiteInlines(nonEmptyAttr("cite", fields), nonEmptyAttr("citeUrl", fields) |> Option.filter(isHttpUrl))
    }

    /// 旧 attrs の出典を text 1 つに。文字が無ければ URL を文字として出す。
    def legacyCiteInlines(text: Option[String], url: Option[String]): List[Json] = match (text, url) {
        case (Some(found), Some(href)) => linkedTextNode(href, found) :: Nil
        case (None, Some(href))        => linkedTextNode(href, href) :: Nil
        case (Some(found), None)       => Json.JObject(Map#{ "type" => Json.JString("text"), "text" => Json.JString(found) }) :: Nil
        case (None, None)              => Nil
    }

    def linkedTextNode(href: String, text: String): Json =
        Json.JObject(Map#{
            "type" => Json.JString("text"),
            "text" => Json.JString(text),
            "marks" => Json.JArray(Vector#{ Json.JObject(Map#{ "type" => Json.JString("link"), "attrs" => Json.JObject(Map#{ "href" => Json.JString(href) }) }) })
        })

    /// content の最後に置かれた quoteCite。
    def quoteCiteNode(fields: Map[String, Json]): Option[Map[String, Json]] =
        children(fields) |> List.reverse |> List.head |> Option.flatMap(child -> match child {
            case Json.JObject(found) if typeOf(found) == Some("quoteCite") => Some(found)
            case _                                                         => None
        })

    /// 引用の本文。出典の quoteCite を除いた子。
    def quoteBody(fields: Map[String, Json]): List[Json] =
        children(fields) |> List.filter(child -> nodeType(child) != Some("quoteCite"))

    /// 引用の出典の平文。quoteCite があればその text を繋ぎ、無ければ旧 attrs.cite。空なら None。URL は出さない。
    def quoteCiteText(fields: Map[String, Json]): Option[String] = match quoteCiteNode(fields) {
        case Some(cite) => Some(childrenText(cite)) |> Option.filter(String.nonEmpty)
        case None       => nonEmptyAttr("cite", fields)
    }

    /// image のキャプションの平文。content があればその text を繋ぎ、無ければ attrs.caption。空なら None。
    def captionText(fields: Map[String, Json]): Option[String] =
        if (List.isEmpty(children(fields))) nonEmptyAttr("caption", fields)
        else Some(childrenText(fields)) |> Option.filter(String.nonEmpty)

    /// 空でない文字列の attr。空文字は無いのと同じ。
    def nonEmptyAttr(name: String, fields: Map[String, Json]): Option[String] =
        attrString(name, fields) |> Option.filter(String.nonEmpty)

    /// ある物だけを空白 1 つで繋ぐ。どちらも無ければ None。
    def joinNonEmpty(first: Option[String], second: Option[String]): Option[String] =
        Some(List.join(" ", (first |> Option.toList) ::: (second |> Option.toList))) |> Option.filter(String.nonEmpty)

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
    /// cards は linkCard の url → OGP（表にある物だけ）。無い url は URL だけの a になる。
    ///
    pub def toHtml(images: Map[AssetId, ImageRef], paths: Map[EntryId, String], cards: Map[String, CardRef], doc: Json): String = htmlOf({ images = images, paths = paths, cards = cards }, withHeadingIds(doc))

    ///
    /// linkCard の OGP（`<a data-link-card>` の中身）。表の行から公開の HTML に出せる物だけ。
    ///
    /// - title: 必ずある（無い行はカードにしない）
    /// - description / imageUrl / siteName: 無ければ出ない。site の文字は siteName、無ければ url のホスト
    ///
    pub type alias CardRef = { title = String, description = Option[String], imageUrl = Option[String], siteName = Option[String] }

    /// toHtml が持ち回る写し。images は asset、paths は entry のリンク先、cards は linkCard の OGP。
    type alias Refs = { images = Map[AssetId, ImageRef], paths = Map[EntryId, String], cards = Map[String, CardRef] }

    def htmlOf(refs: Refs, node: Json): String = match node {
        case Json.JObject(fields) =>
            let images = refs#images;
            let paths = refs#paths;
            let inner = () -> children(fields) |> List.map(htmlOf(refs)) |> List.join("");
            match typeOf(fields) {
                case Some("text")           => applyMarks(paths, marksOf(fields), escape(Map.get("text", fields) |> Option.flatMap(EntryValue.asString) |> Option.getWithDefault("")))
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
                case Some("blockquote")     =>
                    let body = quoteBody(fields) |> List.map(htmlOf(refs)) |> List.join("");
                    match quoteCiteHtml(refs, fields) {
                        case Some(cite) => "<figure data-quote><blockquote>${body}</blockquote><figcaption>${cite}</figcaption></figure>"
                        case None       => "<blockquote>${body}</blockquote>"
                    }
                case Some("codeBlock")      =>
                    let language = attrString("language", fields) |> Option.filter(isLanguage) |> Option.map(found -> " class=\"language-${found}\"") |> Option.getWithDefault("");
                    let diagram = attrString("language", fields) |> Option.filter(found -> found == diagramLanguage()) |> Option.map(found -> " data-diagram=\"${found}\"") |> Option.getWithDefault("");
                    let fileName = attrString("fileName", fields) |> Option.filter(isFileName) |> Option.map(found -> " data-file-name=\"${escape(found)}\"") |> Option.getWithDefault("");
                    let highlightLines = attrString("highlightLines", fields) |> Option.filter(isHighlightLines) |> Option.map(found -> " data-highlight-lines=\"${found}\"") |> Option.getWithDefault("");
                    let wrap = Map.get("wrap", attrs(fields)) |> Option.flatMap(EntryValue.asBool) |> Option.filter(found -> found) |> Option.map(_ -> " data-wrap") |> Option.getWithDefault("");
                    "<pre${diagram}${fileName}${highlightLines}${wrap}><code${language}>${inner()}</code></pre>"
                case Some("table")          => tableHtml(refs, fields)
                case Some("tableRow")       => "<tr>${inner()}</tr>"
                case Some("tableCell")      => "<td${spanAttrs(fields)}${alignAttr(fields)}>${inner()}</td>"
                case Some("tableHeader")    => "<th${spanAttrs(fields)}${alignAttr(fields)}>${inner()}</th>"
                case Some("callout")        => "<aside data-kind=\"${escape(attrString("kind", fields) |> Option.getWithDefault("note"))}\">${inner()}</aside>"
                case Some("horizontalRule") => "<hr>"
                case Some("hardBreak")      => "<br>"
                case Some("image")          => picturesHtml(refs, fields)
                case Some("embed")          => embedHtml(fields)
                case Some("gallery")        => picturesHtml(refs, fields)
                case Some("linkCard")       => linkCardHtml(refs#cards, fields)
                case Some("details")        => "<details><summary>${escape(attrString("summary", fields) |> Option.getWithDefault(""))}</summary>${inner()}</details>"
                case Some("mathBlock")      => "<div data-math=\"block\">${escape(attrString("tex", fields) |> Option.getWithDefault(""))}</div>"
                case Some("video")          => videoHtml(images, fields)
                case _                      => inner()
            }
        case _ => ""
    }

    ///
    /// image（と古い gallery）。1 枚なら今までの image と同じ figure / img、2 枚以上なら `figure data-gallery="枚数"` で包む。
    /// data-gallery は枚数で、並べ方（列数・折り返し・横スクロール）はサイト側の CSS が決める。
    ///
    /// WhyNot: 列数を出さない。列数を本文に埋めると、狭い画面と別のデザインで崩れる（文字色を持たないのと同じ理由）。
    ///
    def picturesHtml(refs: Refs, fields: Map[String, Json]): String =
        let parts = pictureItems(fields) |> List.filterMap(imageParts(refs));
        match parts {
            case Nil           => ""
            case single :: Nil => pictureHtml(single)
            case _             => "<figure data-gallery=\"${List.length(parts)}\">${parts |> List.map(pictureHtml) |> List.join("")}</figure>"
        }

    ///
    /// 画像 1 枚。caption か source があれば figure で包み、size / align は figure に付ける。
    /// figure が無い時は img に付ける（href だけなら `<a><img></a>`）。
    ///
    /// WhyNot: href だけの時に figure を作らない。中身が img 1 つの figure は意味が無く、
    /// サイト側の `figure` の CSS（余白・キャプションの下線）が空の figure にも当たる。
    ///
    def pictureHtml(parts: ImageParts): String =
        match parts#caption {
            case Some(found) => "<figure${parts#layout}>${linkedImg("", parts)}<figcaption>${found}</figcaption></figure>"
            case None        => linkedImg(parts#layout, parts)
        }

    ///
    /// image の HTML の材料。imgAttrs は img の属性（エスケープ済み）、href はリンク先、caption は figcaption の中身（caption と `<cite>`）、
    /// layout は figure か img に付ける data-size / data-align。
    ///
    type alias ImageParts = { imgAttrs = String, href = Option[String], caption = Option[String], layout = String }

    /// asset が無ければ None。caption は content（マーク付きの inline の HTML）、無ければ attrs.caption をエスケープした物。
    def imageParts(refs: Refs, fields: Map[String, Json]): Option[ImageParts] =
        attrString("assetId", fields) |> Option.flatMap(AssetId.parse) |> Option.flatMap(id -> Map.get(id, refs#images)) |> Option.map(image -> {
            let size = match (image#width, image#height) {
                case (Some(width), Some(height)) => " width=\"${width}\" height=\"${height}\""
                case _                           => ""
            };
            let caption =
                if (List.isEmpty(children(fields))) nonEmptyAttr("caption", fields) |> Option.map(escape)
                else Some(children(fields) |> List.map(htmlOf(refs)) |> List.join("")) |> Option.filter(found -> String.nonEmpty(String.trim(found)));
            let cite = citeHtml(nonEmptyAttr("source", fields), nonEmptyAttr("sourceUrl", fields) |> Option.filter(isHttpUrl));
            {
                imgAttrs = "src=\"${escape(image#url)}\" alt=\"${escape(attrString("alt", fields) |> Option.getWithDefault(""))}\"${size}",
                href = nonEmptyAttr("href", fields) |> Option.filter(isHttpUrl),
                caption = joinNonEmpty(caption, cite),
                layout = dataAttr("size", imageSizes(), fields) ++ dataAttr("align", imageAligns(), fields)
            }
        })

    /// img タグ。href があれば外部リンクと同じ a で巻く。extra は img に足す属性。
    def linkedImg(extra: String, parts: ImageParts): String =
        let img = "<img ${parts#imgAttrs}${extra}>";
        parts#href |> Option.map(href -> "<a href=\"${escape(href)}\" target=\"_blank\" rel=\"noopener noreferrer\">${img}</a>") |> Option.getWithDefault(img)

    /// 決まった値の attr を ` data-name="value"` にする。無いか許さない値なら空。
    def dataAttr(name: String, allowed: List[String], fields: Map[String, Json]): String =
        nonEmptyAttr(name, fields) |> Option.filter(value -> List.memberOf(value, allowed))
            |> Option.map(value -> " data-${name}=\"${value}\"") |> Option.getWithDefault("")

    /// 引用の出典の `<cite>`。中身は content のマーク付きの inline（link は本文と同じ a）。空なら None。
    def quoteCiteHtml(refs: Refs, fields: Map[String, Json]): Option[String] =
        Some(quoteCiteInlines(fields) |> List.map(htmlOf(refs)) |> List.join(""))
            |> Option.filter(found -> String.nonEmpty(String.trim(found)))
            |> Option.map(found -> "<cite>${found}</cite>")

    /// 出典の `<cite>`。url があれば外部リンクと同じ a で巻き、文字が無ければ url を文字として出す。どちらも無ければ None。
    def citeHtml(text: Option[String], url: Option[String]): Option[String] = match (text, url) {
        case (Some(found), Some(href)) => Some("<cite><a href=\"${escape(href)}\" target=\"_blank\" rel=\"noopener noreferrer\">${escape(found)}</a></cite>")
        case (None, Some(href))        => Some("<cite><a href=\"${escape(href)}\" target=\"_blank\" rel=\"noopener noreferrer\">${escape(href)}</a></cite>")
        case (Some(found), None)       => Some("<cite>${escape(found)}</cite>")
        case (None, None)              => None
    }

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

    ///
    /// linkCard。cards に OGP があれば title / description / site / thumbnail を span と img で出す（JavaScript も iframe も無し）。
    /// 無ければ（まだ取っていない・取れなかった）URL だけの a。見た目はサイト側。
    ///
    def linkCardHtml(cards: Map[String, CardRef], fields: Map[String, Json]): String = match attrString("url", fields) |> Option.filter(isHttpUrl) {
        case Some(url) => match Map.get(url, cards) {
            case Some(card) =>
                let description = card#description |> Option.map(found -> "<span data-description>${escape(found)}</span>") |> Option.getWithDefault("");
                let site = card#siteName |> Option.getWithDefault(Ogp.hostOf(url));
                let thumbnail = card#imageUrl |> Option.filter(isHttpUrl) |> Option.map(found -> "<img data-thumbnail src=\"${escape(found)}\" alt=\"\">") |> Option.getWithDefault("");
                "<a data-link-card href=\"${escape(url)}\" target=\"_blank\" rel=\"noopener noreferrer\"><span data-title>${escape(card#title)}</span>${description}<span data-site>${escape(site)}</span>${thumbnail}</a>"
            case None => "<a data-link-card href=\"${escape(url)}\">${escape(url)}</a>"
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
    def applyMarks(paths: Map[EntryId, String], marks: List[Map[String, Json]], text: String): String =
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
                // **型に linkPath があれば踏める href を出す。** 無ければ `#entry:{id}` のままで、
                // サイトが data-entry-id を見て差し替える。data-entry-id はどちらでも付ける。
                case (_, Some(entryId)) =>
                    let href = Map.get(entryId, paths) |> Option.getWithDefault("#entry:${EntryId.text(entryId)}");
                    "<a href=\"${escape(href)}\" data-entry-id=\"${EntryId.text(entryId)}\">${acc}</a>"
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
    def tableHtml(refs: Refs, fields: Map[String, Json]): String =
        let rows = children(fields);
        let render = list -> list |> List.map(htmlOf(refs)) |> List.join("");
        match rows {
            case Nil          => "<table></table>"
            case head :: rest =>
                if (isHeaderRow(head)) {
                    let body = if (List.isEmpty(rest)) "" else "<tbody>${render(rest)}</tbody>";
                    "<table><thead>${htmlOf(refs, head)}</thead>${body}</table>"
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
