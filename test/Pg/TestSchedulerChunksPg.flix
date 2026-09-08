///
/// 予約公開のチャンク化を実 PostgreSQL で見る。同じ時刻の予約がチャンク（100 件）より多くても、1 回の tick が予算の中で
/// 拾い直して全部公開する。予算が尽きれば残りは pending のまま次の tick に譲る。
///
mod TestSchedulerChunksPg {

    use Util.Json.Json

    def past(): Timestamp.Timestamp = Timestamp.at("2020-01-01T00:00:00Z")

    /// blogs に e1..eN（title 有り）を置き、全部を同じ過去の時刻で publish に予約する。
    def seedSchedules(count: Int32): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, { required = true | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
        List.range(1, count + 1) |> List.forEach(index -> {
            let entryId = CmsTestKit.entryId("e${index}");
            discard ContentEntries.create(Session.grant(), blogs#id, Some(entryId), CmsTestKit.entryData(List#{("title", Json.JString("post ${index}"))}));
            discard Schedules.schedule(Session.grant(), entryId, ScheduleAction.Publish, past(), false)
        })

    /// 予約の状態ごとの件数（pending, running, done, failed）。
    def scheduleCounts(): (Int64, Int64, Int64, Int64) \ IO =
        let count = status -> PgTestSupport.countSql("SELECT count(*)::bigint AS total FROM scheduled_actions WHERE status = $1", SqlValue.Str(status) :: Nil);
        (count("pending"), count("running"), count("done"), count("failed"))

    /// 公開中の entry の数。
    def publishedCount(): Int64 \ IO =
        PgTestSupport.countSql("SELECT count(*)::bigint AS total FROM entries WHERE stage = 'published'", Nil)

    ///
    /// 同じ時刻の予約 300 件は、チャンク 100 件の 1 回の tick で全部 done になり、entry も全部公開される（job.* の行も 300）。
    ///
    /// WhyNot: 予算を既定の 10 秒にしないのは、CI の遅い DB で 300 件の公開が 10 秒を越えると残りが次の tick に譲られ、
    /// 「1 回で全部」を見るテストが環境で揺れるため。予算が尽きた時の振る舞いは下のテストが見る。
    ///
    @Test
    def testPgTickRunsAllChunksWithinBudget(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> seedSchedules(300));
            let (ticked, records) = Log.runWithList(() -> Scheduler.tickWith({ chunkSize = 100i64, budgetMs = 600000i64 }, pool));
            let doneRows = records |> List.filter(record -> Map.get("job.outcome", record#fields) == Some(Value.Str("done"))) |> List.length;
            (ticked, scheduleCounts(), publishedCount(), doneRows)
        });
        Assert.assertEq(expected = (Ok(300), (0i64, 0i64, 300i64, 0i64), 300i64, 300), outcome)

    ///
    /// 予算が 1 ミリ秒なら最初のチャンク（100 件）だけ実行し、残り 200 件は claim されず pending のまま。次の tick が拾う。
    ///
    @Test
    def testPgTickStopsAtBudgetAndLeavesRestPending(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> seedSchedules(300));
            let firstTick = ServerTestKit.quietly(() -> Scheduler.tickWith({ chunkSize = 100i64, budgetMs = 1i64 }, pool));
            let afterFirst = scheduleCounts();
            let secondTick = ServerTestKit.quietly(() -> Scheduler.tickWith({ chunkSize = 100i64, budgetMs = 600000i64 }, pool));
            (firstTick, afterFirst, secondTick, scheduleCounts(), publishedCount())
        });
        Assert.assertEq(expected = (Ok(100), (200i64, 0i64, 100i64, 0i64), Ok(200), (0i64, 0i64, 300i64, 0i64), 300i64), outcome)

}
