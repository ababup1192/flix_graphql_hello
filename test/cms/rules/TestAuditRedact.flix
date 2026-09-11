///
/// AuditRedact.webhookUrl: Webhook の URL を監査に残せる形（host / pathHint / urlHash）に落とす。純粋。
///
/// deploy hook や Slack の URL は最後のセグメントがそのまま認証情報なので、append-only の監査に丸ごと入れると消せない。
///
mod TestAuditRedact {

    use Util.Json.Json

    /// 表の URL。host と、最後のセグメントを "…" に落とした pathHint。
    ///
    ///   Cloudflare / Vercel の deploy hook、Slack の incoming webhook、普通の URL、path の無い URL、path が無く query だけの URL
    def table(): List[(String, (String, String))] = List#{
        ("https://api.cloudflare.com/client/v4/pages/webhooks/deploy_hooks/8f3a1c9e2b47", ("api.cloudflare.com", "/client/v4/pages/webhooks/deploy_hooks/…")),
        ("https://api.vercel.com/v1/integrations/deploy/prj_x/abc123",                     ("api.vercel.com", "/v1/integrations/deploy/prj_x/…")),
        ("https://hooks.slack.com/services/T0/B0/xxxx",                                    ("hooks.slack.com", "/services/T0/B0/…")),
        ("https://example.com/hooks/cms",                                                  ("example.com", "/hooks/…")),
        ("https://example.com",                                                            ("example.com", "/")),
        ("https://example.com?token=abc123",                                               ("example.com", "/"))
    }

    /// Json の文字列のキー。
    def field(key: String, json: Json): String = match json {
        case Json.JObject(map) => match Map.get(key, map) {
            case Some(Json.JString(text)) => text
            case _                        => "?"
        }
        case _ => "?"
    }

    /// host と pathHint の表。
    @Test
    def testAuditRedactHostAndPathHint(): Unit \ Assert =
        Assert.assertEq(
            expected = table() |> List.map(snd),
            table() |> List.map(fst) |> List.map(url -> {
                let json = AuditRedact.webhookUrl(url);
                (field("host", json), field("pathHint", json))
            }))

    /// 元の URL の最後のセグメント（トークンの部分）は、落とした Json のどこにも出ない。
    @Test
    def testAuditRedactDropsLastSegment(): Unit \ Assert =
        let secrets = List#{ "8f3a1c9e2b47", "abc123", "xxxx", "cms", "://", "token=abc123" };
        Assert.assertEq(
            expected = List#{ false, false, false, false, false, false },
            List.zip(table() |> List.map(fst), secrets)
                |> List.map(match (url, secret) -> Util.Json.toCompactString(AuditRedact.webhookUrl(url)) |> String.contains(substr = secret)))

    /// urlHash は URL ごとに決まり、同じ URL なら同じ 12 桁（作った時と消した時の照合に使う）。
    @Test
    def testAuditRedactHashIsStable(): Unit \ Assert =
        let hash = url -> field("urlHash", AuditRedact.webhookUrl(url));
        Assert.assertEq(
            expected = (true, 12, false),
            (hash("https://example.com/hooks/cms") == hash("https://example.com/hooks/cms"),
             String.length(hash("https://example.com/hooks/cms")),
             hash("https://example.com/hooks/cms") == hash("https://example.com/hooks/cms2")))

}
