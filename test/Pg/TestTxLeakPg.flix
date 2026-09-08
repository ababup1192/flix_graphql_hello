///
/// Tx の中で業務エラー（CmsErr）・DB の失敗（DbErr）・JVM の例外が起きた時に、接続がプールへ返るか。
/// 接続 1 本のプールで、失敗の後にもう 1 度借りられれば返っている。借りられなければ「idle in transaction」で漏れている。
///
mod TestTxLeakPg {

    import java.lang.Integer
    import java.lang.NumberFormatException

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
        let first = RawSql.runWithAllow(() -> DbRunner.transact(pool, None, Actor.System, () -> {
            let rows = Sql.fetch("SELECT 1", Nil) |> List.length;
            if (rows == 0) rows else CmsErr.notFound(Entity.Entry, "x")
        }));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (Err(ApplicationFailure.Domain(CmsErr.CmsFailure.NotFound(Entity.Entry, "x"))), Ok(1)), (first, second))

    /// BEGIN の直後に流す onBegin（TenantTx が RLS の印を置く所と同じ経路）が JVM の例外を投げても、接続が返る（sqlfx 0.4.2 から）。
    @Test
    def testPgExceptionInOnBeginReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let first = DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withLazyTxAfterBegin(pool,
            () -> { discard Sql.fetch("SELECT 1", Nil); if (Integer.parseInt("boom") == 0) () else () },
            () -> Sql.fetch("SELECT 1", Nil) |> List.length)))
            |> Result.mapErr(failure -> String.contains(substr = "boom", "${failure}"));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (Err(true), Ok(1)), (first, second))

    /// DB の失敗（無い表を叩く = DbErr）は再実行しない失敗として返り、ROLLBACK されて接続が返る。
    @Test
    def testPgDbErrInsideTxReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let first = RawSql.runWithAllow(() -> DbRunner.transact(pool, None, Actor.System, () -> {
            discard Sql.fetch("SELECT 1", Nil);
            Sql.fetch("SELECT 1 FROM no_such_table", Nil) |> List.length
        })) |> Result.mapErr(failure -> String.startsWith(prefix = "Infrastructure(Permanent", "${failure}"));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (Err(true), Ok(1)), (first, second))

    /// Runner と同じ入れ子（IdGen / Tenant / Clock の handler が transact の外。Session の handler と Db.guard は transact が入れる）で、
    /// f が effect を使った後に JVM の例外（リゾルバの VerifyError と同じ経路）を投げても、DB の失敗として返り、接続が返る。
    ///
    /// WhyNot: sqlfx の withLazyTx の catch に任せないのは、catch の内側に handler（Session.runWith）が入ると例外が catch を素通りするため（2026-09-08 に 0.4.0 でも実測）。
    @Test
    def testPgExceptionAfterEffectsInsideTransactReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let first = RawSql.runWithAllow(() -> IdGen.runWithRandom(() -> Tenant.runWith(ProjectId.default(), () -> Time.Clock.runWithIO(() ->
            DbRunner.transact(pool, None, Actor.System, () -> {
                discard Sql.fetch("SELECT 1", Nil);
                discard IdGen.freshEntryId();
                discard Tenant.current();
                discard Time.Clock.now();
                discard (Session.grant() : Granted[ReadDraft]);
                Integer.parseInt("boom")
            })))))
            |> Result.mapErr(failure -> String.contains(substr = "boom", "${failure}"));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (Err(true), Ok(1)), (first, second))

    /// JVM の例外（Java interop が投げる NumberFormatException）が Tx の中で飛んでも、DB の失敗として返り、接続が返る。
    @Test
    def testPgExceptionInsideTxReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let first = RawSql.runWithAllow(() -> DbRunner.transact(pool, None, Actor.System, () -> {
            discard Sql.fetch("SELECT 1", Nil);
            Integer.parseInt("boom")
        })) |> Result.mapErr(failure -> String.contains(substr = "boom", "${failure}"));
        let second = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(expected = (Err(true), Ok(1)), (first, second))

    // ---- 読むだけの文書の 1 リクエスト 1 Tx（共有の接続） ----

    /// リクエストの Tx の持ち物（既定のプロジェクトの印、System）。
    def requestTx(pool: Pool): RequestTx.Handle \ IO =
        DbRunner.openRequestTx(pool, Some(ProjectId.default()), Actor.System, Ref.fresh(Static, None))

    /// 共有の接続で 1 フィールドぶん走らせ、走ったか（Ran = true）と失敗の文言を返す。
    def fieldOn(handle: RequestTx.Handle, thunk: Unit -> a \ ef): (Bool, Option[String]) \ (ef - {Db, CmsErr, Session, RawSql}) + IO =
        match RawSql.runWithAllow(() -> DbRunner.transactShared(handle, _ -> (), Actor.System, thunk)) {
            case RequestTx.Attempt.Ran(Ok(_))       => (true, None)
            case RequestTx.Attempt.Ran(Err(failure)) => (true, Some(ApplicationFailure.describe(failure)))
            case RequestTx.Attempt.Skipped(failure) => (false, Some(DbError.describeFailure(failure)))
        }

    ///
    /// 共有の接続で SQL を 1 本流してから業務エラー。Tx は続き、次のフィールドも同じ接続で走り、閉じると COMMIT。接続は返る。
    ///
    @Test
    def testPgSharedTxCmsErrKeepsGoingAndReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let handle = requestTx(pool);
        let first = fieldOn(handle, () -> { discard Sql.fetch("SELECT 1", Nil); CmsErr.notFound(Entity.Entry, "x") });
        let second = fieldOn(handle, () -> Sql.fetch("SELECT 1", Nil) |> List.length);
        let closed = DbRunner.closeRequestTx(handle);
        let again = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(
            expected = ((true, Some("entry 'x' が見つかりません")), (true, None), RequestTx.Outcome.Committed, 1i64, Ok(1)),
            (first, second, closed#outcome, closed#transactions, again))

    ///
    /// 共有の接続で DB の失敗（無い表）。そのフィールドは走って失敗、次のフィールドは走らず（Skipped）同じ失敗、閉じると ROLLBACK。接続は返る。
    ///
    @Test
    def testPgSharedTxDbErrBreaksAndReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let handle = requestTx(pool);
        let first = fieldOn(handle, () -> { discard Sql.fetch("SELECT 1", Nil); Sql.fetch("SELECT 1 FROM no_such_table", Nil) |> List.length });
        let second = fieldOn(handle, () -> Sql.fetch("SELECT 1", Nil) |> List.length);
        let closed = DbRunner.closeRequestTx(handle);
        let again = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(
            expected = ((true, true), (false, true), RequestTx.Outcome.RolledBack, true, Ok(1)),
            ((fst(first), snd(first) |> Option.exists(String.contains(substr = "no_such_table"))),
             (fst(second), snd(second) |> Option.exists(String.contains(substr = "no_such_table"))),
             closed#outcome, Option.nonEmpty(closed#brokenBy), again))

    ///
    /// 共有の接続で effect を使った後に JVM の例外。DB の失敗として Broken になり、閉じると ROLLBACK。接続は返る。
    ///
    @Test
    def testPgSharedTxExceptionBreaksAndReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let handle = requestTx(pool);
        let first = IdGen.runWithRandom(() -> Tenant.runWith(ProjectId.default(), () -> fieldOn(handle, () -> {
            discard Sql.fetch("SELECT 1", Nil);
            discard IdGen.freshEntryId();
            discard (Session.grant() : Granted[ReadDraft]);
            Integer.parseInt("boom")
        })));
        let closed = DbRunner.closeRequestTx(handle);
        let again = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(
            expected = ((true, true), RequestTx.Outcome.RolledBack, Ok(1)),
            ((fst(first), snd(first) |> Option.exists(String.contains(substr = "boom"))), closed#outcome, again))

    ///
    /// withRequestTx の body（文書の実行）が接続を借りた後に JVM の例外で抜けても、Tx は閉じられ（COMMIT）接続が返り、例外はそのまま届く。
    ///
    @Test
    def testPgWithRequestTxClosesAfterThrowReturnsConnection(): Unit \ {IO, Assert} =
        let pool = singlePool();
        let observed = Ref.fresh(Static, Log.Fields.empty());
        let thrown = fst(Log.runWithList(() ->
            try {
                "no exception: ${DbRunner.withRequestTx(pool, Some(ProjectId.default()), Actor.System, fields -> Ref.put(LogFields.mergeCounts(fields, Ref.get(observed)), observed), Ref.fresh(Static, None), handle -> {
                    discard fieldOn(handle, () -> Sql.fetch("SELECT 1", Nil) |> List.length);
                    Integer.parseInt("boom")
                })}"
            } catch {
                case _: NumberFormatException => "caught"
            }));
        let again = borrowAgain(pool);
        Pool.close(pool);
        Assert.assertEq(
            expected = ("caught", Some(Value.Str("committed")), Some(Value.Int(1)), Ok(1)),
            (thrown, Map.get("db.tx.outcome", Ref.get(observed)), Map.get("db.transactions", Ref.get(observed)), again))

}
