///
/// Scheduler.canClaimMore: 1 回の tick で次のチャンクを拾うかの判断（純粋な部分）。
/// Scheduler.chunkSize / budgetSeconds: 環境変数の値の読み取り。
///
mod TestScheduler {

    /// 直前のチャンクが満杯で、tick の予算（budgetMs）にまだ達していない時だけ次を拾う。
    /// 満杯でなければ時刻の来た予約は尽きている。予算に達したら残りは次の tick に譲る。
    @Test
    def testCanClaimMoreTable(): Unit \ Assert =
        let table = List#{
            // (開始, 今, 予算 ms, 直前のチャンクの件数, チャンクの大きさ) → 次を拾うか
            ((0i64, 0i64,     10000i64, 100, 100i64), true),
            ((0i64, 9999i64,  10000i64, 100, 100i64), true),
            ((0i64, 10000i64, 10000i64, 100, 100i64), false),
            ((0i64, 15000i64, 10000i64, 100, 100i64), false),
            ((0i64, 0i64,     10000i64, 99,  100i64), false),
            ((0i64, 0i64,     10000i64, 0,   100i64), false),
            ((0i64, 0i64,     0i64,     100, 100i64), false),
            ((5000i64, 14999i64, 10000i64, 100, 100i64), true),
            ((5000i64, 15000i64, 10000i64, 100, 100i64), false)
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match ((startedAt, now, budgetMs, lastChunkSize, chunkSize), _) ->
                Scheduler.canClaimMore({ startedAt = startedAt, now = now, budgetMs = budgetMs, lastChunkSize = lastChunkSize, chunkSize = chunkSize })))

    /// CMS_SCHEDULER_CHUNK_SIZE: 無い・数字でない・1 未満なら既定の 100。
    @Test
    def testChunkSizeTable(): Unit \ Assert =
        let table = List#{
            (None,        100i64),
            (Some("50"),  50i64),
            (Some("1"),   1i64),
            (Some("0"),   100i64),
            (Some("-1"),  100i64),
            (Some("abc"), 100i64),
            (Some(""),    100i64)
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(match (raw, _) -> Scheduler.chunkSize(raw)))

    /// CMS_SCHEDULER_TICK_BUDGET_SECONDS: 無い・数字でない・1 未満なら既定の 10。
    @Test
    def testBudgetSecondsTable(): Unit \ Assert =
        let table = List#{
            (None,        10i64),
            (Some("30"),  30i64),
            (Some("1"),   1i64),
            (Some("0"),   10i64),
            (Some("x"),   10i64)
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(match (raw, _) -> Scheduler.budgetSeconds(raw)))

    /// 既定の設定はチャンク 100 件、予算 10 秒。
    @Test
    def testDefaultConfig(): Unit \ Assert =
        Assert.assertEq(expected = (100i64, 10000i64), (Scheduler.defaultConfig()#chunkSize, Scheduler.defaultConfig()#budgetMs))

}
