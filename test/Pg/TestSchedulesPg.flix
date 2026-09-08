///
/// 予約公開を実 PostgreSQL で見る。過去の時刻で予約して tick を呼べば、通常の公開と同じ検査で公開・取り下げされ、
/// 通らなければ failed に理由が残る。取り消し・置き換え・実行中に落ちた行の回復も見る。
///
mod TestSchedulesPg {

    use Util.Json.Json

    def past(): Timestamp.Timestamp = Timestamp.at("2020-01-01T00:00:00Z")
    def future(): Timestamp.Timestamp = Timestamp.at("2100-01-01T00:00:00Z")

    /// blogs（title は required）に e1（title 有り）と e2（title 無し）を置く。
    def seedEntries(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, { required = true | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
        discard ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("ok"))}));
        discard ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(Nil))

    def statusOf(pool: Pool, id: String): (ScheduleStatus, String) \ IO =
        PgTestSupport.mutateOrBug(pool, () -> Schedules.list(Session.grant(), None, 50, None))
            |> List.find(schedule -> schedule#id == id) |> Option.map(schedule -> (schedule#status, schedule#lastError)) |> Option.getWithDefault((ScheduleStatus.Cancelled, "?"))

    def stageOf(pool: Pool, id: String): Stage \ IO =
        PgTestSupport.mutateOrBug(pool, () -> ContentEntries.find(Session.grant(), CmsTestKit.entryId(id))) |> Option.map(entry -> entry#stage) |> Option.getWithDefault(Stage.Draft)

    ///
    /// 過去の時刻の publish は tick で公開され done。required が欠けた entry は failed に理由。未来の物は拾われない。
    /// 公開された物を過去の時刻で unpublish すれば取り下がる。
    ///
    @Test
    def testPgScheduleRunsDueActions(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let (okId, badId, laterId) = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"e1", "e2"}, () -> {
                seedEntries();
                (Schedules.schedule(Session.grant(), CmsTestKit.entryId("e1"), ScheduleAction.Publish, past(), false)#id,
                 Schedules.schedule(Session.grant(), CmsTestKit.entryId("e2"), ScheduleAction.Publish, past(), false)#id,
                 Schedules.schedule(Session.grant(), CmsTestKit.entryId("e1"), ScheduleAction.Unpublish, future(), false)#id)
            }));
            let firstTick = ServerTestKit.quietly(() -> Scheduler.tick(pool));
            let afterPublish = (statusOf(pool, okId), statusOf(pool, badId), statusOf(pool, laterId), stageOf(pool, "e1"));
            let unpublishId = PgTestSupport.mutateOrBug(pool, () -> Schedules.schedule(Session.grant(), CmsTestKit.entryId("e1"), ScheduleAction.Unpublish, past(), false)#id);
            let secondTick = ServerTestKit.quietly(() -> Scheduler.tick(pool));
            (firstTick, afterPublish, statusOf(pool, laterId), secondTick, statusOf(pool, unpublishId), stageOf(pool, "e1"))
        });
        Assert.assertEq(
            expected = (
                Ok(2),
                ((ScheduleStatus.Done, ""), (ScheduleStatus.Failed, "fields.title: 公開には値が要ります"), (ScheduleStatus.Pending, ""), Stage.Published),
                (ScheduleStatus.Cancelled, ""),
                Ok(1),
                (ScheduleStatus.Done, ""),
                Stage.Draft),
            outcome)

    ///
    /// 取り消しは pending にだけ効く。実行中に落ちた行（running のまま claimed_at が古い）は tick の回復で pending に戻り、次に実行される。
    ///
    @Test
    def testPgScheduleCancelAndRecovery(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let id = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"e1", "e2"}, () -> {
                seedEntries();
                Schedules.schedule(Session.grant(), CmsTestKit.entryId("e1"), ScheduleAction.Publish, past(), false)#id
            }));
            let cancelled = PgTestSupport.mutateOrBug(pool, () -> Schedules.cancel(Session.grant(), id)) |> (schedule -> schedule#status);
            let cancelAgainRejected = PgTestSupport.mutateOrBug(pool, () -> CmsTestKit.failureMessage(() -> Schedules.cancel(Session.grant(), id))) |> Result.isErr;
            // 落ちた事にする: 新しい予約を running のまま 1 時間前に拾った形にする
            let stuckId = PgTestSupport.mutateOrBug(pool, () -> Schedules.schedule(Session.grant(), CmsTestKit.entryId("e1"), ScheduleAction.Publish, past(), false)#id);
            discard PgTestSupport.executeSql("UPDATE scheduled_actions SET status = 'running', claimed_at = now() - interval '1 hour' WHERE id = $1", SqlValue.Str(stuckId) :: Nil);
            let untouched = ServerTestKit.quietly(() -> Scheduler.tick(pool));
            let beforeRecovery = statusOf(pool, stuckId);
            let jobs = BackgroundJobs.createState(15i64, None, OutboundHttp.newClient(), Scheduler.defaultConfig());
            let failures = ServerTestKit.quietly(() -> BackgroundJobs.tick(pool, jobs));
            (cancelled, cancelAgainRejected, untouched, beforeRecovery, failures, statusOf(pool, stuckId), stageOf(pool, "e1"), Option.nonEmpty(Ref.get(jobs#lastTick)))
        });
        Assert.assertEq(
            expected = (ScheduleStatus.Cancelled, true, Ok(0), (ScheduleStatus.Running, ""), Nil, (ScheduleStatus.Done, ""), Stage.Published, true),
            outcome)

    def hook(): WebhookDraft = { name = "site", url = "https://example.com/hook", events = List#{WebhookEvent.EntryPublished}, active = true }

    ///
    /// 別のプロジェクト（shop）の予約を tick が実行すると、entry.published の配信行は shop の project_id で積まれ、default の Webhook には積まれない。
    ///
    ///   default: Webhook だけ     shop: Webhook + blogs(s1) + s1 の publish の予約（過去）
    ///
    @Test
    def testPgScheduleTickQueuesWebhookInOwnProject(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let shop = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"w1", "w2"}, () -> {
                let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
                discard Webhooks.create(Session.grant(), hook());
                PgTestSupport.asProject(shop, () -> {
                    discard Webhooks.create(Session.grant(), hook());
                    let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
                    discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
                    discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("s1")), CmsTestKit.entryData(List#{("title", Json.JString("shop"))}));
                    discard Schedules.schedule(Session.grant(), CmsTestKit.entryId("s1"), ScheduleAction.Publish, past(), false)
                });
                shop
            }));
            let ticked = ServerTestKit.quietly(() -> Scheduler.tick(pool));
            let publishedCount = projectId -> PgTestSupport.countSql("SELECT count(*)::bigint AS total FROM webhook_deliveries WHERE project_id = $1 AND event = 'entry.published'", SqlValue.Int64(ProjectId.toInt64(projectId)) :: Nil);
            (ticked, publishedCount(shop), publishedCount(ProjectId.default()))
        });
        Assert.assertEq(expected = (Ok(1), 1i64, 0i64), outcome)

    ///
    /// tick で公開された entry は、コンテンツ API の既定（PUBLISHED）で引ける。tick の前は無い。
    ///
    @Test
    def testPgScheduledPublishVisibleInContentApi(): Unit \ {IO, Assert} =
        let seed = () -> CmsTestKit.withIds(List#{"e1", "e2"}, () -> {
            seedEntries();
            discard Schedules.schedule(Session.grant(), CmsTestKit.entryId("e1"), ScheduleAction.Publish, past(), false)
        });
        let outcome = PgTestSupport.withContentApiAndPool(seed, (pool, ask) -> {
            let before = ask("{ blog(id: \"e1\") { title } blogs { totalCount } }") |> fst;
            let ticked = ServerTestKit.quietly(() -> Scheduler.tick(pool));
            (before, ticked, ask("{ blog(id: \"e1\") { title } blogs { totalCount } }") |> fst)
        });
        Assert.assertEq(
            expected = (
                Value.Obj(Map#{ "blog" => Value.Null, "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }),
                Ok(1),
                Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "title" => Value.Str("ok") }), "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) })),
            outcome)

    ///
    /// 参照先（p1）が未公開の b1 は、withDependencies 無しの予約では failed に理由が残り、withDependencies 有りなら参照先ごと公開される。
    ///
    ///   b1 { profile: p1 }   p1 は未公開
    ///
    @Test
    def testPgScheduleWithDependencies(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let aloneId = PgTestSupport.seed(() -> {
                let profiles = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("profiles", "書き手"));
                discard ContentTypes.addField(Session.grant(), profiles#id, CmsTestKit.fieldDraft("name", FieldKind.Text, FieldConfig.empty()));
                let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
                discard ContentTypes.addField(Session.grant(), blogs#id, { target = Some(profiles#id) | CmsTestKit.fieldDraft("profile", FieldKind.Reference, FieldConfig.empty()) });
                discard ContentEntries.create(Session.grant(), profiles#id, Some(CmsTestKit.entryId("p1")), CmsTestKit.entryData(List#{("name", Json.JString("山田"))}));
                discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b1")), CmsTestKit.entryData(List#{("profile", Json.JString("p1"))}));
                Schedules.schedule(Session.grant(), CmsTestKit.entryId("b1"), ScheduleAction.Publish, past(), false)#id
            });
            let aloneTick = ServerTestKit.quietly(() -> Scheduler.tick(pool));
            let alone = (statusOf(pool, aloneId), stageOf(pool, "b1"), stageOf(pool, "p1"));
            let togetherId = PgTestSupport.mutateOrBug(pool, () -> Schedules.schedule(Session.grant(), CmsTestKit.entryId("b1"), ScheduleAction.Publish, past(), true)#id);
            let togetherTick = ServerTestKit.quietly(() -> Scheduler.tick(pool));
            (aloneTick, alone, togetherTick, statusOf(pool, togetherId), stageOf(pool, "b1"), stageOf(pool, "p1"))
        });
        Assert.assertEq(
            expected = (
                Ok(1),
                ((ScheduleStatus.Failed, "references: 参照先 'p1' が未公開です（withDependencies: true で一緒に公開できます）"), Stage.Draft, Stage.Draft),
                Ok(1),
                (ScheduleStatus.Done, ""),
                Stage.Published,
                Stage.Published),
            outcome)

}
