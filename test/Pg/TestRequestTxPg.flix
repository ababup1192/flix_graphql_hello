///
/// 読むだけの文書の 1 リクエスト 1 Tx（RequestTx）を実 PostgreSQL で見る: 共有の接続でも RLS の印が効く事と、
/// REPEATABLE READ で文書の途中の COMMIT が見えない事。
///
mod TestRequestTxPg {

    /// 共有の接続で content_types を数える（生成された query。RLS の印が無ければ 0 行）。
    def countTypesOn(handle: RequestTx.Handle): Int32 \ IO =
        match DbRunner.transactShared(handle, _ -> (), Actor.System, () -> ContentTypesQueries.listContentTypes(ProjectId.toInt64(ProjectId.default())) |> List.length) {
            case RequestTx.Attempt.Ran(Ok(count))    => count
            case RequestTx.Attempt.Ran(Err(failure)) => bug!("count: ${ApplicationFailure.describe(failure)}")
            case RequestTx.Attempt.Skipped(failure)  => bug!("skipped: ${DbError.describeFailure(failure)}")
        }

    /// scope の印でリクエストの Tx を開いて数え、閉じる。
    def countTypesWith(pool: Pool, scope: Option[ProjectId]): Int32 \ IO =
        let handle = DbRunner.openRequestTx(pool, scope, Actor.System, Ref.fresh(Static, None));
        let count = countTypesOn(handle);
        discard DbRunner.closeRequestTx(handle);
        count

    /// 既定のプロジェクトに型を 2 つ置く。
    def seedTwoTypes(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        discard ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("tags", "タグ"));
        discard ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"))

    ///
    /// 共有の接続（READ ONLY, REPEATABLE READ）でも BEGIN の直後に置いた印が効く: 既定のプロジェクトの印なら 2 行、印の無い Tx なら 0 行。
    ///
    @Test
    def testPgRequestTxStampsProject(): Unit \ {IO, Assert} =
        PgTestSupport.seed(seedTwoTypes);
        let counts = PgTestSupport.withPool(pool -> (countTypesWith(pool, Some(ProjectId.default())), countTypesWith(pool, None)));
        Assert.assertEq(expected = (2, 0), counts)

    ///
    /// REPEATABLE READ: リクエストの Tx が最初の SQL で snapshot を取った後に別の Tx が型を足して COMMIT しても、同じ Tx の中では見えない（2 のまま）。
    /// 閉じた後の新しい Tx では見える（3）。
    ///
    ///   request Tx: count=2 ─────────── count=2 ─┐ COMMIT
    ///   other Tx:          create(pages) COMMIT   │
    ///   new request Tx:                           └─▶ count=3
    ///
    @Test
    def testPgRequestTxRepeatableRead(): Unit \ {IO, Assert} =
        PgTestSupport.seed(seedTwoTypes);
        let counts = PgTestSupport.withPool(pool -> {
            let handle = DbRunner.openRequestTx(pool, Some(ProjectId.default()), Actor.System, Ref.fresh(Static, None));
            let before = countTypesOn(handle);
            discard PgTestSupport.mutateOrBug(pool, () -> ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("pages", "ページ")));
            let during = countTypesOn(handle);
            let closed = DbRunner.closeRequestTx(handle);
            (before, during, closed#outcome, countTypesWith(pool, Some(ProjectId.default())))
        });
        Assert.assertEq(expected = (2, 2, RequestTx.Outcome.Committed, 3), counts)

    ///
    /// READ ONLY: 共有の接続で書くと DB が断り（25006）、そのフィールドは INTERNAL、Tx は Broken で閉じると ROLLBACK。
    /// 管理 API の Query 側のリゾルバが書く道に迷い込んだ時に、ここで気付く。
    ///
    @Test
    def testPgRequestTxRejectsWrites(): Unit \ {IO, Assert} =
        PgTestSupport.seed(seedTwoTypes);
        let outcome = PgTestSupport.withPool(pool -> {
            let handle = DbRunner.openRequestTx(pool, Some(ProjectId.default()), Actor.System, Ref.fresh(Static, None));
            let written = RawSql.runWithAllow(() -> DbRunner.transactShared(handle, _ -> (), Actor.System, () -> Sql.execute("UPDATE content_types SET name = name", Nil)));
            let closed = DbRunner.closeRequestTx(handle);
            (match written { case RequestTx.Attempt.Ran(Err(failure)) => String.contains(substr = "read-only", ApplicationFailure.describe(failure)) case _ => false }, closed#outcome)
        });
        Assert.assertEq(expected = (true, RequestTx.Outcome.RolledBack), outcome)

}
