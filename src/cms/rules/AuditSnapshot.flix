///
/// Webhook と asset の変更前の姿を監査の Json にする。純粋。型・フィールドは `SchemaSnapshot`。
///
/// WhyNot: `db/` の Rows に置かない。Rows は列名を知る役割で、監査に何を残すかの判断（マスク・落とす物）は別。
///
/// WhyNot: asset の fileName / key / alt を入れない。fileName は個人名・取引先名が入る運用があり、append-only の
/// 監査に入れると消去請求に応えられない。alt は本文に準ずる（版が要るなら asset 側で持つ）。
///
/// WhyNot: `ofWebhook` の引数を `IssuedWebhook` にしない。secret を持つのはそちらだけなので、`Webhook` を受ければ
/// secret 付きの値はここに渡せない。
///
mod AuditSnapshot {

    use Util.Json.Json

    ///
    /// Webhook の姿。url は `AuditRedact.webhookUrl` でマスクした物。
    ///
    pub def ofWebhook(webhook: Webhook): Json =
        Json.JObject(Map#{
            "name"   => Json.JString(webhook#name),
            "url"    => AuditRedact.webhookUrl(webhook#url),
            "events" => Json.JArray(webhook#events |> List.map(event -> Json.JString(WebhookEvent.text(event))) |> List.toVector),
            "active" => Json.JBool(webhook#active)
        })

    ///
    /// asset の姿。mime / size と、画像なら寸法（でなければ null）。
    ///
    pub def ofAsset(asset: Asset): Json =
        Json.JObject(Map#{
            "mime"   => Json.JString(asset#mime),
            "size"   => Json.JNumber(Int64.toBigDecimal(asset#size)),
            "width"  => dimension(asset#width),
            "height" => dimension(asset#height)
        })

    ///
    /// 見せ方（注目点・切り抜き枠）の変更。`{ before, after }` で、それぞれ `AssetPresentation.toJson`（何も無ければ空のオブジェクト）。
    /// 割合の数値だけで個人情報を含まないので、そのまま持つ。
    ///
    pub def ofPresentationChange(was: AssetPresentation, now: AssetPresentation): Json =
        Json.JObject(Map#{ "before" => AssetPresentation.toJson(was), "after" => AssetPresentation.toJson(now) })

    /// 寸法。無ければ null。
    def dimension(value: Option[Int32]): Json = match value {
        case Some(n) => Json.JNumber(Int32.toBigDecimal(n))
        case None    => Json.JNull
    }

}
