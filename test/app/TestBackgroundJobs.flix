///
/// BackgroundJobs.guarded: 1 周（tick）が JVM の例外で飛んでもワーカーが死なず、失敗の説明として次の周へ進める。
///
mod TestBackgroundJobs {

    import java.lang.VerifyError

    /// 普通の周は結果をそのまま返す。
    @Test
    def testGuardedPassesThrough(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = List#{"a"}, BackgroundJobs.guarded(() -> List#{"a"}))

    /// Error（VerifyError。リゾルバと同じ経路）が飛んだら、失敗の説明 1 件になる。
    @Test
    def testGuardedTurnsErrorIntoMessage(): Unit \ {Assert, IO} =
        Assert.assertEq(
            expected = List#{"1 周の途中で例外: stack map"},
            BackgroundJobs.guarded(() -> { discard throw new VerifyError("stack map"); List#{"unreachable"} }))

}
