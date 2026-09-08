///
/// Health.ping を実 PostgreSQL で確かめる。CMS_DSN は make test-pg が渡す。
///
mod TestHealthPg {

    /// 正しい接続先なら ping は Ok。
    @Test
    def testPgHealthPing(): Unit \ {IO, Assert} =
        Assert.assertEq(expected = Ok(()), PgTestSupport.withPool(Health.ping))

    /// /health の道（借り待ちの上限付き）でも、正しい接続先なら Ok。
    @Test
    def testPgHealthPingWithin(): Unit \ {IO, Assert} =
        Assert.assertEq(expected = Ok(()), PgTestSupport.withPool(pool -> Health.pingWithin(pool, 2000)))

    /// 接続 1 本のプールが借りられたままなら、/health の ping は上限で切れて timeout の Err を返す（プールの borrowTimeoutMs を待たない）。
    @Test
    def testPgHealthPingWithinTimesOut(): Unit \ {IO, Assert} =
        let pool = Pool.open({ maxConnections = 1, borrowTimeoutMs = 30000 | Pool.defaultConfig(PgTestSupport.config()) });
        let result = DbError.runWithFailure(() -> RawSql.runWithAllow(() ->
            Pool.withConnection(pool, _ -> Health.pingWithin(pool, 200))));
        Pool.close(pool);
        Assert.assertEq(expected = Ok(Err("timeout 200")), result)

    /// パスワードが違っても open は例外にならず、ping が理由付きの Err を返す（起動時と /health で同じ道を通る）。
    @Test
    def testPgHealthPingWrongPassword(): Unit \ {IO, Assert} =
        let base = Pool.defaultConfig(PgTestSupport.config());
        let pool = Pool.open({ connection = { password = "wrong" | base#connection } | base });
        let result = Health.ping(pool);
        Pool.close(pool);
        Assert.assertTrue(Result.isErr(result))

}
