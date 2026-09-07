///
/// 起動。SDL と生成物の一致、PostgreSQL の接続、migrations の適用済みを確かめ、管理 API（/admin/graphql）と
/// コンテンツ API（/graphql。型の定義から実行時に組み、定義が変われば組み直す）を 8080 番で待つ。
/// パスの先頭に /p/{slug} を付けるとそのプロジェクト、無ければ既定のプロジェクト（default）。
/// 起動に失敗したらメッセージを出して終了コード 1 で終わる。
///
/// 環境変数: CMS_DSN / CMS_DB_USER / CMS_DB_PASSWORD（DbConfig）、ASSET_*（StorageConfig。省略時は asset 無し）、
/// CMS_CORS_ORIGINS（カンマ区切り。省略時は CORS 無し）
///
def main(): Unit \ {IO, Chan, NonDet, Fs.FileRead, Sys.Exit, Sys.Env} =
    let started = forM (
        _           <- checkGenerated(GeneratedCheck.admin());
        connection  <- DbConfig.fromEnv();
        pool        <- openPool(connection);
        _           <- checkMigrations(connection);
        storage     <- StorageConfig.fromEnv();
        adminEngines <- Ok(AdminEngine.create(storage));
        _           <- AdminEngine.current(adminEngines, pool, ProjectId.default())
    ) yield (pool, adminEngines);
    match started {
        case Err(message) => { println(message); Sys.Exit.exit(1) }
        case Ok((pool, adminEngines)) =>
            let cors = { allowedOrigins = Sys.Env.getVar("CMS_CORS_ORIGINS") |> Option.getWithDefault("") |> Cors.parseOrigins };
            let contentConfig = { cors = cors, graphqlPath = "/graphql" };
            let adminConfig = { cors = cors, graphqlPath = "/admin/graphql" };
            let engineCache = ContentEngine.create();
            // WhyNot: コンテンツ API を実行する時以外（/health、404、preflight、GET）でエンジンを組まないのは、型定義が壊れた時に
            // 死活監視や preflight まで 503 になり、404 ごとに目印の SELECT が走るため。GraphQL を実行しない道なので管理 API のエンジンで受ける
            HttpServer.listen(8080, request ->
                Health.runWithPool(pool, () -> {
                    let (slug, path) = Server.splitProject(request#path);
                    let scoped = { path = path | request };
                    match resolveProject(pool, slug) {
                        case Err(message)      => Server.unavailable(message)
                        case Ok(None)          => Server.notFound("projectId '${slug |> Option.getWithDefault("")}' がありません")
                        case Ok(Some(projectId)) =>
                            if (Server.needsGraphqlEngine(contentConfig, scoped))
                                match ContentEngine.current(engineCache, pool, projectId) {
                                    case Ok(engine)   => Graphql.runWithEngine(engine, () -> Server.handle(contentConfig, scoped))
                                    case Err(message) => Server.unavailable(message)
                                }
                            else
                                match AdminEngine.current(adminEngines, pool, projectId) {
                                    case Ok(engine)   => Graphql.runWithEngine(engine, () -> Server.handle(adminConfig, scoped))
                                    case Err(message) => Server.unavailable(message)
                                }
                    }
                }))
    }

///
/// パスの slug からプロジェクトを決める。slug が無ければ既定（SQL を出さない）。無い slug は None。
///
def resolveProject(pool: Pool, slug: Option[String]): Result[String, Option[ProjectId]] \ IO = match slug {
    case None        => Ok(Some(ProjectId.default()))
    case Some(found) => DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> Projects.findBySlug(found))) |> Result.mapErr(DbRunner.failureMessage)
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
