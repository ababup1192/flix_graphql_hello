///
/// 起動。SDL と生成物の一致、PostgreSQL の接続、migrations の適用済みを確かめ、2 つのエンジン（見本の /graphql と
/// 管理 API の /admin/graphql）を組み立てて 8080 番で待つ。起動に失敗したらメッセージを出して終了コード 1 で終わる。
///
/// 環境変数: CMS_DSN / CMS_DB_USER / CMS_DB_PASSWORD（DbConfig）、CMS_CORS_ORIGINS（カンマ区切り。省略時は CORS 無し）
///
def main(): Unit \ {IO, Chan, NonDet, Fs.FileRead, Sys.Exit, Sys.Env} =
    let started = forM (
        _           <- checkGenerated(GeneratedCheck.schema());
        _           <- checkGenerated(GeneratedCheck.admin());
        connection  <- DbConfig.fromEnv();
        pool        <- openPool(connection);
        _           <- checkMigrations(connection);
        database    <- SqliteCounter.open("counter.db");
        engine      <- Graphql.buildEngine(AppSchema.make(f -> SqliteCounter.runWithSqlite(database, f)));
        adminEngine <- Graphql.buildEngine(AdminSchema.make(AdminRunner.make(pool)))
    ) yield (pool, engine, adminEngine);
    match started {
        case Err(message) => { println(message); Sys.Exit.exit(1) }
        case Ok((pool, engine, adminEngine)) =>
            let cors = { allowedOrigins = Sys.Env.getVar("CMS_CORS_ORIGINS") |> Option.getWithDefault("") |> Cors.parseOrigins };
            let config = { cors = cors, graphqlPath = "/graphql" };
            let adminConfig = { cors = cors, graphqlPath = "/admin/graphql" };
            HttpServer.listen(8080, request ->
                Health.runWithPool(pool, () ->
                    if (Server.pathOf(request#path) == adminConfig#graphqlPath)
                        Graphql.runWithEngine(adminEngine, () -> Server.handle(adminConfig, request))
                    else
                        Graphql.runWithEngine(engine, () -> Server.handle(config, request))))
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
/// migrations/ が全部適用済みか。未適用や改変があれば Err（`make migrate` を促す）。
///
/// WhyNot: 起動時に apply しないのは、複数台が同時に起動した時の順序と、失敗した migration の扱いを
/// デプロイの手順に置きたいため。起動は check だけにする。
///
def checkMigrations(connection: Jdbc.ConnectionConfig): Result[String, Unit] \ {IO, Fs.FileRead} =
    let outcome = run {
        Migrate.runWithResult(() -> DbError.runWithFailure(() -> Jdbc.withConnection(connection, conn -> Migrate.check(conn, "migrations"))))
    } with Fs.ReadFile.runWithFileRead
      with Fs.DirList.runWithIO;
    match outcome {
        case Ok(Ok(()))       => Ok(())
        case Ok(Err(failure)) => Err("migrations を確かめられません: ${failure}")
        case Err(message)     => Err("migrations が当たっていません（`make migrate` で当ててください）: ${message}")
    }

///
/// 生成物が SDL ファイルから、期待する版の生成器で作られた物か照合する。
/// テストでも同じ事を確かめるが、SDL だけ変えて起動しても古いスキーマで動いてしまうので、起動時にも止める。
///
def checkGenerated(generated: GeneratedCheck.Generated): Result[String, Unit] \ {IO, Fs.FileRead} =
    forM (
        sdl <- Fs.FileRead.read(generated#sdlPath) |> Result.mapErr(error -> "${generated#sdlPath} を読めません: ${error}");
        _   <- GeneratedCheck.check(generated, sdl)
    ) yield ()
