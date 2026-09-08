///
/// BackgroundJobs.guarded: 1 周（tick）が JVM の例外で飛んでもワーカーが死なず、失敗の説明として次の周へ進める。
/// BackgroundJobs.shutdown: 停止の行を出してから止める。
///
mod TestBackgroundJobs {

    import java.lang.VerifyError

    /// 停止は `shutting down` を先に出し、周の途中でなければすぐ `jobs drained`。その後は新しい周を始めない（stopping）。
    @Test
    def testShutdownLogsThenStops(): Unit \ {Assert, IO} =
        let state = BackgroundJobs.createState(1i64);
        let (_, records) = Log.runWithList(() -> BackgroundJobs.shutdown(state));
        Assert.assertEq(
            expected = (List#{(Log.Severity.Info, "shutting down"), (Log.Severity.Info, "jobs drained")}, true),
            (records |> List.map(record -> (record#severity, record#message)), Ref.get(state#stopping)))

    /// 普通の周は結果をそのまま返す。
    @Test
    def testGuardedPassesThrough(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = List#{"a"}, ServerTestKit.quietly(() -> BackgroundJobs.guarded(() -> List#{"a"})))

    /// Error（VerifyError。リゾルバと同じ経路）が飛んだら、失敗の説明 1 件になる。
    @Test
    def testGuardedTurnsErrorIntoMessage(): Unit \ {Assert, IO} =
        Assert.assertEq(
            expected = List#{"1 周の途中で例外: stack map"},
            ServerTestKit.quietly(() -> BackgroundJobs.guarded(() -> { discard throw new VerifyError("stack map"); List#{"unreachable"} })))

}
