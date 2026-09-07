///
/// webhooks / webhook_deliveries の行とドメインの値の変換。列名を知るのはここだけ。
///
mod WebhookRows {

    pub def toWebhook(row: { id = Int64, publicId = String, name = String, url = String, events = List[String], active = Bool, createdAt = Timestamp.Timestamp | r }): Webhook \ DbErr =
        { id = row#id, publicId = row#publicId, name = row#name, url = row#url,
          events = row#events |> List.map(text -> WebhookEvent.parse(text) |> Rows.orRaise("webhooks.events", text)),
          active = row#active, createdAt = row#createdAt }

    pub def toDelivery(row: { id = String, event = String, status = String, attempts = Int32, nextAttemptAt = Timestamp.Timestamp, lastStatus = Int32, lastError = String, createdAt = Timestamp.Timestamp, deliveredAt = Option[Timestamp.Timestamp] | r }): WebhookDelivery \ DbErr =
        { id = row#id,
          event = WebhookEvent.parse(row#event) |> Rows.orRaise("webhook_deliveries.event", row#event),
          status = DeliveryStatus.parse(row#status) |> Rows.orRaise("webhook_deliveries.status", row#status),
          attempts = row#attempts, nextAttemptAt = row#nextAttemptAt, lastStatus = row#lastStatus, lastError = row#lastError,
          createdAt = row#createdAt, deliveredAt = row#deliveredAt }

}
