///
/// Webhook を実 PostgreSQL で見る。公開・取り下げ・型の変更で配信が積まれ、dispatcher が拾って送り、失敗すれば再試行を積み、
/// 再送すれば送り直す。HTTP は Http effect の handler を差し替えて相手の応答を作る。
///
mod TestWebhooksPg {

    use Util.Json.Json
    use Net.Http.Http
    use Net.HttpRequest
    use Net.HttpResponse.HttpResponse

    def draft(events: List[WebhookEvent]): WebhookDraft =
        { name = "site", url = "https://example.com/hook", events = events, active = true }

    /// 決まったステータスを返し、受けたリクエストを記録する Http の handler で tick を回す。
    def tickWith(status: Int32, received: Ref[List[HttpRequest], Static], pool: Pool): Result[String, Int32] \ IO =
        run WebhookDispatcher.tick(pool) with handler Http {
            def request(req, resume) = {
                Ref.put(req :: Ref.get(received), received);
                resume(Ok(HttpResponse.HttpResponse({ url = HttpRequest.url(req), status = status, headers = Map.empty(), body = Net.Body.Text("") })))
            }
        }

    def header(name: String, req: HttpRequest): String =
        HttpRequest.headers(req) |> Map.get(name) |> Option.flatMap(List.head) |> Option.getWithDefault("")

    ///
    /// 型を作る（schema.changed）→ フィールド（schema.changed）→ entry を公開（entry.published）→ 取り下げ（entry.unpublished）で 4 件積まれ、新しい順に並ぶ。
    /// 同じ Webhook 宛は古い順に 1 件ずつなので、相手が 500 なら最古の 1 件だけ attempts 1 で pending に戻り、残りは待つ。次の周では 0 件。
    /// 最古を redeliver して 200 なら、同じ tick で 4 件が順に送られ delivered。最後に送られたのは最新の entry.unpublished。
    /// 送ったリクエストには出来事・配信 id・署名が付き、署名は secret から同じ計算で照合できる。
    ///
    @Test
    def testPgWebhookOutboxAndDispatch(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let issued = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"w1", "e1"}, () -> {
                let issued = Webhooks.create(draft(List#{WebhookEvent.EntryPublished, WebhookEvent.EntryUnpublished, WebhookEvent.SchemaChanged}));
                let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
                discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
                let entry = ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("hi"))}));
                discard ContentEntries.publish(entry#id, "tester", false);
                discard ContentEntries.unpublish(entry#id);
                issued
            }));
            let webhookId = issued#webhook#publicId;
            let listDeliveries = () -> PgTestSupport.mutate(pool, () -> Webhooks.deliveries(webhookId, 20)) |> PgTestSupport.seededOrBug;
            let queued = listDeliveries() |> List.map(delivery -> (delivery#event, delivery#status, delivery#attempts));
            let received = Ref.fresh(Static, Nil);
            let firstTick = tickWith(500, received, pool);
            let afterFailure = listDeliveries() |> List.map(delivery -> (delivery#status, delivery#attempts, delivery#lastStatus));
            let secondTick = tickWith(500, received, pool);
            let oldest = listDeliveries() |> List.last |> Option.map(delivery -> delivery#id) |> Option.getWithDefault("?");
            discard PgTestSupport.mutate(pool, () -> Webhooks.redeliver(oldest));
            let thirdTick = tickWith(200, received, pool);
            let redelivered = listDeliveries() |> List.find(delivery -> delivery#id == oldest) |> Option.map(delivery -> (delivery#status, delivery#attempts, delivery#lastStatus, Option.nonEmpty(delivery#deliveredAt)));
            let lastRequest = Ref.get(received) |> List.head;
            let signatureMatches = lastRequest |> Option.map(req ->
                header("X-Cms-Signature", req) == WebhookDispatcher.signature(issued#secret, { timestamp = header("X-Cms-Timestamp", req), body = HttpRequest.body(req) |> Option.getWithDefault("") }));
            let lastEvent = lastRequest |> Option.map(req -> (header("X-Cms-Event", req), header("X-Cms-Delivery", req) == oldest, HttpRequest.url(req)));
            let bodyMentionsProject = lastRequest |> Option.flatMap(HttpRequest.body) |> Option.map(body -> String.contains(substr = "\"project\":\"default\"", body) and String.contains(substr = "\"type\":\"blogs\"", body));
            (queued, firstTick, afterFailure, secondTick, thirdTick, redelivered, signatureMatches, lastEvent, bodyMentionsProject, List.length(Ref.get(received)))
        });
        Assert.assertEq(
            expected = (
                List#{ (WebhookEvent.EntryUnpublished, DeliveryStatus.Pending, 0), (WebhookEvent.EntryPublished, DeliveryStatus.Pending, 0),
                       (WebhookEvent.SchemaChanged, DeliveryStatus.Pending, 0), (WebhookEvent.SchemaChanged, DeliveryStatus.Pending, 0) },
                Ok(1),
                List#{ (DeliveryStatus.Pending, 0, 0), (DeliveryStatus.Pending, 0, 0), (DeliveryStatus.Pending, 0, 0), (DeliveryStatus.Pending, 1, 500) },
                Ok(0),
                Ok(4),
                Some((DeliveryStatus.Delivered, 2, 200, true)),
                Some(true),
                Some(("entry.unpublished", false, "https://example.com/hook")),
                Some(true),
                5),
            outcome)

    ///
    /// 管理 API。作ると secret が 1 度だけ返り、一覧には出ない。直せば events と active が変わり、消せば一覧から消える。
    /// url の形が違えば invalid。
    ///
    @Test
    def testPgWebhookAdminApi(): Unit \ {IO, Assert} =
        let (created, listed, updated, badUrl, deleted, afterDelete) = PgTestSupport.withAdminApi(() -> (), (schema, _) -> {
            let ask = PgTestSupport.askOwner(schema);
            let created = ask("mutation { createWebhook(input: { name: \"site\", url: \"https://example.com/hook\", events: [ENTRY_PUBLISHED] }) { webhook { id name events active } secret } }");
            let id = created |> fst |> Value.path(List#{"createWebhook", "webhook", "id"}) |> Value.asStr |> Option.getWithDefault("?");
            let secret = created |> fst |> Value.path(List#{"createWebhook", "secret"}) |> Value.asStr |> Option.getWithDefault("");
            let listed = ask("{ webhooks { name events active } }");
            let updated = ask("mutation { updateWebhook(id: \"${id}\", input: { name: \"site\", url: \"https://example.com/hook2\", events: [ENTRY_PUBLISHED, SCHEMA_CHANGED], active: false }) { url events active } }");
            let badUrl = ask("mutation { updateWebhook(id: \"${id}\", input: { name: \"site\", url: \"ftp://x\", events: [ENTRY_PUBLISHED] }) { id } }") |> snd;
            let deleted = ask("mutation { deleteWebhook(id: \"${id}\") }") |> fst |> Value.path(List#{"deleteWebhook"}) |> Value.asStr |> Option.map(found -> found == id);
            let afterDelete = ask("{ webhooks { id } }");
            ((String.startsWith(prefix = "whsec_", secret), created |> fst |> Value.path(List#{"createWebhook", "webhook", "events"})), listed, updated, badUrl, deleted, afterDelete)
        });
        Assert.assertEq(
            expected = (
                (true, Value.List(Value.Str("ENTRY_PUBLISHED") :: Nil)),
                (Value.Obj(Map#{ "webhooks" => Value.List(Value.Obj(Map#{ "name" => Value.Str("site"), "events" => Value.List(Value.Str("ENTRY_PUBLISHED") :: Nil), "active" => Value.Bool(true) }) :: Nil) }), None),
                (Value.Obj(Map#{ "updateWebhook" => Value.Obj(Map#{ "url" => Value.Str("https://example.com/hook2"), "events" => Value.List(Value.Str("ENTRY_PUBLISHED") :: Value.Str("SCHEMA_CHANGED") :: Nil), "active" => Value.Bool(false) }) }), None),
                Some("url: url は http:// か https:// で始めてください"),
                Some(true),
                (Value.Obj(Map#{ "webhooks" => Value.List(Nil) }), None)),
            (created, listed, updated, badUrl, deleted, afterDelete))


    ///
    /// entry.deleted も積まれ、無効（active: false）な Webhook には積まれない。
    ///
    @Test
    def testPgWebhookDeletedEventAndInactive(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"w1", "w2", "e1"}, () -> {
            let active = Webhooks.create(draft(List#{WebhookEvent.EntryDeleted}));
            let inactive = Webhooks.create({ active = false | draft(List#{WebhookEvent.EntryDeleted, WebhookEvent.SchemaChanged}) });
            let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
            let entry = ContentEntries.create(blogs#id, None, CmsTestKit.entryData(Nil));
            ContentEntries.delete(entry#id);
            (Webhooks.deliveries(active#webhook#publicId, 20) |> List.map(delivery -> delivery#event),
             Webhooks.deliveries(inactive#webhook#publicId, 20) |> List.length)
        }));
        Assert.assertEq(expected = Ok(Ok((List#{WebhookEvent.EntryDeleted}, 0))), result)

    ///
    /// 5 回失敗すると failed になり、理由が残る。redeliver で送る番に戻せる（attempts は積み上がる）。
    ///
    ///   tick(500) ×5（間に redeliver で待ち時間を飛ばす）→ failed / attempts 5 / "HTTP 500"
    ///
    @Test
    def testPgWebhookFailsAfterFiveAttempts(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let issued = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"w1"}, () -> {
                let issued = Webhooks.create(draft(List#{WebhookEvent.SchemaChanged}));
                discard ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
                issued
            }));
            let received = Ref.fresh(Static, Nil);
            let deliveryId = PgTestSupport.mutate(pool, () -> Webhooks.deliveries(issued#webhook#publicId, 1)) |> PgTestSupport.seededOrBug |> List.head |> Option.map(delivery -> delivery#id) |> Option.getWithDefault("?");
            let attempt = () -> {
                discard tickWith(500, received, pool);
                discard PgTestSupport.mutate(pool, () -> Webhooks.redeliver(deliveryId))
            };
            List.forEach(_ -> attempt(), List.range(0, 4));
            discard tickWith(500, received, pool);
            let delivery = PgTestSupport.mutate(pool, () -> Webhooks.deliveries(issued#webhook#publicId, 1)) |> PgTestSupport.seededOrBug |> List.head;
            (delivery |> Option.map(found -> (found#status, found#attempts, found#lastStatus, found#lastError)), List.length(Ref.get(received)))
        });
        Assert.assertEq(expected = (Some((DeliveryStatus.Failed, 5, 500, "HTTP 500")), 5), outcome)

    ///
    /// 2 台の dispatcher が同時に拾っても同じ配信は 1 台にしか渡らない（FOR UPDATE SKIP LOCKED）。
    ///
    ///   Tx A: 拾う（COMMIT しない）→ Tx B: 拾う → 0 件 → A を COMMIT
    ///
    @Test
    def testPgWebhookClaimIsExclusive(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            discard PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"w1"}, () -> {
                discard Webhooks.create(draft(List#{WebhookEvent.SchemaChanged}));
                ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"))
            }));
            DbError.runWithFailure(() -> Jdbc.withConnection(PgTestSupport.appConfig(), conn -> {
                Tx.begin(conn);
                let first = Jdbc.runWithConnection(conn, () -> WebhooksQueries.claimDueDeliveries(10i64)) |> List.length;
                let second = DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> WebhooksQueries.claimDueDeliveries(10i64) |> List.length));
                Tx.commit(conn);
                let afterCommit = DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> WebhooksQueries.claimDueDeliveries(10i64) |> List.length));
                (first, second, afterCommit)
            }))
        });
        Assert.assertEq(expected = Ok((1, Ok(0), Ok(0))), outcome)


    ///
    /// 同じ Webhook 宛は積んだ順に 1 件ずつ送る。1 件目が 500 で再試行待ちの間、2 件目は拾われない。1 件目を再送して 200 なら、続けて 2 件目も同じ tick で送られる。
    ///
    ///   [d1, d2] 積む → tick(500): d1 だけ送る（attempts 1）、d2 は pending のまま attempts 0
    ///   → tick(500): 0 件（d1 が待ち中なので d2 も待つ）→ redeliver(d1) → tick(200): d1, d2 の順に 2 件
    ///
    @Test
    def testPgWebhookKeepsOrderPerWebhook(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let issued = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"w1"}, () -> {
                let issued = Webhooks.create(draft(List#{WebhookEvent.SchemaChanged}));
                let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
                discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
                issued
            }));
            let received = Ref.fresh(Static, Nil);
            let deliveries = () -> PgTestSupport.mutate(pool, () -> Webhooks.deliveries(issued#webhook#publicId, 10)) |> PgTestSupport.seededOrBug |> List.reverse;
            let ids = deliveries() |> List.map(delivery -> delivery#id);
            let first = tickWith(500, received, pool);
            let afterFirst = deliveries() |> List.map(delivery -> delivery#attempts);
            let blocked = tickWith(500, received, pool);
            discard PgTestSupport.mutate(pool, () -> Webhooks.redeliver(List.head(ids) |> Option.getWithDefault("?")));
            let third = tickWith(200, received, pool);
            let sentOrder = Ref.get(received) |> List.reverse |> List.map(req -> header("X-Cms-Delivery", req));
            (List.length(ids), first, afterFirst, blocked, third, sentOrder == (ids ::: List.take(1, ids)) or sentOrder == (List.take(1, ids) ::: ids), deliveries() |> List.map(delivery -> delivery#status))
        });
        Assert.assertEq(
            expected = (2, Ok(1), List#{1, 0}, Ok(0), Ok(2), true, List#{DeliveryStatus.Delivered, DeliveryStatus.Delivered}),
            outcome)

}
