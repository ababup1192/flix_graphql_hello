import java.lang.System

///
/// 起動。SDL と生成物の一致、PostgreSQL の接続、migrations の適用済みを確かめ、管理 API（/admin/graphql）と
/// コンテンツ API（/graphql。型の定義から実行時に組み、定義が変われば組み直す）、Account API（/account/graphql。プロジェクトを選ぶ前の操作）を 8080 番で待つ。
/// パスの先頭に /p/{プロジェクト slug} を付けるとそのプロジェクト、無ければ既定プロジェクト（CMS_DEFAULT_PROJECT。空なら 404）。
/// 起動に失敗したらメッセージを出して終了コード 1 で終わる。
///
/// 環境変数: CMS_DSN / CMS_DB_USER / CMS_DB_PASSWORD（DbConfig。表の所有者）、CMS_DB_APP_USER / CMS_DB_APP_PASSWORD（リクエスト用のロール。無ければ所有者で繋ぐ）、
/// CMS_DB_TIMEOUT_SECONDS（接続ごとに DB 側で効かせる時間の上限。既定 30、0 で無効）、ASSET_*（StorageConfig。省略時は asset 無し）、
/// CMS_CORS_ORIGINS（カンマ区切り。省略時は CORS 無し）、CMS_BASE_DOMAIN（`{プロジェクト slug}.{base}` の Host でプロジェクトを選ぶ。省略時は /p/ だけ）、
/// CMS_DEFAULT_PROJECT（プロジェクト slug 無しの時のプロジェクト slug。省略時は default、空ならプロジェクト slug 無しは 404）、CMS_SIGNUP（open / closed）、
/// CMS_JOBS（on / off。off ならプロセス内のワーカーを回さない。外部トリガーか別 worker で回す）、CMS_JOBS_TOKEN（POST /jobs/tick を許す値。無ければ閉じる）、CMS_JOBS_DRAIN_SECONDS（停止時に実行中の仕事を待つ秒数。既定 15）、CMS_CACHE_MAX_AGE（コンテンツ API の GET で身元無しの応答に付ける Cache-Control の秒数。既定 60、0 で no-store）、
/// CMS_MODE=import-microcms（サーバを立てず、CMS_IMPORT_DIR の microCMS のスキーマを写してダミーの entry を CMS_IMPORT_COUNT 件ずつ積んで終わる）、CMS_MIGRATE（apply なら起動時に migrations/ を当てる。
/// 省略時は check で、未適用があれば起動しない）、CMS_VERSION（/health に出す版。省略時は dev）、CMS_MAX_CONNECTIONS（HTTP の同時接続の上限。超えた接続は 503。既定 256）
///
def main(): Unit \ {IO, Fs.FileRead, Sys.Exit, Sys.Env} =
    let started = forM (
        _           <- checkGenerated(GeneratedCheck.admin());
        _           <- checkGenerated(GeneratedCheck.account());
        connection  <- DbConfig.fromEnv();
        _           <- prepareMigrations(connection, Sys.Env.getVar("CMS_MIGRATE"));
        appConnection <- Ok(DbConfig.appFromEnv(connection));
        _           <- ensureAppRole(connection, appConnection);
        pool        <- openPool(appConnection |> Option.getWithDefault(connection));
        storage     <- StorageConfig.fromEnv();
        auth        <- AuthConfig.fromEnv();
        deps        <- Ok({ storage = storage, auth = auth });
        defaultProject <- resolveDefaultProject(pool, Sys.Env.getVar("CMS_DEFAULT_PROJECT"));
        accountEngine  <- AccountSchema.engine(pool, deps);
        adminEngines <- Ok(AdminEngine.create(deps));
        _           <- AdminEngine.current(adminEngines, pool, defaultProject |> Option.getWithDefault(ProjectId.default()))
    ) yield (pool, adminEngines, deps, defaultProject, accountEngine);
    match (started, Sys.Env.getVar("CMS_MODE")) {
        case (Err(message), _) => { println(message); Sys.Exit.exit(1) }
        // 一発処理: microCMS のスキーマを写してダミーを積み、終わる（サーバは立てない）
        case (Ok((pool, _, deps, defaultProject, _)), Some("import-microcms")) =>
            let dir = Sys.Env.getVar("CMS_IMPORT_DIR") |> Option.getWithDefault("import/microcms/schema");
            let count = Sys.Env.getVar("CMS_IMPORT_COUNT") |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(3);
            match MicrocmsCli.execute(dir, pool, deps, defaultProject |> Option.getWithDefault(ProjectId.default()), count) {
                case Ok(summary)  => { println(summary); Pool.close(pool) }
                case Err(message) => { println(message); Pool.close(pool); Sys.Exit.exit(1) }
            }
        case (Ok((pool, adminEngines, deps, defaultProject, accountEngine)), _) =>
            let jwks = TokenVerifier.createCache();
            let cors = { allowedOrigins = Sys.Env.getVar("CMS_CORS_ORIGINS") |> Option.getWithDefault("") |> Cors.parseOrigins };
            let version = Sys.Env.getVar("CMS_VERSION") |> Option.getWithDefault("dev");
            let baseDomain = Sys.Env.getVar("CMS_BASE_DOMAIN") |> Option.filter(text -> not String.isEmpty(text));
            let jobsToken = Sys.Env.getVar("CMS_JOBS_TOKEN") |> Option.filter(text -> not String.isEmpty(text));
            let jobsOn = Sys.Env.getVar("CMS_JOBS") |> Option.getWithDefault("on") != "off";
            let drainSeconds = Sys.Env.getVar("CMS_JOBS_DRAIN_SECONDS") |> Option.flatMap(Int64.fromString) |> Option.getWithDefault(15i64);
            let jobs = BackgroundJobs.createState(drainSeconds);
            let cacheMaxAge = Sys.Env.getVar("CMS_CACHE_MAX_AGE") |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(60);
            let config = { cors = cors, version = version, jobsToken = jobsToken, cacheMaxAge = if (cacheMaxAge > 0) Some(cacheMaxAge) else None };
            let engineCache = ContentEngine.create(deps);
            // WhyNot: 開発モード（X-Dev-User を信じる）で 127.0.0.1 にしか bind しないのは、ヘッダで人になれる経路を LAN に開けないため
            let bind = match deps#auth#mode { case AuthConfig.Mode.Dev => Some("127.0.0.1") case _ => None };
            // 予約公開と Webhook の配信はプロセス内のワーカーで回す。積むのはリクエストの Tx（outbox）、拾って実行するのはここ
            region rc {
            BackgroundJobs.installShutdownHook(jobs);
            if (jobsOn) spawn BackgroundJobs.runForever(pool, jobs) @ rc else println("jobs: CMS_JOBS=off なのでプロセス内のワーカーは回しません（POST /jobs/tick か別の worker で回してください）");
            let maxConnections = Sys.Env.getVar("CMS_MAX_CONNECTIONS") |> Option.flatMap(Int32.fromString) |> Option.filter(n -> n > 0) |> Option.getWithDefault(256);
            let listener = HttpServer.open({ bind = bind, maxConnections = maxConnections | HttpServer.defaultConfig() });
            let runtime = {
                pool = pool, deps = deps, jwks = jwks, baseDomain = baseDomain, defaultProject = defaultProject,
                accountEngine = accountEngine, adminEngines = adminEngines, engineCache = engineCache,
                config = config, routes = Server.routes(config, Health.ofPool(pool, jobs, listener)) |> Router.withProjectPrefix };
            HttpServer.listen(listener, served -> println(HttpServer.logLine(Log.timeText(System.currentTimeMillis()), served)), request -> dispatch(runtime, request))
            }
    }

///
/// 起動後にリクエストごとに使う物の束。
///
type alias Runtime = {
    pool = Pool, deps = Deps, jwks = TokenVerifier.JwksCache, baseDomain = Option[String], defaultProject = Option[ProjectId],
    accountEngine = Graphql.Engine, adminEngines = AdminEngine.Cache, engineCache = ContentEngine.Cache,
    config = ServerConfig, routes = List[Route[{Graphql, IO}]] }

///
/// 1 リクエストを middleware（CORS → Host のプロジェクト → 身元）を通してルート表で振り分け、行の engine に合わせてエンジンを入れて実行する。
/// 404 / 405 / 503 も CORS を通る。
///
def dispatch(runtime: Runtime, request: HttpRequest): HttpResponse \ IO =
    let pipeline =
        Cors.wrap(runtime#config#cors, Router.allowedMethods(runtime#routes),
            Server.wrapProjectFromHost(runtime#baseDomain,
                Credentials.wrap(tokenHeaderOf(runtime#deps#auth), verifierOf(runtime#deps#auth, runtime#jwks),
                    Server.dispatch(runtime#routes, (found, routeRequest) -> runRoute(runtime, found, routeRequest)))));
    pipeline({ request = request, params = Map.empty(), credential = Credential.Missing })

///
/// 一致した行を実行する。engine が None ならエンジン無し、Account ならプロジェクトを見ない。
/// Content / Admin は params の projectSlug（無ければ既定プロジェクト）を id に解き、無ければ 404、エンジンを組めなければ 503。
///
/// WhyNot: エンジンの要らない道（/health、/jobs/tick）でエンジンを組まないのは、型定義が壊れた時に死活監視まで 503 になり、
/// プロジェクトの SELECT が余分に走るため。
///
def runRoute(runtime: Runtime, found: Route[{Graphql, IO}], routeRequest: RouteRequest): HttpResponse \ IO =
    let execute = () -> (found#handle)(routeRequest);
    match found#engine {
        case None                 => Graphql.runWithoutEngine(execute)
        case Some(Engine.Account) => Graphql.runWithEngine(runtime#accountEngine, execute)
        case Some(engine)         =>
            let projectSlug = Map.get(Router.projectSlugParam(), routeRequest#params);
            match resolveProject(runtime#pool, runtime#defaultProject, projectSlug) {
                case Err(message)        => Server.unavailable(message)
                case Ok(None)            => Server.notFound("プロジェクト '${projectSlug |> Option.getWithDefault("")}' がありません")
                case Ok(Some(projectId)) => match engineOf(runtime, engine, projectId) {
                    case Ok(built)    => Graphql.runWithEngine(built, execute)
                    case Err(message) => Server.unavailable(message)
                }
            }
    }

///
/// 行の engine に合う、このプロジェクトのエンジン。コンテンツ API は型の定義から組み（目印で組み直す）、管理 API はプロジェクトごとに 1 つ。
///
def engineOf(runtime: Runtime, engine: Engine, projectId: ProjectId): Result[String, Graphql.Engine] \ IO = match engine {
    case Engine.Content => ContentEngine.current(runtime#engineCache, runtime#pool, projectId)
    case Engine.Admin   => AdminEngine.current(runtime#adminEngines, runtime#pool, projectId)
    case Engine.Account => Ok(runtime#accountEngine)
}

///
/// ログインのトークンを読むヘッダ。dev モードは X-Dev-User の email を信じる（AuthConfig が CMS_VERSION=dev の時にしか許さない）。
///
def tokenHeaderOf(auth: AuthConfig.AuthConfig): String =
    match auth#mode { case AuthConfig.Mode.Dev => "X-Dev-User" case _ => auth#tokenHeader }

///
/// ログインのトークンの検証（発行元の JWKS、dev、閉じている）。身元の読み取りは Credentials.wrap（PAT → トークン → X-Api-Key → X-Preview-Token の順）。
///
def verifierOf(auth: AuthConfig.AuthConfig, jwks: TokenVerifier.JwksCache, token: String): Result[String, Principal] \ IO = match auth#mode {
    case AuthConfig.Mode.Jwks(config) => Net.Http.runWithIO(() -> Time.Clock.runWithIO(() -> TokenVerifier.runWithJwks(config, jwks, () -> TokenVerifier.verify(token))))
    case AuthConfig.Mode.Dev          => TokenVerifier.runDev(() -> TokenVerifier.verify(token))
    case AuthConfig.Mode.Closed       => Err("管理 API は閉じています（CMS_AUTH=none）")
}

///
/// パスか Host のプロジェクト slug からプロジェクトを決める。無ければ既定プロジェクト（SQL を出さない）。
/// 形が違うか無いプロジェクト slug は None（404）。
///
def resolveProject(pool: Pool, defaultProject: Option[ProjectId], projectSlug: Option[String]): Result[String, Option[ProjectId]] \ IO = match projectSlug {
    case None       => Ok(defaultProject)
    case Some(text) => match ProjectSlug.parse(text) {
        case None       => Ok(None)
        case Some(slug) => DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> Projects.findBySlug(slug))) |> Result.mapErr(DbRunner.failureMessage)
    }
}

///
/// CMS_DEFAULT_PROJECT から既定プロジェクト。省略なら default、空なら無し（プロジェクト slug 無しは 404）、
/// プロジェクト slug が書いてあればそれを引き、無ければ起動しない。
///
def resolveDefaultProject(pool: Pool, configured: Option[String]): Result[String, Option[ProjectId]] \ IO = match configured {
    case None     => Ok(Some(ProjectId.default()))
    case Some("") => Ok(None)
    case Some(text) => match ProjectSlug.parse(text) {
        case None       => Err("CMS_DEFAULT_PROJECT '${text}' はプロジェクト slug の形ではありません（${ProjectSlug.rule()}）")
        case Some(slug) =>
            DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> Projects.findBySlug(slug)))
                |> Result.mapErr(DbRunner.failureMessage)
                |> Result.flatMap(found -> match found {
                    case Some(id) => Ok(Some(id))
                    case None     => Err("CMS_DEFAULT_PROJECT '${text}' のプロジェクトがありません")
                })
    }
}

///
/// アプリ用のロールを所有者の接続で用意する。設定が無ければ何もしない（所有者で繋ぐ）。
///
/// WhyNot: 所有者で繋ぐ事を Err にしないのは、セルフホストで 1 プロジェクトならロール分離の価値が薄く、
/// policy は FORCE で所有者にも効くため。ログには出して分かるようにする。
///
def ensureAppRole(owner: Jdbc.ConnectionConfig, app: Option[Jdbc.ConnectionConfig]): Result[String, Unit] \ IO = match app {
    case None        => { println("db: CMS_DB_APP_PASSWORD が無いので所有者（${owner#user}）で繋ぎます。RLS は効きますがロール分離はありません"); Ok(()) }
    case Some(found) => AppRole.ensure(owner, found)
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
