///
/// Tx の中で業務エラー（CmsErr）・DB の失敗（DbErr）・JVM の例外が起きた時に、接続がプールへ返るか。
/// 接続 1 本のプールで、失敗の後にもう 1 度借りられれば返っている。借りられなければ「idle in transaction」で漏れている。
///
mod TestTxLeakPg {

    import java.lang.Integer

    def singlePool(): Pool \ IO =
        Pool.open({ maxConnections = 1, borrowTimeoutMs = 500 | Pool.defaultConfig(PgTestSupport.config()) })

    /// 接続 1 本のプールからもう 1 度借りて SELECT 1 が通るか（Ok(1) なら返っている）。
    def borrowAgain(pool: Pool): Result[String, Int32] \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withLazyTx(pool, () -> Sql.fetch("SELECT 1", Nil) |> List.length)))
            |> Result.mapErr(failure -> "${failure}")

    /// Runner と同じ DbRunner.transact で、SQL を 1 本流してから業務エラー。ROLLBACK されて接続が返り、次も借りられる。
    @Test
    def testPgCmsErrInsideTxReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let first = RawSql.runWithAllow(() -> DbRunner.transact(pool, None, () -> {
            let rows = Sql.fetch("SELECT 1", Nil) |> List.length;
            if (rows == 0) rows else CmsErr.notFound(Entity.Entry, "x")
        }));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (Ok(Err(CmsErr.CmsFailure.NotFound(Entity.Entry, "x"))), Ok(1)), (first, second))

    /// DB の失敗（無い表を叩く = DbErr）は再実行しない失敗として返り、ROLLBACK されて接続が返る。
    @Test
    def testPgDbErrInsideTxReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let first = RawSql.runWithAllow(() -> DbRunner.transact(pool, None, () -> {
            discard Sql.fetch("SELECT 1", Nil);
            Sql.fetch("SELECT 1 FROM no_such_table", Nil) |> List.length
        })) |> Result.mapErr(failure -> String.startsWith(prefix = "Permanent", "${failure}"));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (Err(true), Ok(1)), (first, second))

    /// Runner と同じ入れ子（IdGen / Tenant / Clock の handler が transact の外、Session が中、f を Db.guard で直に包む）で、
    /// effect を使った後に JVM の例外（リゾルバの VerifyError と同じ経路）が飛んでも、DB の失敗として返り、接続が返る。
    ///
    /// WhyNot: sqlfx の withLazyTx の catch に任せないのは、catch の内側に handler（Session.runWith）が入ると例外が catch を素通りするため（2026-09-08 に 0.4.0 でも実測）。
    @Test
    def testPgExceptionAfterEffectsInsideRunnerNestingReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let first = RawSql.runWithAllow(() -> IdGen.runWithRandom(() -> Tenant.runWith(ProjectId.default(), () -> Time.Clock.runWithIO(() ->
            DbRunner.transact(pool, None, () -> Session.runWith(Actor.System, () -> Db.guard(() -> {
                discard Sql.fetch("SELECT 1", Nil);
                discard IdGen.freshEntryId();
                discard Tenant.current();
                discard Time.Clock.now();
                Session.require(Permission.ReadDraft);
                Integer.parseInt("boom")
            })))))))
            |> Result.mapErr(failure -> String.contains(substr = "boom", "${failure}"));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (Err(true), Ok(1)), (first, second))

    /// JVM の例外（Java interop が投げる NumberFormatException）が Tx の中で飛んでも、DB の失敗として返り、接続が返る。
    @Test
    def testPgExceptionInsideTxReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let first = RawSql.runWithAllow(() -> DbRunner.transact(pool, None, () -> {
            discard Sql.fetch("SELECT 1", Nil);
            Integer.parseInt("boom")
        })) |> Result.mapErr(failure -> String.contains(substr = "boom", "${failure}"));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (Err(true), Ok(1)), (first, second))

}
