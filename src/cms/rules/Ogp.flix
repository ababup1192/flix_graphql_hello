///
/// OGP の読み取り。HTML の文字列から og:title / og:description / og:image / og:site_name を読み、無ければ `<title>`。
/// 取りに行って良い URL か（http(s) だけ。プライベートアドレスは断る）と、取り直しの判定もここ。全部純粋。
///
/// WhyNot: HTML パーサを持ち込まないのは、要るのが `<meta>` と `<title>` の属性だけで、壊れた HTML でも
/// 落ちずに「読めた分だけ」返せれば足りるため。タグの外の文字は見ない。
///
mod Ogp {

    ///
    /// 読めた OGP。無い物は None。
    ///
    /// - title: og:title、無ければ `<title>`
    /// - description: og:description を 200 字で切った物
    /// - imageUrl: og:image。相対なら url で絶対にした物
    /// - siteName: og:site_name
    ///
    pub type alias Meta = { title = Option[String], description = Option[String], imageUrl = Option[String], siteName = Option[String] }

    /// description をここで切る（字数）。
    pub def descriptionLimit(): Int32 = 200

    /// 取り直すまでの日数（7 日）。
    pub def refreshAfterMs(): Int64 = 7i64 * 24i64 * 60i64 * 60i64 * 1000i64

    /// 失敗した行を取り直してよいまでの長さ（1 時間）。
    pub def retryErrorAfterMs(): Int64 = 60i64 * 60i64 * 1000i64

    /// 読む本文の上限（バイト）。OGP は head にあるので、先頭だけで足りる。
    pub def bodyLimitBytes(): Int32 = 512 * 1024

    /// 相手を待つ秒数。
    pub def timeoutSeconds(): Int32 = 5

    // ---- 取り直しの判定 ----

    ///
    /// 取り直す番か。成功した行は 7 日、失敗した行は 1 時間で番になる。now と fetchedAt は UNIX ミリ秒。
    ///
    pub def needsRefetch(now: Int64, fetchedAt: Int64, hasError: Bool): Bool =
        if (hasError) now - fetchedAt >= retryErrorAfterMs() else now - fetchedAt >= refreshAfterMs()

    // ---- 取りに行って良い URL か ----

    ///
    /// 取りに行かない理由。http(s) 以外と、プライベートアドレス（127.0.0.0/8、10/8、172.16/12、192.168/16、169.254/16、localhost）。
    /// 取りに行って良ければ None。
    ///
    pub def refuseReason(url: String): Option[String] =
        if (not (String.startsWith(prefix = "http://", url) or String.startsWith(prefix = "https://", url))) Some("http(s) の URL だけ取りに行けます")
        else match hostOf(url) {
            case ""   => Some("URL にホストがありません")
            case host => if (isPrivateHost(host)) Some("プライベートアドレスには取りに行きません") else None
        }

    ///
    /// URL のホスト（小文字。ポートと userinfo は除く）。読めなければ空。
    ///
    pub def hostOf(url: String): String =
        let authority = String.indexOf(substr = "://", url) |> Option.map(at -> String.dropLeft(at + 3, url)) |> Option.getWithDefault("")
            |> String.takeWhile(c -> c != '/' and c != '?' and c != '#');
        let withoutUser = String.indexOfRight(substr = "@", authority) |> Option.map(at -> String.dropLeft(at + 1, authority)) |> Option.getWithDefault(authority);
        let withoutPort = if (String.startsWith(prefix = "[", withoutUser)) String.takeWhile(c -> c != ']', withoutUser) ++ "]" else String.takeWhile(c -> c != ':', withoutUser);
        String.toLowerCase(withoutPort)

    /// localhost、ループバック、リンクローカル、RFC 1918 の範囲。
    def isPrivateHost(host: String): Bool =
        host == "localhost" or String.endsWith(suffix = ".localhost", host) or host == "[::1]" or host == "0.0.0.0"
        or (match ipv4Of(host) {
            case Some((a, b, _, _)) => a == 127 or a == 10 or a == 0 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) or (a == 169 and b == 254)
            case None               => false
        })

    /// ドット区切りの IPv4。4 つとも 0..255 の数字でなければ None。
    def ipv4Of(host: String): Option[(Int32, Int32, Int32, Int32)] =
        match String.splitOn(substr = ".", host) |> List.map(Int32.fromString) {
            case Some(a) :: Some(b) :: Some(c) :: Some(d) :: Nil =>
                if (List.forAll(n -> n >= 0 and n <= 255, List#{a, b, c, d})) Some((a, b, c, d)) else None
            case _ => None
        }

    // ---- 失敗の理由 ----

    ///
    /// HTTP のステータスから人が読む理由。2xx は理由にならないので None。
    ///
    pub def describeStatus(status: Int32): Option[String] =
        if (status >= 200 and status < 300) None
        else if (status == 401 or status == 403) Some("取得を断られました（HTTP ${status}。bot を受け付けないサイト）")
        else if (status == 404 or status == 410) Some("ページが見つかりません（HTTP ${status}）")
        else Some("取得に失敗しました（HTTP ${status}）")

    /// OGP も title も無かった時の理由。
    pub def noMetaReason(): String = "OGP も title もありません"

    /// HTML 以外が返った時の理由。
    pub def notHtmlReason(contentType: String): String = "HTML ではありません（${contentType}）"

    // ---- 読む ----

    ///
    /// HTML から OGP を読む。属性の順が逆でも、シングルクォートでも読む。og:title が無ければ `<title>`。
    /// 何も無ければ全部 None。
    ///
    pub def parse(url: String, html: String): Meta =
        let metas = metaTags(html) |> List.map(attributes);
        let property = key -> metas |> List.findMap(found -> if (propertyOf(found) == Some(key)) Map.get("content", found) |> Option.map(clean) |> Option.filter(String.nonEmpty) else None);
        {
            title = property("og:title") |> firstSome(titleTag(html)),
            description = property("og:description") |> Option.map(String.take(descriptionLimit())),
            imageUrl = property("og:image") |> Option.map(resolveUrl(url)),
            siteName = property("og:site_name")
        }

    /// first があればそれ、無ければ fallback。
    def firstSome(fallback: Option[a], first: Option[a]): Option[a] = match first {
        case Some(_) => first
        case None    => fallback
    }

    /// meta の property（無ければ name）。小文字で比べる。
    def propertyOf(found: Map[String, String]): Option[String] =
        Map.get("property", found) |> firstSome(Map.get("name", found)) |> Option.map(String.toLowerCase)

    ///
    /// `<meta ...>` のタグの中身（`<meta` の後から `>` の前まで）を全部。閉じ `>` の無い物は末尾まで。
    ///
    def metaTags(html: String): List[String] =
        String.indicesOf(substr = "<meta", String.toLowerCase(html)) |> Vector.toList |> List.map(at -> {
            let rest = String.dropLeft(at + 5, html);
            String.takeWhile(c -> c != '>', rest)
        })

    /// `<title>…</title>` の中身。無ければ None。
    def titleTag(html: String): Option[String] =
        let lowered = String.toLowerCase(html);
        String.indexOf(substr = "<title", lowered) |> Option.flatMap(start ->
            String.indexOfLeftWithOffset(substr = ">", offset = start, lowered) |> Option.map(open ->
                String.dropLeft(open + 1, html) |> String.takeWhile(c -> c != '<') |> clean)) |> Option.filter(String.nonEmpty)

    ///
    /// タグの中の `key="value"` / `key='value'` / `key=value` を集める。キーは小文字。値は実体参照を戻す。
    ///
    pub def attributes(tag: String): Map[String, String] =
        readAttributes(String.toList(tag), Map.empty())

    def readAttributes(chars: List[Char], acc: Map[String, String]): Map[String, String] =
        match List.dropWhile(c -> Char.isWhitespace(c) or c == '/', chars) {
            case Nil  => acc
            case rest =>
                let (key, afterKey) = List.span(c -> not Char.isWhitespace(c) and c != '=' and c != '/', rest);
                match List.dropWhile(Char.isWhitespace, afterKey) {
                    case '=' :: afterEquals =>
                        let (value, remaining) = readValue(List.dropWhile(Char.isWhitespace, afterEquals));
                        readAttributes(remaining, Map.insert(String.toLowerCase(List.join("", List.map(Char.toString, key))), decodeEntities(value), acc))
                    case remaining => if (List.isEmpty(key)) readAttributes(List.drop(1, remaining), acc) else readAttributes(remaining, acc)
                }
        }

    /// 引用符付きならその中、無ければ空白まで。
    def readValue(chars: List[Char]): (String, List[Char]) = match chars {
        case '"' :: rest  => quoted('"', rest)
        case '\'' :: rest => quoted('\'', rest)
        case _            => { let (value, remaining) = List.span(c -> not Char.isWhitespace(c), chars); (List.join("", List.map(Char.toString, value)), remaining) }
    }

    def quoted(quote: Char, chars: List[Char]): (String, List[Char]) =
        let (value, remaining) = List.span(c -> c != quote, chars);
        (List.join("", List.map(Char.toString, value)), List.drop(1, remaining))

    /// 前後の空白を落とし、中の空白の連なりを 1 つに。
    def clean(text: String): String = String.words(text) |> List.join(" ")

    /// よく出る実体参照を戻す。`&amp;` は最後（`&amp;lt;` を `<` にしない）。
    pub def decodeEntities(text: String): String =
        text
            |> String.replace(src = "&quot;", dst = "\"")
            |> String.replace(src = "&#39;", dst = "'")
            |> String.replace(src = "&#x27;", dst = "'")
            |> String.replace(src = "&apos;", dst = "'")
            |> String.replace(src = "&lt;", dst = "<")
            |> String.replace(src = "&gt;", dst = ">")
            |> String.replace(src = "&#x2F;", dst = "/")
            |> String.replace(src = "&amp;", dst = "&")

    // ---- URL ----

    ///
    /// 相対 URL を base で絶対にする。絶対ならそのまま、`//host/…` は base のスキーム、`/…` は base の origin、それ以外は base のディレクトリ。
    ///
    pub def resolveUrl(base: String, reference: String): String =
        if (String.startsWith(prefix = "http://", reference) or String.startsWith(prefix = "https://", reference)) reference
        else if (String.startsWith(prefix = "//", reference)) schemeOf(base) ++ ":" ++ reference
        else if (String.startsWith(prefix = "/", reference)) originOf(base) ++ reference
        else directoryOf(base) ++ reference

    /// `https` など。
    def schemeOf(url: String): String = String.takeWhile(c -> c != ':', url)

    /// `https://host:port`。
    def originOf(url: String): String =
        let afterScheme = String.indexOf(substr = "://", url) |> Option.map(at -> at + 3) |> Option.getWithDefault(0);
        String.takeLeft(afterScheme, url) ++ (String.dropLeft(afterScheme, url) |> String.takeWhile(c -> c != '/' and c != '?' and c != '#'))

    /// クエリと fragment を落とし、最後の `/` まで。パスが無ければ origin + `/`。
    def directoryOf(url: String): String =
        let withoutQuery = String.takeWhile(c -> c != '?' and c != '#', url);
        let origin = originOf(url);
        let path = String.dropLeft(String.length(origin), withoutQuery);
        match String.indexOfRight(substr = "/", path) {
            case Some(at) => origin ++ String.takeLeft(at + 1, path)
            case None     => origin ++ "/"
        }

}
