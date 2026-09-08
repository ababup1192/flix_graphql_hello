///
/// WebhookRows: webhooks / webhook_deliveries の行とドメインの値の往復。純粋（DbErr は Result に落として見る）。
///
/// 観点:
/// - 往復: WebhookEvent と DeliveryStatus の全 case、events の空のリスト、deliveredAt の None / Some、ULID と public_id はそのまま
/// - 境界: 知らない event（リストの途中でも）と status は DbErr
///
mod TestWebhookRows {

    def at(millis: Int64): Timestamp.Timestamp = Timestamp.fromEpochMillis(millis)

    def ulid(): String = "01ARYZ6S41TSV4RRFFQ69G5FAV"

    def allEvents(): List[WebhookEvent] = List#{WebhookEvent.EntryPublished, WebhookEvent.EntryUnpublished, WebhookEvent.EntryDeleted, WebhookEvent.SchemaChanged}

    def webhookRow(events: List[String]): { id = Int64, publicId = String, name = String, url = String, events = List[String], active = Bool, createdAt = Timestamp.Timestamp } =
        { id = 3i64, publicId = "3f9a1c2b7e6d", name = "deploy", url = "https://example.com/hook?x=日本", events = events, active = false, createdAt = at(1725000000123i64) }

    def deliveryRow(event: String, status: String, deliveredAt: Option[Timestamp.Timestamp]): { id = String, event = String, status = String, attempts = Int32, nextAttemptAt = Timestamp.Timestamp, lastStatus = Int32, lastError = String, createdAt = Timestamp.Timestamp, deliveredAt = Option[Timestamp.Timestamp] } =
        { id = ulid(), event = event, status = status, attempts = 2, nextAttemptAt = at(1725000000001i64), lastStatus = 503, lastError = "timeout", createdAt = at(1725000000123i64), deliveredAt = deliveredAt }

    /// webhooks の行は events の全 case（順番のまま）と空のリストで往復し、他の列はそのまま。
    @Test
    def testWebhookRoundTrip(): Unit \ Assert =
        let table = List#{allEvents(), Nil, List#{WebhookEvent.SchemaChanged, WebhookEvent.EntryPublished}};
        Assert.assertEq(expected = table |> List.map(events -> Ok((3i64, "3f9a1c2b7e6d", "deploy", "https://example.com/hook?x=日本", events, false, at(1725000000123i64)))),
            table |> List.map(events -> DbErr.runWithResult(() -> {
                let found = WebhookRows.toWebhook(webhookRow(List.map(WebhookEvent.text, events)));
                (found#id, found#publicId, found#name, found#url, found#events, found#active, found#createdAt)
            })))

    /// events に知らない文字列が 1 つでもあれば DbErr（先頭でも途中でも）。
    @Test
    def testToWebhookRejects(): Unit \ Assert =
        Assert.assertEq(expected = (true, true),
            (DbErr.runWithResult(() -> WebhookRows.toWebhook(webhookRow(List#{"entry.archived"}))) |> Result.isErr,
             DbErr.runWithResult(() -> WebhookRows.toWebhook(webhookRow(List#{"entry.published", "entry.archived", "schema.changed"}))) |> Result.isErr))

    /// webhook_deliveries の行は event × status の全組で往復し、deliveredAt の None / Some と他の列はそのまま。
    @Test
    def testDeliveryRoundTrip(): Unit \ Assert =
        let statuses = List#{DeliveryStatus.Pending, DeliveryStatus.Sending, DeliveryStatus.Delivered, DeliveryStatus.Failed};
        let table = allEvents() |> List.flatMap(event -> statuses |> List.map(status -> (event, status, if (status == DeliveryStatus.Delivered) Some(at(1725000000999i64)) else None)));
        Assert.assertEq(expected = table |> List.map(match (event, status, deliveredAt) -> Ok((ulid(), event, status, 2, at(1725000000001i64), 503, "timeout", at(1725000000123i64), deliveredAt))),
            table |> List.map(match (event, status, deliveredAt) -> DbErr.runWithResult(() -> {
                let found = WebhookRows.toDelivery(deliveryRow(WebhookEvent.text(event), DeliveryStatus.text(status), deliveredAt));
                (found#id, found#event, found#status, found#attempts, found#nextAttemptAt, found#lastStatus, found#lastError, found#createdAt, found#deliveredAt)
            })))

    /// 知らない event と status は DbErr。
    @Test
    def testToDeliveryRejects(): Unit \ Assert =
        Assert.assertEq(expected = (true, true),
            (DbErr.runWithResult(() -> WebhookRows.toDelivery(deliveryRow("entry.archived", "pending", None))) |> Result.isErr,
             DbErr.runWithResult(() -> WebhookRows.toDelivery(deliveryRow("entry.published", "retrying", None))) |> Result.isErr))

}
