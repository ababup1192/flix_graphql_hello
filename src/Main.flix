///
/// 起動。SDL と生成物の一致、PostgreSQL の接続、migrations の適用済みを確かめ、管理 API（/admin/graphql）と
/// コンテンツ API（/graphql。型の定義から実行時に組み、定義が変われば組み直す）、Account API（/account/graphql。プロジェクトを選ぶ前の操作）を 8080 番で待つ。
/// パスの先頭に /p/{プロジェクト slug} を付けるとそのプロジェクト、無ければ既定プロジェクト（CMS_DEFAULT_PROJECT。空なら 404）。
/// 起動に失敗したらメッセージを出して終了コード 1 で終わる。
///
/// 環境変数: CMS_DSN / CMS_DB_USER / CMS_DB_PASSWORD（DbConfig）、ASSET_*（StorageConfig。省略時は asset 無し）、
/// CMS_CORS_ORIGINS（カンマ区切り。省略時は CORS 無し）、CMS_BASE_DOMAIN（`{プロジェクト slug}.{base}` の Host でプロジェクトを選ぶ。省略時は /p/ だけ）、
/// CMS_DEFAULT_PROJECT（プロジェクト slug 無しの時のプロジェクト slug。省略時は default、空ならプロジェクト slug 無しは 404）、CMS_SIGNUP（open / closed）、CMS_MIGRATE（apply なら起動時に migrations/ を当てる。
/// 省略時は check で、未適用があれば起動しない）、CMS_VERSION（/health に出す版。省略時は dev）
///
def main(): Unit \ {IO, Chan, NonDet, Fs.FileRead, Sys.Exit, Sys.Env} =
    let started = forM (
        _           <- checkGenerated(GeneratedCheck.admin());
        _           <- checkGenerated(GeneratedCheck.account());
        connection  <- DbConfig.fromEnv();
        pool        <- openPool(connection);
        _           <- prepareMigrations(connection, Sys.Env.getVar("CMS_MIGRATE"));
        storage     <- StorageConfig.fromEnv();
        auth        <- AuthConfig.fromEnv();
        deps        <- Ok({ storage = storage, auth = auth });
        defaultProject <- resolveDefaultProject(pool, Sys.Env.getVar("CMS_DEFAULT_PROJECT"));
        accountEngine  <- AccountSchema.engine(pool, deps);
        adminEngines <- Ok(AdminEngine.create(deps));
        _           <- AdminEngine.current(adminEngines, pool, defaultProject |> Option.getWithDefault(ProjectId.default()))
    ) yield (pool, adminEngines, deps, defaultProject, accountEngine);
    match started {
        case Err(message) => { println(message); Sys.Exit.exit(1) }
        case Ok((pool, adminEngines, deps, defaultProject, accountEngine)) =>
            let jwks = TokenVerifier.createCache();
            let cors = { allowedOrigins = Sys.Env.getVar("CMS_CORS_ORIGINS") |> Option.getWithDefault("") |> Cors.parseOrigins };
            let version = Sys.Env.getVar("CMS_VERSION") |> Option.getWithDefault("dev");
            let baseDomain = Sys.Env.getVar("CMS_BASE_DOMAIN") |> Option.filter(text -> not String.isEmpty(text));
            let contentConfig = { cors = cors, graphqlPath = "/graphql", version = version };
            let adminConfig = { cors = cors, graphqlPath = "/admin/graphql", version = version };
            let accountConfig = { cors = cors, graphqlPath = "/account/graphql", version = version };
            let engineCache = ContentEngine.create(deps);
            // WhyNot: コンテンツ API を実行する時以外（/health、404、preflight、GET）でエンジンを組まないのは、型定義が壊れた時に
            // 死活監視や preflight まで 503 になり、404 ごとに目印の SELECT が走るため。GraphQL を実行しない道なので管理 API のエンジンで受ける
            // WhyNot: 開発モード（X-Dev-User を信じる）で 127.0.0.1 にしか bind しないのは、ヘッダで人になれる経路を LAN に開けないため
            let bind = match deps#auth#mode { case AuthConfig.Mode.Dev => Some("127.0.0.1") case _ => None };
            HttpServer.listen(bind, 8080, request ->
                Health.runWithPool(pool, () -> {
                    let (projectSlug, path) = Server.projectOf(baseDomain, request);
                    let scoped = { path = path | request };
                    let credential = credentialOf(deps#auth, jwks, request);
                    // WhyNot: プロジェクト slug 無しで既定プロジェクトも無い時に Account API のエンジンで受けるのは、/health と 404 を
                    // プロジェクト無しで返すため（Account API は GraphQL のパス以外を実行しない）
                    if (Option.isEmpty(projectSlug) and (Server.pathOf(path) == accountConfig#graphqlPath or Option.isEmpty(defaultProject)))
                        Graphql.runWithEngine(accountEngine, () -> Server.handle(accountConfig, credential, scoped))
                    else
                    match resolveProject(pool, defaultProject, projectSlug) {
                        case Err(message)      => Server.unavailable(message)
                        case Ok(None)          => Server.notFound("プロジェクト '${projectSlug |> Option.getWithDefault("")}' がありません")
                        case Ok(Some(projectId)) =>
                            if (Server.needsGraphqlEngine(contentConfig, scoped))
                                match ContentEngine.current(engineCache, pool, projectId) {
                                    case Ok(engine)   => Graphql.runWithEngine(engine, () -> Server.handle(contentConfig, credential, scoped))
                                    case Err(message) => Server.unavailable(message)
                                }
                            else
                                match AdminEngine.current(adminEngines, pool, projectId) {
                                    case Ok(engine)   => Graphql.runWithEngine(engine, () -> Server.handle(adminConfig, credential, scoped))
                                    case Err(message) => Server.unavailable(message)
                                }
                    }
                }))
    }

///
/// リクエストの身元。トークンのヘッダがあれば発行元で検証し、無ければ X-Api-Key、どちらも無ければ Missing。
/// dev モードは X-Dev-User の email を信じる（AuthConfig が CMS_VERSION=dev の時にしか許さない）。
///
def credentialOf(auth: AuthConfig.AuthConfig, jwks: TokenVerifier.JwksCache, request: HttpRequest): Credential \ IO =
    let verified = token -> match auth#mode {
        case AuthConfig.Mode.Jwks(config) => Net.Http.runWithIO(() -> Time.Clock.runWithIO(() -> TokenVerifier.runWithJwks(config, jwks, () -> TokenVerifier.verify(token))))
        case AuthConfig.Mode.Dev          => TokenVerifier.runDev(() -> TokenVerifier.verify(token))
        case AuthConfig.Mode.Closed       => Err("管理 API は閉じています（CMS_AUTH=none）")
    };
    let headerName = match auth#mode { case AuthConfig.Mode.Dev => "X-Dev-User" case _ => auth#tokenHeader };
    match (AuthConfig.tokenOf(headerName, request#headers), AuthConfig.apiKeyOf(request#headers)) {
        case (Some(token), _) => match verified(token) {
            case Ok(principal) => Credential.Bearer(principal#issuer, principal#subject, principal#email, principal#name)
            case Err(reason)   => Credential.Invalid(reason)
        }
        case (None, Some(key)) => Credential.ApiKey(key)
        case (None, None)      => Credential.Missing
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
