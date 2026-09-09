///
/// Health.ping と Health.saturation を実 PostgreSQL で確かめる。CMS_DSN は make test-pg が渡す。
///
mod TestHealthPg {

    import java.lang.System

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

    ///
    /// 接続 1 本のプールを借りたままにすると、Hikari の数字は active=1 / max=1 になり、Health.saturation が 100% を返す。
    /// /health が `status: degraded` を出す根拠がこれ。
    ///
    /// 借り待ちの上限を 30 秒にしてあるので、もし数字を読むのに接続を借りていれば、この 1 本が返るまで待って
    /// 30 秒かかる。1 秒で終わる事まで見て、「/health の中で待つ物を増やさない」を守れているかを確かめる。
    ///
    @Test
    def testPgHealthSaturationDoesNotBorrow(): Unit \ {IO, Assert} =
        let pool = Pool.open({ maxConnections = 1, borrowTimeoutMs = 30000 | Pool.defaultConfig(PgTestSupport.config()) });
        let startedAt = System.currentTimeMillis();
        let outcome = DbError.runWithFailure(() -> RawSql.runWithAllow(() ->
            Pool.withConnection(pool, _ -> {
                let stats = Pool.stats(pool);
                (Health.saturation(stats), stats#active, stats#max)
            })));
        let elapsedMs = System.currentTimeMillis() - startedAt;
        Pool.close(pool);
        Assert.assertEq(expected = (Ok((Some(100), 1, 1)), true), (outcome, elapsedMs < 1000i64))

    /// 借りていないプールは張り付いていない（active=0）。
    @Test
    def testPgHealthSaturationIdlePool(): Unit \ {IO, Assert} =
        let pool = Pool.open({ maxConnections = 1 | Pool.defaultConfig(PgTestSupport.config()) });
        discard Health.ping(pool);
        let saturation = Health.saturation(Pool.stats(pool));
        Pool.close(pool);
        Assert.assertEq(expected = None, saturation)

    /// パスワードが違っても open は例外にならず、ping が理由付きの Err を返す（起動時と /health で同じ道を通る）。
    @Test
    def testPgHealthPingWrongPassword(): Unit \ {IO, Assert} =
        let base = Pool.defaultConfig(PgTestSupport.config());
        let pool = Pool.open({ connection = { password = "wrong" | base#connection } | base });
        let result = Health.ping(pool);
        Pool.close(pool);
        Assert.assertTrue(Result.isErr(result))

}
