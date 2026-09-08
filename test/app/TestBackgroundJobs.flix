///
/// BackgroundJobs.guarded: 1 周（tick）が JVM の例外で飛んでもワーカーが死なず、失敗の説明として次の周へ進める。
/// BackgroundJobs.guardedPart: 予約公開・Webhook の部分が飛んでも、その部分の失敗として残りへ進める。
/// BackgroundJobs.guardedWatch: 見張りの 1 周が飛んでも Error の行を出して次の周へ進める。
/// BackgroundJobs.shutdown: 停止の行を出してから止める。
/// BackgroundJobs.nextWaitMs: 1 周が長くても次の周までの間隔が設定どおりになる。
///
mod TestBackgroundJobs {

    import java.lang.VerifyError

    /// 停止は `shutting down` を先に出し、周の途中でなければすぐ `jobs drained`。その後は新しい周を始めない（stopping）。
    @Test
    def testShutdownLogsThenStops(): Unit \ {Assert, IO} =
        let state = BackgroundJobs.createState(1i64, None);
        let (_, records) = Log.runWithList(() -> BackgroundJobs.shutdown(state));
        Assert.assertEq(
            expected = (List#{(Log.Severity.Info, "shutting down"), (Log.Severity.Info, "jobs drained")}, true),
            (records |> List.map(record -> (record#severity, record#message)), Ref.get(state#stopping)))

    /// 普通の周は結果をそのまま返す。
    @Test
    def testGuardedPassesThrough(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = List#{"a"}, BackgroundJobs.guarded(Log.Sink.silent(), () -> List#{"a"}))

    /// Error（VerifyError。リゾルバと同じ経路）が飛んだら、失敗の説明 1 件になる。
    @Test
    def testGuardedTurnsErrorIntoMessage(): Unit \ {Assert, IO} =
        Assert.assertEq(
            expected = List#{"1 周の途中で例外: stack map"},
            BackgroundJobs.guarded(Log.Sink.silent(), () -> { discard throw new VerifyError("stack map"); List#{"unreachable"} }))

    /// tick の中の run（Net.Http.runWithIO と同じ形）から Log の行を出した後、その run の中で例外が飛んでも受かる。
    /// Log の handler が try の内側にあるので、op が try を越えない。
    @Test
    def testGuardedCatchesInsideInnerRunAfterLog(): Unit \ {Assert, IO} =
        Assert.assertEq(
            expected = List#{"1 周の途中で例外: after log"},
            BackgroundJobs.guarded(Log.Sink.silent(), () -> Tenant.runWith(ProjectId.default(), () -> {
                Log.info("x", Log.Fields.empty());
                discard throw new VerifyError("after log");
                List#{"unreachable"}
            })))

    /// 部分の網: 通れば結果のまま、飛べば label 付きの失敗。外の Log の handler の下で Log を出してから飛んでも受かる（/jobs/tick の形）。
    @Test
    def testGuardedPartTable(): Unit \ {Assert, IO} =
        let (outcomes, _) = Log.runWithList(() -> (
            BackgroundJobs.guardedPart("Webhook", () -> Ok(3)),
            BackgroundJobs.guardedPart("Webhook", () -> Err("HTTP 500")),
            BackgroundJobs.guardedPart("予約公開", () -> { Log.info("x", Log.Fields.empty()); discard throw new VerifyError("stack map"); Ok(0) })));
        Assert.assertEq(expected = (Ok(3), Err("HTTP 500"), Err("予約公開の途中で例外: stack map")), outcomes)

    /// 見張りの網: 飛んだら `watch failed` の Error の行を 1 つ出して戻る（スレッドは死なない）。
    @Test
    def testGuardedWatchLogsAndContinues(): Unit \ {Assert, IO} =
        let records = Ref.fresh(Static, Nil);
        BackgroundJobs.guardedWatch(Log.Sink.collect(records), () -> { Log.info("ping", Log.Fields.empty()); throw new VerifyError("stats") });
        Assert.assertEq(
            expected = List#{(Log.Severity.Info, "ping", false), (Log.Severity.Error, "watch failed", true)},
            Ref.get(records) |> List.reverse |> List.map(record -> (record#severity, record#message, Map.memberOf("error.message", record#fields))))

    /// 2 秒の周期で、1 周に掛かった時間を引いた分だけ待つ。周期を超えた周（DB が詰まった時）の後は待たない。
    @Test
    def testNextWaitMsTable(): Unit \ Assert =
        let table = List#{
            ((2000i64, 0i64),     2000i64),
            ((2000i64, 500i64),   1500i64),
            ((2000i64, 2000i64),  0i64),
            ((2000i64, 15000i64), 0i64)
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match ((interval, elapsed), _) -> BackgroundJobs.nextWaitMs(interval, elapsed)))

}
