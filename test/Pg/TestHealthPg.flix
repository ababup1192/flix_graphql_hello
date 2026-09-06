///
/// Health.ping を実 PostgreSQL で確かめる。CMS_DSN は make test-pg が渡す。
///

/// 正しい接続先なら ping は Ok。
@Test
def testPgHealthPing(): Unit \ {IO, Assert} =
    let pool = Pool.open(Pool.defaultConfig(PgTestSupport.config()));
    let result = Health.ping(pool);
    Pool.close(pool);
    Assert.assertEq(expected = Ok(()), result)

/// パスワードが違っても open は例外にならず、ping が理由付きの Err を返す（起動時と /health で同じ道を通る）。
@Test
def testPgHealthPingWrongPassword(): Unit \ {IO, Assert} =
    let config = PgTestSupport.config();
    let pool = Pool.open({ connection = { url = config#url, user = config#user, password = "wrong" }, maxConnections = 1, borrowTimeoutMs = 2000 });
    let result = Health.ping(pool);
    Pool.close(pool);
    Assert.assertTrue(Result.isErr(result))
