import java.lang.System
import java.lang.Throwable

///
/// 起動。SDL と生成物の一致、PostgreSQL の接続、migrations の適用済みを確かめ、管理 API（/admin/graphql）と
/// コンテンツ API（/graphql。型の定義から実行時に組み、定義が変われば組み直す）、Account API（/account/graphql。プロジェクトを選ぶ前の操作）を 8080 番で待つ。
/// パスの先頭に /p/{プロジェクト slug} を付けるとそのプロジェクト、無ければ既定プロジェクト（CMS_DEFAULT_PROJECT。空なら 404）。
/// 起動に失敗したらメッセージを出して終了コード 1 で終わる。ログは 1 行 JSON（docs/logging.md）。
///
/// 環境変数: CMS_DSN / CMS_DB_USER / CMS_DB_PASSWORD（DbConfig。表の所有者）、CMS_DB_APP_USER / CMS_DB_APP_PASSWORD（リクエスト用のロール。無ければ所有者で繋ぐ）、
/// CMS_DB_TIMEOUT_SECONDS（接続ごとに DB 側で効かせる時間の上限。既定 30、0 で無効）、CMS_DB_LEAK_DETECTION_SECONDS（借りたまま返さない接続の検出。既定 0 で無効）、
/// CMS_DB_MAX_CONNECTIONS（接続プールの上限。既定 10）、CMS_DB_BORROW_TIMEOUT_SECONDS（接続を借りるのを待つ上限。既定 2）、ASSET_*（StorageConfig。省略時は asset 無し）、
/// CMS_CORS_ORIGINS（カンマ区切り。省略時は CORS 無し）、CMS_BASE_DOMAIN（`{プロジェクト slug}.{base}` の Host でプロジェクトを選ぶ。省略時は /p/ だけ）、
/// CMS_DEFAULT_PROJECT（プロジェクト slug 無しの時のプロジェクト slug。省略時は default、空ならプロジェクト slug 無しは 404）、CMS_SIGNUP（open / closed）、
/// CMS_JOBS（on / off。off ならプロセス内のワーカーを回さない。外部トリガーか別 worker で回す）、CMS_JOBS_TOKEN（POST /jobs/tick を許す値。無ければ閉じる）、CMS_JOBS_DRAIN_SECONDS（自己回復の停止で実行中の仕事を待つ秒数。既定 15）、CMS_SHUTDOWN_TIMEOUT_SECONDS（SIGTERM で HTTP の接続と仕事を待つ秒数。既定 20。超えたら終了コード 2）、CMS_SELF_HEAL（on / off。プールが壊れたまま戻らない時に自分で終わる。既定 on）、CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS（既定 90）、CMS_SELF_HEAL_WARMUP_SECONDS（起動から見送る秒数。既定 300）、CMS_SELF_HEAL_JITTER_SECONDS（複数台が同時に終わらないための上乗せの上限。既定 10）、CMS_CACHE_MAX_AGE（コンテンツ API の GET で身元無しの応答に付ける Cache-Control の秒数。既定 60、0 で no-store）、
/// CMS_MODE=import-microcms（サーバを立てず、CMS_IMPORT_DIR の microCMS のスキーマを写してダミーの entry を CMS_IMPORT_COUNT 件ずつ積んで終わる）、CMS_MIGRATE（apply なら起動時に migrations/ を当てる。
/// 省略時は check で、未適用があれば起動しない）、CMS_VERSION（/health とログの version に出す版。省略時は dev）、CMS_MAX_CONNECTIONS（HTTP の同時接続の上限。超えた接続は 503。既定 256）、
/// CMS_LOG_LEVEL（trace / debug / info / warn / error / fatal。これより軽い行は出さない。既定 info）
///
def main(): Unit \ {IO, Fs.FileRead, Sys.Exit, Sys.Env} =
    let version = Sys.Env.getVar("CMS_VERSION") |> Option.getWithDefault("dev");
    let sink = sinkOf(version, Sys.Env.getVar("CMS_LOG_LEVEL"));
    Log.runWith(sink, () -> start(version, sink))

///
/// ログの出力先。CMS_LOG_LEVEL で絞り、service / version を全行に足し、1 行 JSON を stdout に書く。
/// 知らない値は info にする（起動を止めるほどの事ではない。起動の行に出る）。
///
def sinkOf(version: String, level: Option[String]): Log.Sink =
    Log.Sink.minSeverity(level |> Option.flatMap(Log.parseSeverity) |> Option.getWithDefault(Log.Severity.Info),
        Log.Sink.enrich(Log.Fields.empty() |> Log.Fields.str("service", "cms") |> Log.Fields.str("version", version),
            Log.Sink.json(_ -> System.currentTimeMillis(), line -> println(line))))

///
/// 起動の本体。Log は main が入れる。
///
/// WhyNot: 1 つの関数にしないのは、Log を持つ関数は CPS の frame に落ちて、この長さだと JVM のメソッドの上限（64 KB）を超えるため
/// （2026-09-08 に "Method too large" で実測）。boot / importMicrocms / serve に分ける。
///
def start(version: String, sink: Log.Sink): Unit \ {IO, Fs.FileRead, Sys.Exit, Sys.Env, Log} =
    match (boot(sink), Sys.Env.getVar("CMS_MODE")) {
        case (Err(message), _) => { Log.Fields.empty() |> Log.Fields.str("error.message", message) |> Log.fatal("startup failed"); Sys.Exit.exit(1) }
        // 一発処理: microCMS のスキーマを写してダミーを積み、終わる（サーバは立てない）
        case (Ok(started), Some("import-microcms")) => importMicrocms(started)
        case (Ok(started), _)                       => serve(version, sink, started)
    }

///
/// 起動時に組む物。
///
type alias Started = { pool = Pool, dbConnection = Jdbc.ConnectionConfig, adminEngines = AdminEngine.Cache, deps = Deps, defaultProject = Option[ProjectId], accountEngine = Graphql.Engine }

///
/// SDL と生成物の一致、DB、migrations、ロール、プール、依存、既定プロジェクト、エンジンの順に確かめて組む。
///
def boot(sink: Log.Sink): Result[String, Started] \ {IO, Fs.FileRead, Sys.Env, Log} =
    forM (
        _           <- checkGenerated(GeneratedCheck.admin());
        _           <- checkGenerated(GeneratedCheck.account());
        connection  <- DbConfig.fromEnv();
        _           <- prepareMigrations(connection, Sys.Env.getVar("CMS_MIGRATE"));
        appConnection <- Ok(DbConfig.appFromEnv(connection));
        _           <- ensureAppRole(connection, appConnection);
        dbConnection <- Ok(appConnection |> Option.getWithDefault(connection));
        pool        <- openPool(dbConnection);
        storage     <- StorageConfig.fromEnv();
        auth        <- AuthConfig.fromEnv();
        deps        <- Ok({ storage = storage, auth = auth, log = sink });
        defaultProject <- resolveDefaultProject(pool, Sys.Env.getVar("CMS_DEFAULT_PROJECT"));
        accountEngine  <- AccountSchema.engine(pool, deps);
        adminEngines <- Ok(AdminEngine.create(deps));
        _           <- AdminEngine.current(adminEngines, pool, defaultProject |> Option.getWithDefault(ProjectId.default()))
    ) yield { pool = pool, dbConnection = dbConnection, adminEngines = adminEngines, deps = deps, defaultProject = defaultProject, accountEngine = accountEngine }

///
/// CMS_MODE=import-microcms。microCMS のスキーマを写してダミーを積み、終わる。
///
def importMicrocms(started: Started): Unit \ {IO, Fs.FileRead, Sys.Exit, Sys.Env, Log} =
    let dir = Sys.Env.getVar("CMS_IMPORT_DIR") |> Option.getWithDefault("import/microcms/schema");
    let count = Sys.Env.getVar("CMS_IMPORT_COUNT") |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(3);
    match MicrocmsCli.execute(dir, started#pool, started#deps, started#defaultProject |> Option.getWithDefault(ProjectId.default()), count) {
        // WhyNot: まとめを Log にしないのは、これはコマンドの出力（人が読む複数行の表）で、ログの行ではないため
        case Ok(summary)  => { println(summary); Pool.close(started#pool) }
        case Err(message) => { Log.Fields.empty() |> Log.Fields.str("error.message", message) |> Log.fatal("import failed"); Pool.close(started#pool); Sys.Exit.exit(1) }
    }

///
/// サーバを立てて待つ。戻らない。
///
def serve(version: String, sink: Log.Sink, started: Started): Unit \ {IO, Sys.Env, Sys.Exit, Log} =
    let deps = started#deps;
    let jwks = TokenVerifier.createCache();
    let cors = { allowedOrigins = Sys.Env.getVar("CMS_CORS_ORIGINS") |> Option.getWithDefault("") |> Cors.parseOrigins };
    let baseDomain = Sys.Env.getVar("CMS_BASE_DOMAIN") |> Option.filter(text -> not String.isEmpty(text));
    let jobsToken = Sys.Env.getVar("CMS_JOBS_TOKEN") |> Option.filter(text -> not String.isEmpty(text));
    let jobsOn = Sys.Env.getVar("CMS_JOBS") |> Option.getWithDefault("on") != "off";
    let drainSeconds = Sys.Env.getVar("CMS_JOBS_DRAIN_SECONDS") |> Option.flatMap(Int64.fromString) |> Option.getWithDefault(15i64);
    let jobs = BackgroundJobs.createState(drainSeconds);
    let heal = healWatch(started);
    let cacheMaxAge = Sys.Env.getVar("CMS_CACHE_MAX_AGE") |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(60);
    let config = { cors = cors, version = version, jobsToken = jobsToken, cacheMaxAge = if (cacheMaxAge > 0) Some(cacheMaxAge) else None };
    let engineCache = ContentEngine.create(deps);
    // WhyNot: 開発モード（X-Dev-User を信じる）で 127.0.0.1 にしか bind しないのは、ヘッダで人になれる経路を LAN に開けないため
    let bind = match deps#auth#mode { case AuthConfig.Mode.Dev => Some("127.0.0.1") case _ => None };
    // 予約公開と Webhook の配信はプロセス内のワーカーで回す。積むのはリクエストの Tx（outbox）、拾って実行するのはここ
    region rc {
    if (jobsOn) spawn BackgroundJobs.runForever(started#pool, jobs, sink) @ rc else Log.warn("jobs off (CMS_JOBS=off): POST /jobs/tick か別の worker で回してください", Log.Fields.empty());
    // WhyNot: CMS_JOBS=off の時に見張りを止めないのは、接続プールが壊れる事は仕事を回すかどうかと関係が無いため
    spawn BackgroundJobs.watchForever(started#pool, jobs, heal, sink) @ rc;
    let maxConnections = Sys.Env.getVar("CMS_MAX_CONNECTIONS") |> Option.flatMap(Int32.fromString) |> Option.filter(n -> n > 0) |> Option.getWithDefault(256);
    let listener = HttpServer.open({ bind = bind, maxConnections = maxConnections | HttpServer.defaultConfig() });
    Shutdown.installHook(listener, jobs, Shutdown.timeoutSeconds(Sys.Env.getVar("CMS_SHUTDOWN_TIMEOUT_SECONDS")) * 1000i64, sink);
    let runtime = {
        pool = started#pool, deps = deps, jwks = jwks, baseDomain = baseDomain, defaultProject = started#defaultProject,
        defaultProjectSlug = Sys.Env.getVar("CMS_DEFAULT_PROJECT") |> Option.getWithDefault("default") |> Some |> Option.filter(text -> not String.isEmpty(text)),
        accountEngine = started#accountEngine, adminEngines = started#adminEngines, engineCache = engineCache,
        config = config, sink = sink, routes = Server.routes(config, Health.ofPool(started#pool, jobs, listener, System.currentTimeMillis(), jobsOn, heal)) |> Router.withProjectPrefix };
    Log.Fields.empty()
        |> Log.Fields.str("server.address", bind |> Option.getWithDefault("0.0.0.0"))
        |> Log.Fields.int("server.port", Int32.toInt64(listener#port))
        |> Log.info("listening");
    Option.forEach(died, listenGuarded(listener, sink, runtime))
    }

///
/// listen を回し、Throwable で抜けたらそれを返す（正常に閉じたら None）。
///
/// WhyNot: catch の中でログを出さないのは、Log は effect で、try / catch を跨ぐと CPS の frame に落ちるため。
/// 受けた物を値で返して外で出す。
///
def listenGuarded(listener: HttpServer.Listener, sink: Log.Sink, runtime: Runtime): Option[Throwable] \ IO =
    try {
        HttpServer.listen(listener, served -> logServed(sink, served), request -> dispatch(runtime, request));
        None
    } catch {
        case error: Throwable => Some(error)
    }

///
/// main スレッドが落ちた。行を出して、自己回復と同じ終了コード 3 で終わる。
///
/// WhyNot: drain してから終わらないのは、ここに来るのは OOM のように JVM 自体が壊れている時で、
/// drain の中の DB の呼び出しも同じ理由で詰まり、停止が終わらなくなるため。
///
/// WhyNot: そのまま JVM に投げ返さないのは、投げ返すと終了コードが 1 になり、起動の失敗（1）と区別が付かないため。
/// `-XX:+ExitOnOutOfMemoryError` を付けた JVM が使う番号（実測で 3）に寄せる。
///
def died(error: Throwable): Unit \ {IO, Sys.Exit, Log} =
    let fields = Log.exception(error, Log.Fields.empty());
    if (JvmErrors.isFatal(error)) Log.fatal("main thread died", fields) else Log.error("main thread died", fields);
    Sys.Exit.exit(Shutdown.exitCode(Shutdown.Outcome.Crashed))

///
/// プールが壊れたまま戻らないかを見張る物。CMS_SELF_HEAL=off なら None（見張らない）。
///
def healWatch(started: Started): Option[SelfHeal.Watch] \ {IO, Sys.Env} =
    SelfHeal.fromEnv(healJitterFraction())
        |> Option.map(settings -> SelfHeal.createWatch(settings, System.currentTimeMillis(), started#dbConnection))

///
/// 複数台が同じ時刻に自分を終わらせないための上乗せの割合（0.0〜1.0）。プロセスごとに 1 回だけ引く。
/// 秒に直すのは SelfHeal（上限は CMS_SELF_HEAL_JITTER_SECONDS）。
///
def healJitterFraction(): Float64 \ IO =
    Math.Random.runWithIO(() -> Math.Random.randomFloat64())

///
/// 起動後にリクエストごとに使う物の束。
///
type alias Runtime = {
    pool = Pool, deps = Deps, jwks = TokenVerifier.JwksCache, baseDomain = Option[String], defaultProject = Option[ProjectId], defaultProjectSlug = Option[String],
    accountEngine = Graphql.Engine, adminEngines = AdminEngine.Cache, engineCache = ContentEngine.Cache,
    config = ServerConfig, sink = Log.Sink, routes = List[Route[{Graphql, Log, Observe, IO}]] }

///
/// 1 リクエスト（接続のスレッド）の入口。request id を決め、Log を入れ直して span（request.id / cf.ray / method / path）を張り、
/// 処理の後にリクエストの行を 1 つ出す。
///
def dispatch(runtime: Runtime, request: HttpRequest): HttpResponse \ IO =
    let requestId = RequestId.resolve(request#headers);
    let span = LogFields.request(requestId, request);
    run {
        serveRequest(runtime, requestId, span, request)
    } with Log.withFields(span)
      with Log.runWith(runtime#sink)

///
/// middleware（request id → CORS → Host のプロジェクト → 身元）を通してルート表で振り分け、行の engine に合わせてエンジンを入れて実行する。
/// 404 / 405 / 503 も CORS と X-Request-Id を通る。処理の中で決まる属性（credential.kind / project / graphql.*、Route が Observe に積む mcp.* や 4xx の理由）は
/// extra に積み、リクエストの行に乗せる。
///
/// WhyNot: リクエストの行を HttpServer の onServed でなくここで出すのは、onServed には request id も身元も GraphQL の結果も無く、
/// スレッドを跨がずに届ける口が無いため。onServed は handle が投げた・読めなかった・書けなかった物だけを出す（logServed）。
/// 所要時間はソケットの読み書きを含まない。
///
def serveRequest(runtime: Runtime, requestId: String, span: Log.Fields, request: HttpRequest): HttpResponse \ {IO, Log} =
    let extra = Ref.fresh(Static, Log.Fields.empty());
    let startedAt = System.currentTimeMillis();
    let pipeline =
        RequestId.wrap(requestId,
            Cors.wrap(runtime#config#cors, Router.allowedMethods(runtime#routes),
                Server.wrapProjectFromHost(runtime#baseDomain,
                    Credentials.wrap(tokenHeaderOf(runtime#deps#auth), verifierOf(runtime#deps#auth, runtime#jwks),
                        Server.dispatch(runtime#routes, (found, routeRequest) -> runRoute(runtime, span, extra, found, routeRequest))))));
    let response = Observe.runWithRef(extra, () -> pipeline({ request = request, params = Map.empty(), credential = Credential.Missing }));
    let fields = Ref.get(extra)
        |> LogFields.response(response#status, System.currentTimeMillis() - startedAt, Int32.toInt64(Http.utf8Length(request#body)), Int32.toInt64(Http.utf8Length(response#body)));
    Log.emit({ severity = LogFields.responseSeverity(request#path, response#status, false, fields), message = "request", fields = fields });
    response

///
/// HttpServer が見た結果のうち、serveRequest が行を出せなかった物（handle が投げた・読めなかった 400 / 413 / 431・503 の reject・書けなかった）を出す。
/// 正常に処理して書けた物は serveRequest が出しているので出さない。
///
/// WhyNot: request.id を X-Request-Id があった時にしか付けないのは、この経路は dispatch に入る前か例外で抜けた後で、
/// dispatch が作った ULID を持って来られないため（応答ヘッダにも付いていない）。例外の行は同じスレッドの直前の行と時刻で突き合わせる。
///
def logServed(sink: Log.Sink, served: HttpServer.Served): Unit \ IO =
    if (Option.isEmpty(served#failure) and served#method != "-") ()
    else Log.runWith(sink, () -> emitServed(served))

/// HttpServer の結果の行。413 / 431 はヘッダまで読めているので method / path と、あれば X-Request-Id が付く。
def emitServed(served: HttpServer.Served): Unit \ {IO, Log} =
    let base = Log.Fields.empty()
        |> Log.Fields.opt("request.id", RequestId.ofHeaders(served#headers))
        |> Log.Fields.str("http.request.method", served#method)
        |> Log.Fields.str("url.path", served#path)
        |> LogFields.response(served#status, served#elapsedMs, served#requestBytes, served#responseBytes);
    let fields = match served#failure {
        case Some(error) => Log.exception(error, base)
        case None        => base
    };
    Log.emit({ severity = LogFields.responseSeverity(served#path, served#status, Option.nonEmpty(served#failure), base), message = "request", fields = fields })

///
/// 一致した行を実行する。engine が None ならエンジン無し、Account ならプロジェクトを見ない。
/// Content / Admin は params の projectSlug（無ければ既定プロジェクト）を id に解き、無ければ 404、エンジンを組めなければ 503。
/// 身元の種類とプロジェクト slug をリクエストの行（extra）と、リゾルバに渡す span（Context の log）に足す。
///
/// WhyNot: エンジンの要らない道（/health、/jobs/tick）でエンジンを組まないのは、型定義が壊れた時に死活監視まで 503 になり、
/// プロジェクトの SELECT が余分に走るため。
///
def runRoute(runtime: Runtime, span: Log.Fields, extra: Ref[Log.Fields, Static], found: Route[{Graphql, Log, Observe, IO}], routeRequest: RouteRequest): HttpResponse \ {IO, Log, Observe} =
    let projectSlug = Map.get(Router.projectSlugParam(), routeRequest#params);
    let routeFields = Log.Fields.empty()
        |> Log.Fields.str("credential.kind", LogFields.credentialKind(routeRequest#credential))
        |> Log.Fields.opt("project", projectSlug |> Option.withDefault(default = runtime#defaultProjectSlug));
    Ref.put(Ref.get(extra) |> Log.Fields.merge(routeFields), extra);
    let contextFields = span |> Log.Fields.merge(routeFields);
    let execute = () -> (found#handle)(routeRequest);
    match found#engine {
        case None                 => Graphql.runWithoutEngine(execute)
        case Some(Engine.Account) => runObserved(runtime#accountEngine, contextFields, extra, execute)
        case Some(engine)         =>
            match resolveProject(runtime#pool, runtime#defaultProject, projectSlug) {
                case Err(message)        => unavailable(message)
                case Ok(None)            => { let message = "プロジェクト '${projectSlug |> Option.getWithDefault("")}' がありません"; Observe.note(Log.Fields.empty() |> LogFields.rejection("no_project", message)); Server.notFound(message) }
                case Ok(Some(projectId)) => match engineOf(runtime, engine, projectId) {
                    case Ok(built)    => runObserved(built, contextFields, extra, execute)
                    case Err(message) => unavailable(message)
                }
            }
    }

/// 503。理由をリクエストの行に積む。
def unavailable(message: String): HttpResponse \ Observe =
    Observe.note(Log.Fields.empty() |> LogFields.rejection("unavailable", message));
    Server.unavailable(message)

///
/// エンジンで Graphql effect を本物の実行にし、時計を入れる。実行ごとに Context に span を入れ（Runner がリゾルバの中の行に付ける）、
/// 操作の名前と種類、errors[] の code を extra に積む（リクエストの行に乗る）。Runner が決めた身元の属性（user.id / api_key.name、
/// 検証に落ちた印）は Context の observe で extra に戻す。Runner の側が勝つ（Map.union は左が勝つ）ので、ヘッダから読んだ credential.kind を上書きできる。
///
/// WhyNot: observe を effect にしないのは、Runner は graphql-java の Java コールバックの中で動き、effect はそこを越えられないため。
/// Ref を閉じ込めたラムダは値なので越えられる。
///
def runObserved(engine: Graphql.Engine, contextFields: Log.Fields, extra: Ref[Log.Fields, Static], thunk: Unit -> HttpResponse \ {Graphql, Log, Observe, IO}): HttpResponse \ {IO, Log, Observe} =
    run {
        thunk()
    } with handler Graphql {
        def execute(request, context, resume) = {
            let observe = fields -> Ref.put(Map.union(fields, Ref.get(extra)), extra);
            let response = Graphql.executeWith(engine, request, { log = contextFields, observe = observe | context });
            Ref.put(Ref.get(extra) |> LogFields.graphql(request, response), extra);
            resume(response)
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
def ensureAppRole(owner: Jdbc.ConnectionConfig, app: Option[Jdbc.ConnectionConfig]): Result[String, Unit] \ {IO, Log} = match app {
    case None        => { Log.Fields.empty() |> Log.Fields.str("db.user", owner#user) |> Log.warn("db: CMS_DB_APP_PASSWORD が無いので所有者で繋ぐ（RLS は効くがロール分離は無い）"); Ok(()) }
    case Some(found) => AppRole.ensure(owner, found)
}

///
/// プールを開き、1 回 SELECT 1 を投げて届くことを確かめる。届かなければ閉じて Err。
///
/// WhyNot: 届かなくても起動して /health に任せる、にしないのは、DSN の打ち間違いを起動時に気づけないと
/// 公開サイトのビルドが 503 で落ちるまで分からないため。
///
def openPool(connection: Jdbc.ConnectionConfig): Result[String, Pool] \ {IO, Sys.Env} =
    let pool = Pool.open(DbConfig.poolFromEnv(connection));
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
def prepareMigrations(connection: Jdbc.ConnectionConfig, mode: Option[String]): Result[String, Unit] \ {IO, Fs.FileRead, Log} =
    let outcome = run {
        Migrate.runWithResult(() -> DbError.runWithFailure(() ->
            if (mode == Some("apply"))
                Migrate.apply(Migrate.defaultConfig(connection), "migrations") |> List.forEach(version -> Log.Fields.empty() |> Log.Fields.str("migration.version", version) |> Log.info("migration applied"))
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
