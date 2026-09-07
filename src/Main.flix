///
/// 起動。SDL と生成物の一致、PostgreSQL の接続、migrations の適用済みを確かめ、管理 API（/admin/graphql）と
/// コンテンツ API（/graphql。型の定義から実行時に組み、定義が変われば組み直す）を 8080 番で待つ。
/// パスの先頭に /p/{slug} を付けるとそのプロジェクト、無ければ既定のプロジェクト（default）。
/// 起動に失敗したらメッセージを出して終了コード 1 で終わる。
///
/// 環境変数: CMS_DSN / CMS_DB_USER / CMS_DB_PASSWORD（DbConfig）、ASSET_*（StorageConfig。省略時は asset 無し）、
/// CMS_CORS_ORIGINS（カンマ区切り。省略時は CORS 無し）、CMS_MIGRATE（apply なら起動時に migrations/ を当てる。
/// 省略時は check で、未適用があれば起動しない）、CMS_VERSION（/health に出す版。省略時は dev）
///
def main(): Unit \ {IO, Chan, NonDet, Fs.FileRead, Sys.Exit, Sys.Env} =
    let started = forM (
        _           <- checkGenerated(GeneratedCheck.admin());
        connection  <- DbConfig.fromEnv();
        pool        <- openPool(connection);
        _           <- prepareMigrations(connection, Sys.Env.getVar("CMS_MIGRATE"));
        storage     <- StorageConfig.fromEnv();
        adminEngines <- Ok(AdminEngine.create(storage));
        _           <- AdminEngine.current(adminEngines, pool, ProjectId.default())
    ) yield (pool, adminEngines, storage);
    match started {
        case Err(message) => { println(message); Sys.Exit.exit(1) }
        case Ok((pool, adminEngines, storage)) =>
            let cors = { allowedOrigins = Sys.Env.getVar("CMS_CORS_ORIGINS") |> Option.getWithDefault("") |> Cors.parseOrigins };
            let version = Sys.Env.getVar("CMS_VERSION") |> Option.getWithDefault("dev");
            let contentConfig = { cors = cors, graphqlPath = "/graphql", version = version };
            let adminConfig = { cors = cors, graphqlPath = "/admin/graphql", version = version };
            let engineCache = ContentEngine.create(storage);
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
/// migrations/ の扱い。CMS_MIGRATE が apply なら未適用の物を当て（advisory lock 付きなので複数台の同時起動でも 1 台だけが当てる）、
/// それ以外なら全部適用済みかを確かめて、未適用や改変があれば Err（`make migrate` を促す）。
///
/// WhyNot: 手元の既定を check にするのは、DSN の打ち間違いで別の DB に migration を当ててしまうのを避けるため。
/// イメージ（Dockerfile）は apply を既定にし、`docker compose pull && up` だけで更新が終わるようにする。
///
def prepareMigrations(connection: Jdbc.ConnectionConfig, mode: Option[String]): Result[String, Unit] \ {IO, Fs.FileRead} =
    let outcome = run {
        Migrate.runWithResult(() -> DbError.runWithFailure(() ->
            if (mode == Some("apply"))
                Migrate.apply(Migrate.defaultConfig(connection), "migrations") |> List.forEach(version -> println("migration applied: ${version}"))
            else
                Jdbc.withConnection(connection, conn -> Migrate.check(conn, "migrations"))))
    } with Fs.ReadFile.runWithFileRead
      with Fs.DirList.runWithIO;
    match outcome {
        case Ok(Ok(()))       => Ok(())
        case Ok(Err(failure)) => Err("migrations を当てられません: ${failure}")
        case Err(message)     => if (mode == Some("apply")) Err("migrations が壊れています: ${message}") else Err("migrations が当たっていません（`make migrate` で当ててください）: ${message}")
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
