///
/// AuditSnapshot: Webhook と asset の変更前の姿を監査の Json にする。純粋。
///
/// 見るのはキーの集合。Webhook の url はマスクした形で、asset の fileName / key / alt は入らない。
///
mod TestAuditSnapshot {

    use Util.Json.Json

    def webhook(): Webhook =
        { id = 1i64, publicId = "wh_1", name = "Pages のデプロイ", url = "https://api.cloudflare.com/client/v4/pages/webhooks/deploy_hooks/8f3a1c9e2b47",
          events = List#{ WebhookEvent.EntryPublished, WebhookEvent.SchemaChanged }, active = true, createdAt = Timestamp.fromEpochMillis(0i64) }

    def asset(): Asset =
        { id = AssetId.AssetId("a1b2c3d4e5f6"), key = "1/a1b2c3d4e5f6/取引先の見積.pdf", fileName = "取引先の見積.pdf", mime = "application/pdf", size = 1024i64,
          width = None, height = None, alt = "山田さんの見積", status = AssetStatus.Ready, createdAt = Timestamp.fromEpochMillis(0i64), presentation = AssetPresentation.empty() }

    /// Json のキー（オブジェクトでなければ空）。
    def keys(json: Json): List[String] = match json {
        case Json.JObject(map) => Map.keysOf(map) |> Set.toList
        case _                 => Nil
    }

    /// Json の中のオブジェクト。無ければ空のオブジェクト。
    def child(key: String, json: Json): Json = match json {
        case Json.JObject(map) => Map.get(key, map) |> Option.getWithDefault(Json.JObject(Map.empty()))
        case _                 => Json.JObject(Map.empty())
    }

    /// Webhook は name / url（マスク済み）/ events / active。url は host / pathHint / urlHash に落ちていて、トークンは出ない。
    @Test
    def testAuditSnapshotOfWebhook(): Unit \ Assert =
        let json = AuditSnapshot.ofWebhook(webhook());
        Assert.assertEq(
            expected = (List#{ "active", "events", "name", "url" }, List#{ "host", "pathHint", "urlHash" }, false),
            (keys(json), keys(child("url", json)), Util.Json.toCompactString(json) |> String.contains(substr = "8f3a1c9e2b47")))

    /// asset は mime / size / width / height だけ。fileName・key・alt（個人名や取引先名が入る）は出ない。
    @Test
    def testAuditSnapshotOfAsset(): Unit \ Assert =
        let json = AuditSnapshot.ofAsset(asset());
        let text = Util.Json.toCompactString(json);
        Assert.assertEq(
            expected = (List#{ "height", "mime", "size", "width" }, false, false),
            (keys(json), String.contains(substr = "見積", text), String.contains(substr = "山田", text)))

}
