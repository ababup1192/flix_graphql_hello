///
/// Health.ping を実 PostgreSQL で確かめる。CMS_DSN は make test-pg が渡す。
///

///
/// 接続設定。CMS_DSN が無ければ即 panic（黙って成功させない）。
///
def pgConfig(): Jdbc.ConnectionConfig \ IO =
    run {
        match DbConfig.fromEnv() {
            case Ok(config)   => config
            case Err(message) => bug!("${message}。make test-pg で回す")
        }
    } with Sys.Env.runWithIO

/// 正しい接続先なら ping は Ok。
@Test
def testPgHealthPing(): Unit \ {IO, Assert} =
    let pool = Pool.open(Pool.defaultConfig(pgConfig()));
    let result = Health.ping(pool);
    Pool.close(pool);
    Assert.assertEq(expected = Ok(()), result)

/// パスワードが違っても open は例外にならず、ping が理由付きの Err を返す（起動時と /health で同じ道を通る）。
@Test
def testPgHealthPingWrongPassword(): Unit \ {IO, Assert} =
    let config = pgConfig();
    let pool = Pool.open({ connection = { url = config#url, user = config#user, password = "wrong" }, maxConnections = 1, borrowTimeoutMs = 2000 });
    let result = Health.ping(pool);
    Pool.close(pool);
    Assert.assertTrue(Result.isErr(result))
