///
/// PoolActivity: HikariCP の tracker が「接続が返った」を受けるたびに lastReturnedAt が今の時刻に進む。他の記録では動かない。
/// 実 PG でプールに付けた形は test/Pg/TestPoolActivityPg。
///
mod TestPoolActivity {

    import com.zaxxer.hikari.metrics.IMetricsTracker
    import java.lang.System

    /// 返っていなければ None、返れば Some(今)。借りた・作った・待ち切れなかったの記録では None のまま。
    @Test
    def testTrackerRecordsOnlyReturns(): Unit \ {Assert, IO} =
        let lastReturnedAt = PoolActivity.create();
        let tracker: IMetricsTracker = PoolActivity.tracker(lastReturnedAt);
        let untouched = Ref.get(lastReturnedAt);
        tracker.recordConnectionCreatedMillis(1i64);
        tracker.recordConnectionAcquiredNanos(1i64);
        tracker.recordConnectionTimeout();
        let stillUntouched = Ref.get(lastReturnedAt);
        let before = System.currentTimeMillis();
        tracker.recordConnectionUsageMillis(5i64);
        let recorded = Ref.get(lastReturnedAt) |> Option.exists(at -> at >= before and at <= System.currentTimeMillis());
        Assert.assertEq(expected = (None, None, true), (untouched, stillUntouched, recorded))

}
