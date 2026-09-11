///
/// 監査に残せない値を、後から照合できる形に落とす。純粋。
///
/// WhyNot: Webhook の URL を丸ごと残さない。deploy hook（Cloudflare / Vercel / Netlify）と Slack の incoming webhook は
/// URL の最後のセグメントがそのまま認証情報で、append-only の `audit_events` に入れると二度と消せない。
///
/// WhyNot: ホスト名で「認証情報の入る提供元」を判定しない。提供元は増えるので、全ての URL で一律に最後のセグメントを落とす。
/// 同じ URL に戻したかは urlHash で照合できる。
///
mod AuditRedact {

    use Util.Json.Json

    ///
    /// Webhook の URL → `{host, pathHint, urlHash}`。pathHint は path の最後のセグメント（query と fragment ごと）を "…" に。
    /// urlHash は URL 全体の SHA-256 の先頭 12 桁。
    ///
    pub def webhookUrl(url: String): Json =
        Json.JObject(Map#{
            "host"     => Json.JString(hostOf(url)),
            "pathHint" => Json.JString(pathHintOf(url)),
            "urlHash"  => Json.JString(Sha256.hex(url) |> String.takeLeft(12))
        })

    /// scheme を除いた残り。
    def afterScheme(url: String): String = match String.indexOf(substr = "://", url) {
        case Some(index) => String.dropLeft(index + 3, url)
        case None        => url
    }

    /// ホスト名（port 付きならそのまま）。path が無く query だけの URL でも query は入れない。
    def hostOf(url: String): String =
        afterScheme(url) |> String.takeWhile(ch -> ch != '/' and ch != '?' and ch != '#')

    /// path の最後のセグメントを "…" にした物。path が無ければ "/"（query だけでも、query は落とす）。
    def pathHintOf(url: String): String =
        let path = afterScheme(url) |> String.dropWhile(ch -> ch != '/' and ch != '?' and ch != '#');
        if (path == "" or path == "/" or String.startsWith(prefix = "?", path) or String.startsWith(prefix = "#", path)) "/"
        else match String.splitOn(substr = "/", path) |> List.reverse {
            case _ :: rest => List.reverse("…" :: rest) |> List.join("/")
            case Nil       => "/"
        }

}
