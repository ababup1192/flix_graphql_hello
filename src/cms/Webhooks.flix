///
/// Webhook の登録と配信の積み込み。誰が何をできるかは Session（manageProject）で守る。
/// 積み込み（emit）は公開などのユースケースが同じ Tx で呼ぶ outbox で、送るのは app の WebhookDispatcher。
///
mod Webhooks {

    use Util.Json.Json

    /// secret の接頭辞。secret scanning に引っかかる形。
    def secretPrefix(): String = "whsec_"

    ///
    /// 今のプロジェクトの Webhook。
    ///
    pub def list(): List[Webhook] \ DbRead + DbErr + CmsErr + Tenant + Session =
        Session.require(Permission.ManageProject);
        WebhooksQueries.listWebhooks(Tenant.currentId()) |> List.map(fromRow)

    ///
    /// 作る。secret はこの戻りでしか見えない。
    ///
    pub def create(draft: WebhookDraft): IssuedWebhook \ Db + CmsErr + IdGen + Tenant + Session =
        Session.require(Permission.ManageProject);
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
    pub def update(publicId: String, draft: WebhookDraft): Webhook \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.ManageProject);
        CmsErr.raiseIfAny(validate(draft));
        let changed = WebhooksQueries.updateWebhook({
            publicId = publicId, projectId = Tenant.currentId(), name = draft#name, url = draft#url,
            events = draft#events |> List.map(WebhookEvent.text), active = draft#active });
        if (changed == 0) CmsErr.notFound(Entity.Webhook, publicId) else find(publicId)

    ///
    /// 消す。配信の記録も消える。
    ///
    pub def delete(publicId: String): Unit \ DbWrite + CmsErr + Tenant + Session =
        Session.require(Permission.ManageProject);
        let deleted = WebhooksQueries.deleteWebhook({ publicId = publicId, projectId = Tenant.currentId() });
        if (deleted == 0) CmsErr.notFound(Entity.Webhook, publicId) else ()

    ///
    /// 配信の記録。新しい順。
    ///
    pub def deliveries(publicId: String, first: Int32): List[WebhookDelivery] \ DbRead + DbErr + CmsErr + Tenant + Session =
        Session.require(Permission.ManageProject);
        let webhook = find(publicId);
        WebhooksQueries.listDeliveries({ webhookId = webhook#id, projectId = Tenant.currentId(), limit = Int32.toInt64(Int32.max(1, Int32.min(200, first))) })
            |> List.map(deliveryOf)

    ///
    /// 配信をもう 1 度送る番にする。送っている最中の物は触れない。
    ///
    pub def redeliver(deliveryId: String): WebhookDelivery \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.ManageProject);
        let changed = WebhooksQueries.resetDelivery({ id = deliveryId, projectId = Tenant.currentId() });
        if (changed == 0) CmsErr.notFound(Entity.WebhookDelivery, deliveryId) else ();
        WebhooksQueries.findDelivery({ id = deliveryId, projectId = Tenant.currentId() }) |> Option.map(deliveryOf) |> CmsErr.orNotFound(Entity.WebhookDelivery, deliveryId)

    ///
    /// 出来事を受ける有効な Webhook すべてに配信を積む。ユースケースが同じ Tx で呼ぶ。Webhook が無ければ何もしない。
    ///
    pub def emit(event: WebhookEvent, payload: Json): Unit \ Db + IdGen + Tenant =
        WebhooksQueries.listActiveWebhooksForEvent({ projectId = Tenant.currentId(), event = WebhookEvent.text(event) })
            |> List.forEach(row -> discard WebhooksQueries.insertDelivery({
                id = IdGen.freshUlid(), projectId = Tenant.currentId(), webhookId = row#id, event = WebhookEvent.text(event), payload = payload }))

    ///
    /// entry の出来事の payload。中身は持たず、id と型だけ（受け手はコンテンツ API で読む）。
    ///
    pub def entryPayload(event: WebhookEvent, entryId: EntryId, typeApiId: ApiId): Json \ DbRead + DbErr + Tenant =
        Json.JObject(Map#{
            "event"   => Json.JString(WebhookEvent.text(event)),
            "project" => Json.JString(projectSlug()),
            "entry"   => Json.JObject(Map#{ "id" => Json.JString(EntryId.text(entryId)), "type" => Json.JString(ApiId.text(typeApiId)) })
        })

    ///
    /// 型の変更の payload。
    ///
    pub def schemaPayload(typeApiId: ApiId): Json \ DbRead + DbErr + Tenant =
        Json.JObject(Map#{
            "event"   => Json.JString(WebhookEvent.text(WebhookEvent.SchemaChanged)),
            "project" => Json.JString(projectSlug()),
            "type"    => Json.JString(ApiId.text(typeApiId))
        })

    def projectSlug(): String \ DbRead + DbErr + Tenant =
        Projects.find(Tenant.current()) |> Option.map(found -> ProjectSlug.text(found#slug)) |> Option.getWithDefault("")

    def find(publicId: String): Webhook \ DbRead + DbErr + CmsErr + Tenant =
        WebhooksQueries.findWebhookByPublicId({ publicId = publicId, projectId = Tenant.currentId() }) |> Option.map(fromRow) |> CmsErr.orNotFound(Entity.Webhook, publicId)

    def validate(draft: WebhookDraft): List[Violation] =
        (if (String.isEmpty(String.trim(draft#name))) Violation.Violation("name", "名前を付けてください") :: Nil else Nil)
            ::: (if (String.startsWith(prefix = "https://", draft#url) or String.startsWith(prefix = "http://", draft#url)) Nil else Violation.Violation("url", "url は http:// か https:// で始めてください") :: Nil)
            ::: (if (List.isEmpty(draft#events)) Violation.Violation("events", "出来事を 1 つ以上選んでください") :: Nil else Nil)

    def fromRow(row: { id = Int64, publicId = String, name = String, url = String, events = List[String], active = Bool, createdAt = Timestamp.Timestamp | r }): Webhook \ DbErr =
        { id = row#id, publicId = row#publicId, name = row#name, url = row#url,
          events = row#events |> List.map(text -> WebhookEvent.parse(text) |> Rows.orRaise("webhooks.events", text)),
          active = row#active, createdAt = row#createdAt }

    def deliveryOf(row: { id = String, event = String, status = String, attempts = Int32, nextAttemptAt = Timestamp.Timestamp, lastStatus = Int32, lastError = String, createdAt = Timestamp.Timestamp, deliveredAt = Option[Timestamp.Timestamp] | r }): WebhookDelivery \ DbErr =
        { id = row#id,
          event = WebhookEvent.parse(row#event) |> Rows.orRaise("webhook_deliveries.event", row#event),
          status = DeliveryStatus.parse(row#status) |> Rows.orRaise("webhook_deliveries.status", row#status),
          attempts = row#attempts, nextAttemptAt = row#nextAttemptAt, lastStatus = row#lastStatus, lastError = row#lastError,
          createdAt = row#createdAt, deliveredAt = row#deliveredAt }

}
