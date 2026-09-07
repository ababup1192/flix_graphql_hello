///
/// Tx の中で業務エラー（CmsErr）を投げた時に、接続がプールへ返るか。
/// 接続 1 本のプールで、CmsErr の後にもう 1 度借りられれば返っている。借りられなければ「idle in transaction」で漏れている。
///
mod TestTxLeakPg {

    /// Runner と同じ DbRunner.transact で、SQL を 1 本流してから業務エラー。ROLLBACK されて接続が返り、次も借りられる。
    @Test
    def testPgCmsErrInsideTxReturnsConnection(): Unit \ {IO, Assert} =
        let pool = Pool.open({ connection = PgTestSupport.config(), maxConnections = 1, borrowTimeoutMs = 500 });
        let first = RawSql.runWithAllow(() -> DbRunner.transact(pool, None, () -> {
            let rows = Sql.fetch("SELECT 1", Nil) |> List.length;
            if (rows == 0) rows else CmsErr.notFound(Entity.Entry, "x")
        }));
        let second = DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withLazyTx(pool, () -> Sql.fetch("SELECT 1", Nil) |> List.length)))
            |> Result.mapErr(failure -> "${failure}");
        Pool.close(pool);
        Assert.assertEq(expected = (Ok(Err(CmsErr.CmsFailure.NotFound(Entity.Entry, "x"))), Ok(1)), (first, second))

}
