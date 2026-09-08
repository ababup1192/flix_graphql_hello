///
/// 実 PG のテストで共有する部品: 接続設定、migrations の当て直し、接続の開閉、Credential（owner / Bearer / pepper）と認証、
/// スキーマとエンジンの組み立て、プール越しの Tx、名前付きの比較。
///
mod PgTestSupport {

    use DbError.DbFailure

    ///
    /// 接続設定。CMS_DSN が無ければ即 panic（黙って成功させない）。
    ///
    pub def config(): Jdbc.ConnectionConfig \ IO =
        run {
            match DbConfig.fromEnv() {
                case Ok(found)    => found
                case Err(message) => bug!("${message}。make test-pg で回す")
            }
        } with Sys.Env.runWithIO

    ///
    /// テーブルを消して migrations/ を当て直す。migrate 自体もここで毎回通る。
    ///
    /// WhyNot: DROP TABLE の lock_timeout を接続の既定（CMS_DB_TIMEOUT_SECONDS）に任せないのは、前のテストが接続を漏らして
    /// Tx が開いたままだと DROP がロック待ちで止まり、どのテストが漏らしたか分からないまま何十分も待つため。数秒で FAIL にする。
    def resetSchema(): Unit \ DbWrite + RawSql + IO =
        discard Sql.execute("SET lock_timeout = '5s'", Nil);
        discard Sql.execute("DROP TABLE IF EXISTS cdn_purges, scheduled_actions, webhook_deliveries, webhooks, personal_access_tokens, api_keys, invitations, memberships, org_members, users, organizations, assets, entry_links, entry_versions, entry_unique_values, entry_contents, entries, content_fields, content_types, projects, sqlfx_migrations CASCADE", Nil);
        discard Sql.execute("RESET lock_timeout", Nil);
        let applied = run {
            Migrate.runWithResult(() -> Migrate.apply(Migrate.defaultConfig(config()), "migrations"))
        } with Fs.ReadFile.runWithFileRead
          with Fs.FileRead.runWithIO
          with Fs.DirList.runWithIO;
        match applied {
            case Ok(_)        => ()
            case Err(message) => bug!("migrate failed: ${message}")
        }

    ///
    /// テーブルを作り直し、接続を開いて body を走らせ、必ず閉じる。DB の失敗は DbFailure、業務エラーは CmsFailure に落とす。
    /// テストは全部同じテーブルを作り直すので、直列に走る前提。
    ///
    pub def withDb(body: Unit -> a \ ef): Result[DbFailure, Result[CmsErr.CmsFailure, a]] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, IdGen, Tenant, Session, ObjectStore}) + IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(config(), _ -> {
            resetSchema();
            TenantTx.stampConnection(ProjectId.default());
            CmsErr.runWithResult(() -> Tenant.runWith(ProjectId.default(), () -> Session.runWith(Actor.System, () -> IdGen.runWithRandom(() -> withStorage(body)))))
        })))

    ///
    /// withDb の中で別のプロジェクトとして走らせる。Tenant と RLS の印（接続に効く物）を両方切り替え、終わったら既定に戻す。
    ///
    pub def asProject(projectId: ProjectId, thunk: Unit -> a \ ef): a \ (ef - Tenant) + DbRead =
        TenantTx.stampConnection(projectId);
        let result = Tenant.runWith(projectId, thunk);
        TenantTx.stampConnection(ProjectId.default());
        result

    ///
    /// asset の保存先（MinIO）。ASSET_ENDPOINT が無ければ未設定の handler。
    ///
    pub def storage(): Option[StorageConfig.StorageConfig] \ IO =
        run {
            match StorageConfig.fromEnv() {
                case Ok(found)    => found
                case Err(message) => bug!(message)
            }
        } with Sys.Env.runWithIO

    /// ObjectStore を本物（Http と Clock は IO）で入れる。
    pub def withStorage(body: Unit -> a \ ef): a \ (ef - {ObjectStore, Net.Http.Http, Time.Clock.Clock}) + IO =
        Net.Http.runWithIO(() -> Time.Clock.runWithIO(() -> ObjectStore.runWith(storage(), body)))

    ///
    /// テーブルを作り直して seed を当てる。失敗するのはテストの前提が壊れているので止める。
    ///
    pub def seed(thunk: Unit -> b \ ef): b \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, IdGen, Tenant, Session, ObjectStore}) + IO =
        withDb(thunk) |> seededOrBug

    ///
    /// プール越しに 1 つの Tx で System として書く（withDb の外から、コンテンツ API のエンジンと同じ接続先を触る）。Runner と同じ transact を通る。
    ///
    pub def mutate(pool: Pool, thunk: Unit -> a \ ef): Result[ApplicationFailure, a] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr, IdGen, Tenant, Session, ObjectStore}) + IO =
        Tenant.runWith(ProjectId.default(), () -> IdGen.runWithRandom(() -> withStorage(() -> DbRunner.transact(pool, Some(ProjectId.default()), Actor.System, thunk))))

    ///
    /// mutate の結果を取り出す。失敗するのはテストの前提が壊れているので止める。
    ///
    pub def mutateOrBug(pool: Pool, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr, IdGen, Tenant, Session, ObjectStore}) + IO =
        match mutate(pool, thunk) {
            case Ok(found)    => found
            case Err(failure) => bug!("mutate: ${ApplicationFailure.describe(failure)}")
        }

    ///
    /// テスト用の pepper（CmsTestKit と同じ物）。
    ///
    pub def pepper(): SecretHash.Pepper = CmsTestKit.pepper()

    ///
    /// ログインの JWT の身元。name は subject と同じ。
    ///
    pub def bearer(subject: String, email: String): Credential = Credential.Bearer("test", subject, email, subject)

    ///
    /// bootstrap の owner（owner@test）の users の行。初回の問い合わせで作られ、既定の組織の owner になる。
    ///
    pub def ownerUser(): User \ Db + IdGen =
        Accounts.resolveUser({ ownerEmail = Some("owner@test") }, { issuer = "test", subject = "owner", email = "owner@test", name = "owner" })

    ///
    /// その人（ログインの JWT）として今のプロジェクトで走らせる。
    ///
    pub def runAs(user: User, thunk: Unit -> a \ ef): a \ (ef - Session) + DbRead + Tenant =
        Session.runWith(Accounts.actorFor(user, Tenant.current(), Login.Interactive), thunk)

    ///
    /// bootstrap の owner（ログインの JWT）として今のプロジェクトで走らせる。
    ///
    pub def asOwner(thunk: Unit -> a \ ef): a \ (ef - Session) + Db + IdGen + Tenant =
        runAs(ownerUser(), thunk)

    ///
    /// 署名付き URL へ置く。宣言した Content-Type で送る。成功なら status。
    ///
    pub def putTo(url: String, mime: String, body: String): Result[String, Int32] \ IO =
        Net.Http.runWithIO(() ->
            Net.Http.send(Net.HttpRequest.put(url, body) |> Net.HttpRequest.withContentType(mime))
                |> Result.map(Net.HttpResponse.status)
                |> Result.mapErr(err -> "${err}"))

    ///
    /// 期待値と観測した値を (名前, 文字にした値) にする。型の違う値を 1 つの List に並べて比べ、落ちた時にどの名前が違うか読めるようにする。
    /// 期待値の側も同じ関数で作るので、比べる相手は同じ型の値の ToString。
    ///
    pub def named(name: String, value: a): (String, String) with ToString[a] = (name, "${value}")

    ///
    /// アプリ用のロール（cms_app）の接続設定。API のテストはこれで繋ぎ、RLS 越しに動く事を確かめる。
    ///
    /// WhyNot: 所有者（docker の POSTGRES_USER）で繋がないのは、superuser は FORCE でも RLS を素通りし、
    /// Runner の印が抜けていてもテストが通ってしまうため。表の作り直しと migration だけ所有者で行う。
    ///
    pub def appConfig(): Jdbc.ConnectionConfig \ IO =
        let owner = config();
        { url = owner#url, user = "cms_app", password = "cms_app" }

    ///
    /// cms_app のプールを開いて body に渡し、必ず閉じる。ロールが無ければ所有者で作る（以後に作る表にも権限が付く）。
    ///
    pub def withPool(body: Pool -> a \ ef): a \ ef + IO =
        let app = appConfig();
        match AppRole.ensure(config(), app) {
            case Ok(())       => ()
            case Err(message) => bug!(message)
        };
        let pool = Pool.open(Pool.defaultConfig(app));
        let result = body(pool);
        Pool.close(pool);
        result

    ///
    /// テストが問い合わせる API。スキーマと、認証（リクエストに 1 回。Main.runRoute と同じ）に要るプール・エンジンの種類・プロジェクト（Account は無し）。
    ///
    pub type alias Api = { schema = Schema, engine = Engine, pool = Pool, scope = Option[ProjectId] }

    ///
    /// 既定のプロジェクトの管理 API。
    ///
    pub def adminApi(pool: Pool): Api \ IO = adminApiOf(pool, ProjectId.default())

    ///
    /// このプロジェクトの管理 API。
    ///
    pub def adminApiOf(pool: Pool, projectId: ProjectId): Api \ IO =
        { schema = AdminSchema.make(deps(), AdminRunner.make(pool, deps(), projectId)), engine = Engine.Admin, pool = pool, scope = Some(projectId) }

    ///
    /// Account API（Tenant 無し）。
    ///
    pub def accountApi(pool: Pool): Api \ IO =
        { schema = AccountSchema.make(deps(), AccountRunner.make(pool, deps())), engine = Engine.Account, pool = pool, scope = None }

    ///
    /// テーブルを作り直して seed を当て、その結果と管理 API を body に渡す。seed が失敗するのはテストの前提が壊れている。
    ///
    pub def withAdminApi(seeding: Unit -> b \ ef2, body: (Api, b) -> a \ ef): a \ (ef2 - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, IdGen, Tenant, Session, ObjectStore}) + ef + IO =
        withPool(pool -> {
            let seeded = seed(seeding);
            body(adminApi(pool), seeded)
        })

    ///
    /// テーブルを作り直して seed を当て、Account API を body に渡す。
    ///
    pub def withAccountApi(seeding: Unit -> b \ ef2, body: (Api, b) -> a \ ef): a \ (ef2 - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, IdGen, Tenant, Session, ObjectStore}) + ef + IO =
        withPool(pool -> {
            let seeded = seed(seeding);
            body(accountApi(pool), seeded)
        })

    ///
    /// テスト用の依存。認証は閉じ、bootstrap の owner は owner@test。
    ///
    pub def deps(): Deps \ IO = Deps.forTest(storage())

    ///
    /// bootstrap の owner（owner@test）としての Credential。初回の問い合わせで users が作られ、既定の組織の owner になる。
    ///
    pub def ownerCredential(): Credential = Credential.Bearer("test", "owner", "owner@test", "Owner")

    ///
    /// 認証をリクエストに 1 回（Main.runRoute と同じ形。scope のプロジェクトの印を置いた Tx で Authentication.resolve）。
    /// 認証の Tx が戻す属性（SQL の数）は observe に。DB の失敗はテストの前提が壊れている。
    ///
    pub def authenticateObserved(pool: Pool, engine: Engine, scope: Option[ProjectId], observe: Log.Fields -> Unit \ IO, credential: Credential): Result[Rejection, Authenticated] \ IO =
        IdGen.runWithRandom(() -> Time.Clock.runWithIO(() ->
            DbRunner.withTxObserved(pool, scope, observe, () -> Authentication.resolve(deps(), engine, scope, credential))))
            |> sqlOrBug

    ///
    /// Main.runRoute の locate と同じ形で、匿名のコンテンツ API のリクエストを既定のプロジェクトで認証し、同じ Tx でプロジェクトの版を読む
    /// （コンテンツ API の GET の ETag 用）。この Tx が戻す属性（SQL の数）は observe に。DB の失敗はテストの前提が壊れている。
    ///
    pub def locateAnonymousObserved(pool: Pool, observe: Log.Fields -> Unit \ IO): (Result[Rejection, Authenticated], Option[Int64]) \ IO =
        let scope = Some(ProjectId.default());
        IdGen.runWithRandom(() -> Time.Clock.runWithIO(() ->
            DbRunner.withTxObserved(pool, None, observe, () -> {
                TenantTx.stampTx(scope, Actor.Anonymous);
                let auth = Authentication.resolve(deps(), Engine.Content, scope, Credential.Missing);
                (auth, Some(Tenant.runWith(ProjectId.default(), Projects.contentVersion)))
            })))
            |> sqlOrBug

    ///
    /// 認証をリクエストに 1 回。既定のプロジェクト（Account はプロジェクト無し）。
    ///
    pub def authenticate(pool: Pool, engine: Engine, credential: Credential): Result[Rejection, Authenticated] \ IO =
        authenticateObserved(pool, engine, defaultScope(engine), _ -> (), credential)

    /// エンジンの種類ごとの既定のプロジェクト。
    def defaultScope(engine: Engine): Option[ProjectId] = match engine {
        case Engine.Account => None
        case _              => Some(ProjectId.default())
    }

    ///
    /// この Credential で組み立て済みのエンジン（既定のプロジェクト）に問い合わせる ask。
    ///
    pub def askEngineAs(pool: Pool, engine: Engine, built: Graphql.Engine, credential: Credential): String -> (Value, Option[String]) \ IO =
        askScopedAs(pool, engine, defaultScope(engine), built, credential)

    ///
    /// 問い合わせごとに認証し、断られたら Runner の手前で断られた形（data は Null、errors[].message）にする。
    /// 読むだけの文書には先読みの写しを付ける（Main.runObserved と同じ）。
    ///
    def askScopedAs(pool: Pool, engine: Engine, scope: Option[ProjectId], built: Graphql.Engine, credential: Credential): String -> (Value, Option[String]) \ IO =
        queryText -> match authenticateObserved(pool, engine, scope, _ -> (), credential) {
            case Err(rejection) => (Value.Null, Some(Rejection.message(rejection)))
            case Ok(found)      => executeAs(pool, scope, built, found#actor, _ -> (), GraphqlTestKit.queryOnly(queryText)) |> GraphqlTestKit.summarize
        }

    ///
    /// 認証済みユーザーで文書を実行する（Main.executeDocument と同じ形）。読むだけの文書は 1 リクエスト 1 Tx（DbRunner.withRequestTx）の中で
    /// 先読みの写し付き、mutation を含む文書はフィールドごとの Tx。Runner と Tx が observe に戻す属性（SQL と Tx の数）は observe に。Log の行は捨てる。
    ///
    pub def executeAs(pool: Pool, scope: Option[ProjectId], engine: Graphql.Engine, actor: Actor, observe: Log.Fields -> Unit \ IO, request: GraphqlRequest): GraphqlResponse \ IO =
        let context = { observe = observe | Context.withActor(actor) };
        if (Server.isReadOnly(request#queryText))
            fst(Log.runWithList(() -> DbRunner.withRequestTx(pool, scope, actor, observe, Ref.fresh(Static, None), handle ->
                Graphql.executeWith(engine, request, Context.withRequestTx(handle, Context.withPreload(context))))))
        else
            Graphql.executeWith(engine, request, context)

    ///
    /// この Credential で API（管理 API / Account API）に問い合わせる ask。
    ///
    pub def askAs(api: Api, credential: Credential): (String -> (Value, Option[String]) \ IO) \ IO =
        askScopedAs(api#pool, api#engine, api#scope, GraphqlTestKit.engineOrBug(api#schema), credential)

    ///
    /// owner として API に問い合わせる。
    ///
    pub def askOwner(api: Api): (String -> (Value, Option[String]) \ IO) \ IO =
        askAs(api, ownerCredential())

    ///
    /// owner として、variables 付きのリクエストで API に問い合わせる。
    ///
    pub def askOwnerRequest(api: Api): GraphqlRequest -> (Value, Option[String]) \ IO =
        request -> match authenticateObserved(api#pool, api#engine, api#scope, _ -> (), ownerCredential()) {
            case Err(rejection) => bug!("owner の認証に失敗しました: ${Rejection.message(rejection)}")
            case Ok(found)      => executeAs(api#pool, api#scope, GraphqlTestKit.engineOrBug(api#schema), found#actor, _ -> (), request) |> GraphqlTestKit.summarize
        }

    ///
    /// テーブルを作り直して seed を当て、コンテンツ API に問い合わせる ask を body に渡す。エンジンは定義から組み直す（目印を毎回見る）。
    ///
    pub def withContentApi(seeding: Unit -> b \ ef2, body: (String -> (Value, Option[String]) \ IO) -> a \ ef): a \ (ef2 - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, IdGen, Tenant, Session, ObjectStore}) + ef + IO =
        withContentApiAndPool(seeding, (_, ask) -> body(ask))

    ///
    /// withContentApi に加えて pool も渡す。テストの途中で mutate したい時用。
    ///
    pub def withContentApiAndPool(seeding: Unit -> b \ ef2, body: (Pool, String -> (Value, Option[String]) \ IO) -> a \ ef): a \ (ef2 - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, IdGen, Tenant, Session, ObjectStore}) + ef + IO =
        withPool(pool -> {
            discard seed(seeding);
            let cache = ContentEngine.create(deps());
            body(pool, queryText -> askEngineAs(pool, Engine.Content, engineOrBug(cache, pool), ownerCredential())(queryText))
        })

    ///
    /// 今の定義のエンジン。組めないのはテストの前提が壊れている。
    ///
    pub def engineOrBug(cache: ContentEngine.Cache, pool: Pool): Graphql.Engine \ IO = match ContentEngine.current(cache, pool, ProjectId.default()) {
        case Ok(engine)   => engine
        case Err(message) => bug!("engine: ${message}")
    }

    ///
    /// 既定のプロジェクトのコンテンツ API のエンジンを、新しい cache で今の定義から組む。
    ///
    pub def contentEngine(pool: Pool): Graphql.Engine \ IO =
        engineOrBug(ContentEngine.create(deps()), pool)

    ///
    /// 所有者の接続で生 SQL を 1 本流し、影響した行数を返す。行の時刻や状態を直接ずらすテスト用。失敗はテストの前提が壊れている。
    ///
    pub def executeSql(sql: String, params: List[SqlValue]): Int32 \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(config(), _ -> Sql.execute(sql, params)))) |> sqlOrBug

    ///
    /// 所有者の接続で `count(*)::bigint AS total` を返す生 SQL を 1 本流す。RLS を通さずに表の行数を見るテスト用。
    ///
    pub def countSql(sql: String, params: List[SqlValue]): Int64 \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(config(), _ ->
            Sql.fetchOneAs(Decoder.int64("total"), sql, params) |> Option.getWithDefault(-1i64)))) |> sqlOrBug

    def sqlOrBug(result: Result[DbFailure, a]): a = match result {
        case Ok(found)    => found
        case Err(failure) => bug!("sql: ${failure}")
    }

    def seededOrBug(result: Result[DbFailure, Result[CmsErr.CmsFailure, b]]): b = match result {
        case Ok(Ok(seeded))  => seeded
        case Ok(Err(failure)) => bug!("seed: ${CmsErr.toMessage(failure)}")
        case Err(failure)    => bug!("seed: ${failure}")
    }

}
