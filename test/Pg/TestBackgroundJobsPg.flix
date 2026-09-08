///
/// バックグラウンドワーカーの 1 tick（BackgroundJobs.tick）の回復と掃除を実 PostgreSQL で見る。
/// 行の時刻は生 SQL で過去にずらす（時刻を差し込む口が無いため）。
///
mod TestBackgroundJobsPg {

    use Util.Json.Json

    def future(): Timestamp.Timestamp = Timestamp.at("2100-01-01T00:00:00Z")

    /// 送っても届かない相手（何も listen していない port）。tick が本物の HTTP を送っても外へ出ない。
    def hook(): WebhookDraft = { name = "site", url = "http://127.0.0.1:1/hook", events = List#{WebhookEvent.EntryPublished}, active = true }

    ///
    /// Webhook を 1 つ置き、blogs の e1..eN を作って公開する（entry.published の配信が N 件積まれる）。Webhook の public_id を返す。
    ///
    def publishEntries(count: Int32): String \ Db + CmsErr + IdGen + Tenant + Session =
        let issued = Webhooks.create(Session.grant(), hook());
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        List.range(1, count + 1) |> List.forEach(number -> {
            let entry = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("e${number}")), CmsTestKit.entryData(List#{("title", Json.JString("e${number}"))}));
            discard ContentEntries.publish(Session.grant(), entry#id, "tester", false)
        });
        issued#webhook#publicId

    /// 配信の id。古い順。
    def deliveryIds(pool: Pool, webhookId: String): List[String] \ IO =
        PgTestSupport.mutateOrBug(pool, () -> Webhooks.deliveries(Session.grant(), webhookId, 10)) |> List.map(delivery -> delivery#id) |> List.reverse

    /// 配信の (id, status, attempts)。古い順。
    def deliveryStates(pool: Pool, webhookId: String): List[(String, DeliveryStatus, Int32)] \ IO =
        PgTestSupport.mutateOrBug(pool, () -> Webhooks.deliveries(Session.grant(), webhookId, 10)) |> List.map(delivery -> (delivery#id, delivery#status, delivery#attempts)) |> List.reverse

    /// 予約の id。古い順。
    def scheduleIds(pool: Pool): List[String] \ IO =
        PgTestSupport.mutateOrBug(pool, () -> Schedules.list(Session.grant(), None, 10)) |> List.map(schedule -> schedule#id) |> List.reverse

    def touch(sql: String, id: String): Unit \ IO =
        discard PgTestSupport.executeSql(sql, SqlValue.Str(id) :: Nil)

    ///
    /// 掃除は終わった記録（done / failed / cancelled、delivered / failed）で keepDays より古い物だけ消す。
    /// 古くても pending は残り、終わっていても新しい物は残る。/health のまとめは残った物を数える。
    ///
    ///   予約  s1: done 40 日前 → 消える   s2: pending 40 日前 → 残る   s3: cancelled 10 日前 → 残る
    ///   配信  d1: delivered 40 日前 → 消える   d2: pending 40 日前（次の送信は明日）→ 残る   d3: failed 10 日前 → 残る
    ///
    @Test
    def testPgTickPurgesOnlyOldFinishedRecords(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let webhookId = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"w1"}, () -> {
                let webhookId = publishEntries(3);
                List.forEach(id -> discard Schedules.schedule(Session.grant(), CmsTestKit.entryId(id), ScheduleAction.Publish, future(), false), List#{"e1", "e2", "e3"});
                webhookId
            }));
            let (s1, s2, s3) = match scheduleIds(pool) { case a :: b :: c :: Nil => (a, b, c) case other => bug!("予約が 3 件ではありません: ${other}") };
            let (d1, d2, d3) = match deliveryIds(pool, webhookId) { case a :: b :: c :: Nil => (a, b, c) case other => bug!("配信が 3 件ではありません: ${other}") };
            touch("UPDATE scheduled_actions SET status = 'done', created_at = now() - interval '40 days' WHERE id = $1", s1);
            touch("UPDATE scheduled_actions SET created_at = now() - interval '40 days' WHERE id = $1", s2);
            touch("UPDATE scheduled_actions SET status = 'cancelled', created_at = now() - interval '10 days' WHERE id = $1", s3);
            touch("UPDATE webhook_deliveries SET status = 'delivered', created_at = now() - interval '40 days' WHERE id = $1", d1);
            touch("UPDATE webhook_deliveries SET created_at = now() - interval '40 days', next_attempt_at = now() + interval '1 day' WHERE id = $1", d2);
            touch("UPDATE webhook_deliveries SET status = 'failed', created_at = now() - interval '10 days' WHERE id = $1", d3);
            let jobs = BackgroundJobs.createState(15i64, None, OutboundHttp.newClient());
            let failures = ServerTestKit.quietly(() -> BackgroundJobs.tick(pool, jobs));
            let summary = BackgroundJobs.summary(pool, jobs);
            (failures,
             scheduleIds(pool) == List#{s2, s3},
             deliveryIds(pool, webhookId) == List#{d2, d3},
             (summary#pendingSchedules, summary#failedSchedules, summary#pendingDeliveries, summary#failedDeliveries, Option.nonEmpty(summary#lastTickAt)))
        });
        Assert.assertEq(expected = (Nil, true, true, (1i64, 0i64, 1i64, 1i64, true)), outcome)

    ///
    /// 送っている最中に落ちた配信（sending のまま claimed_at が古い）は tick の回復で pending に戻り、同じ tick の dispatcher が送り直す
    /// （相手に届かないので attempts が進んで再試行待ち）。拾ったばかりの sending は触らない。
    ///
    ///   d1: sending / attempts 1 / 1 時間前に拾った → 回復 → 送る → pending / attempts 2
    ///   d2: sending / attempts 1 / 1 分前に拾った   → そのまま
    ///
    @Test
    def testPgTickRecoversStuckDeliveries(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let webhookId = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"w1"}, () -> publishEntries(2)));
            let (d1, d2) = match deliveryIds(pool, webhookId) { case a :: b :: Nil => (a, b) case other => bug!("配信が 2 件ではありません: ${other}") };
            touch("UPDATE webhook_deliveries SET status = 'sending', attempts = 1, claimed_at = now() - interval '1 hour' WHERE id = $1", d1);
            touch("UPDATE webhook_deliveries SET status = 'sending', attempts = 1, claimed_at = now() - interval '1 minute' WHERE id = $1", d2);
            let failures = ServerTestKit.quietly(() -> BackgroundJobs.tick(pool, BackgroundJobs.createState(15i64, None, OutboundHttp.newClient())));
            (failures, deliveryStates(pool, webhookId) == List#{(d1, DeliveryStatus.Pending, 2), (d2, DeliveryStatus.Sending, 1)})
        });
        Assert.assertEq(expected = (Nil, true), outcome)

}
