///
/// DB 側の時間の上限（DbConfig.withTimeouts が URL に付ける options）が接続に効くか。
/// Tx を開いたまま idle にすると DB 側が接続を切り、次の SQL は失敗するが、接続はプールに返る（接続 1 本のプールでもう 1 度借りられる）。
/// 上限は 1 秒に縮め、このテスト用のプールを別に開く。
///
mod TestDbTimeoutPg {

    import java.lang.Thread

    /// 上限 1 秒、接続 1 本のプール。
    ///
    /// WhyNot: PgTestSupport.config() の URL をそのまま使わないのは、それは DbConfig.fromEnv を通っていて既定（30 秒）の
    /// options が付いており、withTimeouts は既にある options を上書きしないため。生の CMS_DSN から組む。
    def timeoutPool(): Pool \ IO =
        let owner = PgTestSupport.config();
        let dsn = (run { Sys.Env.getVar("CMS_DSN") } with Sys.Env.runWithIO) |> Option.getWithDefault(owner#url);
        Pool.open({ maxConnections = 1, borrowTimeoutMs = 500 | Pool.defaultConfig({ url = DbConfig.withTimeouts(1, dsn) | owner }) })

    /// 接続 1 本のプールからもう 1 度借りて SELECT 1 が通るか（Ok(1) なら返っている）。
    def borrowAgain(pool: Pool): Result[String, Int32] \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withLazyTx(pool, () -> Sql.fetch("SELECT 1", Nil) |> List.length)))
            |> Result.mapErr(failure -> "${failure}")

    /// Tx の中で 1.5 秒 idle にすると idle_in_transaction_session_timeout で切られ、次の SQL が失敗する。接続はプールに返り、次も借りられる。
    @Test
    def testPgIdleInTransactionIsCutAndConnectionReturns(): Unit \ {IO, Assert} =
        let pool = timeoutPool();
        let first = DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withLazyTx(pool, () -> {
            discard Sql.fetch("SELECT 1", Nil);
            Thread.sleep(1500i64);
            Sql.fetch("SELECT 1", Nil) |> List.length
        })));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (true, Ok(1)), (Result.isErr(first), second))

    /// 2 秒かかる SQL は statement_timeout で止められて失敗する。接続はプールに返り、次も借りられる。
    @Test
    def testPgLongStatementIsCancelledAndConnectionReturns(): Unit \ {IO, Assert} =
        let pool = timeoutPool();
        let first = DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withLazyTx(pool, () -> Sql.fetch("SELECT pg_sleep(2)", Nil) |> List.length)));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (true, Ok(1)), (Result.isErr(first), second))

}
