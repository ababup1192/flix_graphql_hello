///
/// PoolActivity を実 PG のプールに付けると、接続が返る道のどれでも（withTx / transact / closeRequestTx / Health.ping）lastReturnedAt が進む。
/// SelfHeal はこの値で「満杯か作り直しの最中」と「壊れて戻らない」を分ける。
///
mod TestPoolActivityPg {

    /// 返った時刻が前の値より進んだか（None → Some も進んだと数える）。
    def advanced(before: Option[Int64], after: Option[Int64]): Bool = match (before, after) {
        case (_, None)                => false
        case (None, Some(_))          => true
        case (Some(old), Some(fresh)) => fresh >= old
    }

    /// 4 つの道を順に通し、それぞれの後で値が進んでいる。付けた直後は None。
    @Test
    def testPgEveryReturnPathAdvances(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let lastReturnedAt = PoolActivity.create();
            PoolActivity.attach(pool, lastReturnedAt);
            let attached = Ref.get(lastReturnedAt);
            discard RawSql.runWithAllow(() -> DbRunner.withTx(pool, None, () -> Sql.fetch("SELECT 1", Nil) |> List.length));
            let afterWithTx = Ref.get(lastReturnedAt);
            discard RawSql.runWithAllow(() -> DbRunner.transact(pool, Some(ProjectId.default()), Actor.System, () -> Sql.fetch("SELECT 1", Nil) |> List.length));
            let afterTransact = Ref.get(lastReturnedAt);
            let handle = DbRunner.openRequestTx(pool, Some(ProjectId.default()), Actor.System);
            discard RawSql.runWithAllow(() -> DbRunner.transactShared(handle, _ -> (), Actor.System, () -> Sql.fetch("SELECT 1", Nil) |> List.length));
            discard DbRunner.closeRequestTx(handle);
            let afterRequestTx = Ref.get(lastReturnedAt);
            discard Health.ping(pool);
            let afterPing = Ref.get(lastReturnedAt);
            (attached, advanced(attached, afterWithTx), advanced(afterWithTx, afterTransact), advanced(afterTransact, afterRequestTx), advanced(afterRequestTx, afterPing))
        });
        Assert.assertEq(expected = (None, true, true, true, true), outcome)

}
