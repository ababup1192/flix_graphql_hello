///
/// Webhook の登録と配信の積み込み。pub の入口は manageProject の証明（`Granted[ManageProject]`）を最初の引数で受け、自分では判定しない。
/// 積み込み（emit）は `Publishing.notify` が公開などのユースケースと同じ Tx で呼ぶ outbox で、送るのは app の WebhookDispatcher。
///
mod Webhooks {

    use Util.Json.Json

    /// secret の接頭辞。secret scanning に引っかかる形。
    def secretPrefix(): String = "whsec_"

    ///
    /// 今のプロジェクトの Webhook。
    ///
    pub def list(_proof: Granted[ManageProject]): List[Webhook] \ DbRead + Tenant =
        WebhooksQueries.listWebhooks(Tenant.currentId()) |> List.map(WebhookRows.toWebhook)

    ///
    /// 作る。secret はこの戻りでしか見えない。
    ///
    pub def create(_proof: Granted[ManageProject], draft: WebhookDraft): IssuedWebhook \ Db + CmsErr + IdGen + Tenant =
        CmsErr.raiseIfAny(validate(draft));
        let publicId = IdGen.freshPublicId();
        let secret = secretPrefix() ++ IdGen.freshSecret();
        discard WebhooksQueries.insertWebhook({
            publicId = publicId, projectId = Tenant.currentId(), name = draft#name, url = draft#url,
            secret = secret, events = draft#events |> List.map(WebhookEvent.text), active = draft#active });
        { webhook = find(publicId), secret = secret }

    ///
    /// 直す。secret は変えない（変えたければ作り直す）。
    ///
    pub def update(_proof: Granted[ManageProject], publicId: String, draft: WebhookDraft): Webhook \ Db + CmsErr + Tenant =
        CmsErr.raiseIfAny(validate(draft));
        let changed = WebhooksQueries.updateWebhook({
            publicId = publicId, projectId = Tenant.currentId(), name = draft#name, url = draft#url,
            events = draft#events |> List.map(WebhookEvent.text), active = draft#active });
        if (changed == 0) CmsErr.notFound(Entity.Webhook, publicId) else find(publicId)

    ///
    /// 消す。配信の記録も消える。
    ///
    pub def delete(_proof: Granted[ManageProject], publicId: String): Unit \ DbWrite + CmsErr + Tenant =
        let deleted = WebhooksQueries.deleteWebhook({ publicId = publicId, projectId = Tenant.currentId() });
        if (deleted == 0) CmsErr.notFound(Entity.Webhook, publicId) else ()

    ///
    /// 配信の記録。新しい順。
    ///
    pub def deliveries(_proof: Granted[ManageProject], publicId: String, first: Int32, after: Option[String]): List[WebhookDelivery] \ DbRead + CmsErr + Tenant =
        let webhook = find(publicId);
        (match after {
            case None          => WebhooksQueries.listDeliveries({ webhookId = webhook#id, projectId = Tenant.currentId(), limit = Int32.toInt64(first) })
            case Some(afterId) => WebhooksQueries.listDeliveriesAfter({ webhookId = webhook#id, projectId = Tenant.currentId(), afterId = afterId, limit = Int32.toInt64(first) })
        }) |> List.map(WebhookRows.toDelivery)

    ///
    /// 配信をもう 1 度送る番にする。送っている最中の物は触れない。
    ///
    pub def redeliver(_proof: Granted[ManageProject], deliveryId: String): WebhookDelivery \ Db + CmsErr + Tenant =
        let changed = WebhooksQueries.resetDelivery({ id = deliveryId, projectId = Tenant.currentId() });
        if (changed == 0) CmsErr.notFound(Entity.WebhookDelivery, deliveryId) else ();
        WebhooksQueries.findDelivery({ id = deliveryId, projectId = Tenant.currentId() }) |> Option.map(WebhookRows.toDelivery) |> CmsErr.orNotFound(Entity.WebhookDelivery, deliveryId)

    ///
    /// entry の出来事を配信に積む。呼ぶのは `Publishing.notify` だけ（公開・取り下げ・削除のユースケースと同じ Tx）。
    ///
    /// WhyNot: 証明を取らないのは、outbox に積むのは操作の結果で、誰ができるかは公開などの入口（publishEntries / writeEntries の証明）が決めているため。
    /// ここで別の証明を要求すると、同じ操作に 2 つの権限が要る事になる。
    ///
    pub def emitEntry(event: WebhookEvent, entryId: EntryId, typeApiId: ApiId): Unit \ Db + IdGen + Tenant =
        emit(event, entryPayload(event, entryId, typeApiId))

    ///
    /// 型の変更を配信に積む。呼ぶのは `Publishing.notify` だけ（型を触るユースケースと同じ Tx）。
    ///
    /// WhyNot: 証明を取らないのは emitEntry と同じ（型の変更の入口が manageTypes の証明を受けている）。
    ///
    pub def emitSchema(typeApiId: ApiId): Unit \ Db + IdGen + Tenant =
        emit(WebhookEvent.SchemaChanged, schemaPayload(typeApiId))

    ///
    /// 出来事を受ける有効な Webhook すべてに配信を積む。Webhook が無ければ何もしない。
    ///
    def emit(event: WebhookEvent, payload: Json): Unit \ Db + IdGen + Tenant =
        WebhooksQueries.listActiveWebhooksForEvent({ projectId = Tenant.currentId(), event = WebhookEvent.text(event) })
            |> List.forEach(row -> discard WebhooksQueries.insertDelivery({
                id = IdGen.freshUlid(), projectId = Tenant.currentId(), webhookId = row#id, event = WebhookEvent.text(event), payload = payload }))

    ///
    /// entry の出来事の payload。中身は持たず、id と型だけ（受け手はコンテンツ API で読む）。
    ///
    def entryPayload(event: WebhookEvent, entryId: EntryId, typeApiId: ApiId): Json \ DbRead + Tenant =
        Json.JObject(Map#{
            "event"   => Json.JString(WebhookEvent.text(event)),
            "project" => Json.JString(projectSlug()),
            "entry"   => Json.JObject(Map#{ "id" => Json.JString(EntryId.text(entryId)), "type" => Json.JString(ApiId.text(typeApiId)) })
        })

    ///
    /// 型の変更の payload。
    ///
    def schemaPayload(typeApiId: ApiId): Json \ DbRead + Tenant =
        Json.JObject(Map#{
            "event"   => Json.JString(WebhookEvent.text(WebhookEvent.SchemaChanged)),
            "project" => Json.JString(projectSlug()),
            "type"    => Json.JString(ApiId.text(typeApiId))
        })

    /// payload に入れる今のプロジェクトのプロジェクト slug。
    def projectSlug(): String \ DbRead + Tenant =
        Projects.find(Tenant.current()) |> Option.map(found -> ProjectSlug.text(found#slug)) |> Option.getWithDefault("")

    /// 外向きの id で 1 つ。無ければ notFound。
    def find(publicId: String): Webhook \ DbRead + CmsErr + Tenant =
        WebhooksQueries.findWebhookByPublicId({ publicId = publicId, projectId = Tenant.currentId() }) |> Option.map(WebhookRows.toWebhook) |> CmsErr.orNotFound(Entity.Webhook, publicId)

    /// 名前・url の形・出来事の有無。
    def validate(draft: WebhookDraft): List[Violation] =
        Naming.validateName("name", draft#name)
            ::: (if (String.startsWith(prefix = "https://", draft#url) or String.startsWith(prefix = "http://", draft#url)) Nil else Violation.Violation("url", "url は http:// か https:// で始めてください") :: Nil)
            ::: (if (List.isEmpty(draft#events)) Violation.Violation("events", "出来事を 1 つ以上選んでください") :: Nil else Nil)

}
