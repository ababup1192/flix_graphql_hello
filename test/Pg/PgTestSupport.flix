///
/// 実 PG のテストで共有する部品: 接続設定、migrations の当て直し、接続の開閉。
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
    def resetSchema(): Unit \ DbWrite + RawSql + IO =
        discard Sql.execute("DROP TABLE IF EXISTS scheduled_actions, webhook_deliveries, webhooks, api_keys, invitations, memberships, org_members, users, organizations, assets, entry_links, entry_versions, entry_unique_values, entry_contents, entries, content_fields, content_types, projects, sqlfx_migrations CASCADE", Nil);
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
    /// プール越しに 1 つの Tx で書く（withDb の外から、コンテンツ API のエンジンと同じ接続先を触る）。
    ///
    pub def mutate(pool: Pool, thunk: Unit -> a \ ef): Result[DbFailure, Result[CmsErr.CmsFailure, a]] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr, IdGen, Tenant, Session, ObjectStore}) + IO =
        Tenant.runWith(ProjectId.default(), () -> Session.runWith(Actor.System, () -> IdGen.runWithRandom(() -> withStorage(() -> DbRunner.transact(pool, Some(ProjectId.default()), thunk)))))

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
    /// テーブルを作り直して seed を当て、その結果と管理 API の Schema を body に渡す。seed が失敗するのはテストの前提が壊れている。
    ///
    pub def withAdminApi(seeding: Unit -> b \ ef2, body: (Schema, b) -> a \ ef): a \ (ef2 - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, IdGen, Tenant, Session, ObjectStore}) + ef + IO =
        withPool(pool -> {
            let seeded = seed(seeding);
            body(AdminSchema.make(deps(), AdminRunner.make(pool, deps(), ProjectId.default())), seeded)
        })

    ///
    /// テーブルを作り直して seed を当て、Account API（Tenant 無し）の Schema を body に渡す。
    ///
    pub def withAccountApi(seeding: Unit -> b \ ef2, body: (Schema, b) -> a \ ef): a \ (ef2 - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, IdGen, Tenant, Session, ObjectStore}) + ef + IO =
        withPool(pool -> {
            let seeded = seed(seeding);
            body(AccountSchema.make(deps(), AccountRunner.make(pool, deps())), seeded)
        })

    ///
    /// テスト用の依存。認証は閉じ、bootstrap の owner は owner@test。
    ///
    pub def deps(): Deps \ IO = Deps.forTest(storage())

    ///
    /// bootstrap の owner（owner@test）としての身元。初回の問い合わせで users が作られ、既定の組織の owner になる。
    ///
    pub def ownerCredential(): Credential = Credential.Bearer("test", "owner", "owner@test", "Owner")

    ///
    /// owner として管理 API に問い合わせる。
    ///
    pub def askOwner(schema: Schema): String -> (Value, Option[String]) \ IO =
        queryText -> GraphqlTestKit.askWith(schema, Context.withCredential(ownerCredential()), queryText)

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
            body(pool, queryText -> GraphqlTestKit.askEngineWith(engineOrBug(cache, pool), Context.withCredential(ownerCredential()), queryText))
        })

    ///
    /// 今の定義のエンジン。組めないのはテストの前提が壊れている。
    ///
    def engineOrBug(cache: ContentEngine.Cache, pool: Pool): Graphql.Engine \ IO = match ContentEngine.current(cache, pool, ProjectId.default()) {
        case Ok(engine)   => engine
        case Err(message) => bug!("engine: ${message}")
    }

    pub def seededOrBug(result: Result[DbFailure, Result[CmsErr.CmsFailure, b]]): b = match result {
        case Ok(Ok(seeded))  => seeded
        case Ok(Err(failure)) => bug!("seed: ${CmsErr.toMessage(failure)}")
        case Err(failure)    => bug!("seed: ${failure}")
    }

}
