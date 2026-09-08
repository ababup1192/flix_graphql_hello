///
/// 接続がプールに最後に返った時刻。HikariCP の IMetricsTracker（接続がプールに返るたびに `recordConnectionUsageMillis` が呼ばれる）で記録し、
/// SelfHeal が「プールは流れている（満杯なだけ）」と「壊れて戻らない」を分けるのに読む。
///
/// WhyNot: DbRunner の COMMIT / ROLLBACK の出口で記録しないのは、接続が返る道が transact / withTx / closeRequestTx / Health.ping /
/// Pool.withConnection と複数あり、その全部に Ref を配るには pool を受け取る 40 か所の署名を変える必要があるため。
/// 2026-09-08 の実機 E2E では closeRequestTx だけが記録していたので、304（withTx で版を読むだけ）の負荷中に PG が復旧して 200 が返り始めても
/// 「Tx が閉じていない」のままで、復旧の 3.4 秒後に自己回復が exit 3 した。Hikari の recycle は接続が返る道の全部が通る 1 か所で、
/// プロセスに 1 つの Ref を起動時に付けるだけで済む。
///
mod PoolActivity {

    import com.zaxxer.hikari.metrics.IMetricsTracker
    import com.zaxxer.hikari.metrics.MetricsTrackerFactory
    import com.zaxxer.hikari.metrics.{PoolStats => HikariPoolStats}
    import java.lang.System

    ///
    /// 接続がプールに最後に返った時刻（UNIX ミリ秒）。まだ 1 本も返っていなければ None。
    ///
    pub type alias LastReturnedAt = Ref[Option[Int64], Static]

    pub def create(): LastReturnedAt \ IO =
        Ref.fresh(Static, None)

    ///
    /// プールに tracker を付ける。以後、接続が返るたびに lastReturnedAt が進む。プールごとに 1 回だけ（Hikari は 2 回目を断る）。
    ///
    pub def attach(pool: Pool, lastReturnedAt: LastReturnedAt): Unit \ IO =
        let Pool.Pool(dataSource) = pool;
        dataSource.setMetricsTrackerFactory(factory(lastReturnedAt))

    ///
    /// 接続が返った時刻を lastReturnedAt に置く tracker。他の記録（借りた・作った・待ち切れなかった）は捨てる。
    ///
    pub def tracker(lastReturnedAt: LastReturnedAt): IMetricsTracker \ IO =
        new IMetricsTracker {
            def recordConnectionUsageMillis(_this: IMetricsTracker, _elapsedBorrowedMs: Int64): Unit \ IO =
                Ref.put(Some(System.currentTimeMillis()), lastReturnedAt)
        }

    def factory(lastReturnedAt: LastReturnedAt): MetricsTrackerFactory \ IO =
        new MetricsTrackerFactory {
            def create(_this: MetricsTrackerFactory, _poolName: String, _stats: HikariPoolStats): IMetricsTracker \ IO =
                tracker(lastReturnedAt)
        }

}
