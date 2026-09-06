///
/// schema.graphql と生成物の一致を確かめ、環境変数から PostgreSQL の接続プールを開き、SQLite のカウンタを開き、
/// エンジンを 1 回だけ組み立てて 8080 番で GraphQL の HTTP サーバを起動する。
/// 起動に失敗したら（DB に届かない場合も）メッセージを出して終了コード 1 で終わる。
///
/// 環境変数: CMS_DSN / CMS_DB_USER / CMS_DB_PASSWORD（DbConfig）、CMS_CORS_ORIGINS（カンマ区切り。省略時は CORS 無し）
///
def main(): Unit \ {IO, Chan, NonDet, Fs.FileRead, Sys.Exit, Sys.Env} =
    let started = forM (
        _          <- checkGenerated("schema.graphql");
        connection <- DbConfig.fromEnv();
        pool       <- openPool(connection);
        database   <- SqliteCounter.open("counter.db");
        engine     <- Graphql.buildEngine(AppSchema.make(f -> SqliteCounter.runWithSqlite(database, f)))
    ) yield (pool, engine);
    match started {
        case Err(message)      => { println(message); Sys.Exit.exit(1) }
        case Ok((pool, built)) =>
            let config = { cors = { allowedOrigins = Sys.Env.getVar("CMS_CORS_ORIGINS") |> Option.getWithDefault("") |> Cors.parseOrigins } };
            HttpServer.listen(8080, request ->
                Health.runWithPool(pool, () ->
                    Graphql.runWithEngine(built, () -> Server.handle(config, request))))
    }

///
/// プールを開き、1 回 SELECT 1 を投げて届くことを確かめる。届かなければ閉じて Err。
///
/// WhyNot: 届かなくても起動して /health に任せる、にしないのは、DSN の打ち間違いを起動時に気づけないと
/// 公開サイトのビルドが 503 で落ちるまで分からないため。
///
def openPool(connection: Jdbc.ConnectionConfig): Result[String, Pool] \ IO =
    let pool = Pool.open(Pool.defaultConfig(connection));
    match Health.ping(pool) {
        case Ok(())       => Ok(pool)
        case Err(message) => { Pool.close(pool); Err("PostgreSQL に届きません: ${message}") }
    }

///
/// 生成物が schema.graphql から、期待する版の生成器で作られた物か照合する。
/// テストでも同じ事を確かめるが、SDL だけ変えて起動しても古いスキーマで動いてしまうので、起動時にも止める。
///
def checkGenerated(sdlPath: String): Result[String, Unit] \ {IO, Fs.FileRead} =
    forM (
        sdl <- Fs.FileRead.read(sdlPath) |> Result.mapErr(error -> "${sdlPath} を読めません: ${error}");
        _   <- GeneratedCheck.check(sdl)
    ) yield ()
