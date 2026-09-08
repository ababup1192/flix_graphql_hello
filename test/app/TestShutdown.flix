///
/// Shutdown: SIGTERM で待ち切れたかの判定と、その終了コード。CMS_SHUTDOWN_TIMEOUT_SECONDS の読み方。
///
mod TestShutdown {

    use Shutdown.Outcome

    /// 接続も仕事も残っていなければ Clean。どちらかが残っていれば TimedOut。
    @Test
    def testDecideTable(): Unit \ Assert =
        let table = List#{
            ({ connections = 0, inTick = false }, Outcome.Clean),
            ({ connections = 3, inTick = false }, Outcome.TimedOut),
            ({ connections = 0, inTick = true },  Outcome.TimedOut),
            ({ connections = 3, inTick = true },  Outcome.TimedOut)
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (remaining, _) -> Shutdown.decide(remaining)))

    /// 綺麗に停止したら 0、待ち切れなかったら 2（3 は自己回復が使う）。
    @Test
    def testExitCodeTable(): Unit \ Assert =
        let table = List#{ (Outcome.Clean, 0), (Outcome.TimedOut, 2) };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (outcome, _) -> Shutdown.exitCode(outcome)))

    /// 無い・数字でない・0 以下なら既定の 20 秒。
    @Test
    def testTimeoutSecondsTable(): Unit \ Assert =
        let table = List#{ (None, 20i64), (Some("60"), 60i64), (Some("abc"), 20i64), (Some("0"), 20i64), (Some("-3"), 20i64) };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (raw, _) -> Shutdown.timeoutSeconds(raw)))

}
