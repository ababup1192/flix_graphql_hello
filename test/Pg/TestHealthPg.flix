///
/// Health.ping を実 PostgreSQL で確かめる。CMS_DSN は make test-pg が渡す。
///
mod TestHealthPg {

    /// 正しい接続先なら ping は Ok。
    @Test
    def testPgHealthPing(): Unit \ {IO, Assert} =
        Assert.assertEq(expected = Ok(()), PgTestSupport.withPool(Health.ping))

    /// パスワードが違っても open は例外にならず、ping が理由付きの Err を返す（起動時と /health で同じ道を通る）。
    @Test
    def testPgHealthPingWrongPassword(): Unit \ {IO, Assert} =
        let base = Pool.defaultConfig(PgTestSupport.config());
        let pool = Pool.open({ connection = { password = "wrong" | base#connection } | base });
        let result = Health.ping(pool);
        Pool.close(pool);
        Assert.assertTrue(Result.isErr(result))

}
