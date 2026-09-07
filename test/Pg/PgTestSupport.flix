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
        discard Sql.execute("DROP TABLE IF EXISTS entry_links, entry_versions, entry_unique_values, entry_contents, entries, content_fields, content_types, projects, sqlfx_migrations CASCADE", Nil);
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
    pub def withDb(body: Unit -> a \ ef): Result[DbFailure, Result[CmsErr.CmsFailure, a]] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, Tenant}) + IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(config(), _ -> {
            resetSchema();
            CmsErr.runWithResult(() -> Tenant.runWith(ProjectId.default(), body))
        })))

    ///
    /// テーブルを作り直して seed を当てる。失敗するのはテストの前提が壊れているので止める。
    ///
    pub def seed(thunk: Unit -> b \ ef): b \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, Tenant}) + IO =
        withDb(thunk) |> seededOrBug

    ///
    /// プール越しに 1 つの Tx で書く（withDb の外から、コンテンツ API のエンジンと同じ接続先を触る）。
    ///
    pub def mutate(pool: Pool, thunk: Unit -> a \ ef): Result[DbFailure, Result[CmsErr.CmsFailure, a]] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr, Tenant}) + IO =
        DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Tenant.runWith(ProjectId.default(), () -> Pool.withLazyTx(pool, thunk))))

    ///
    /// プールを開いて body に渡し、必ず閉じる。
    ///
    pub def withPool(body: Pool -> a \ ef): a \ ef + IO =
        let pool = Pool.open(Pool.defaultConfig(config()));
        let result = body(pool);
        Pool.close(pool);
        result

    ///
    /// テーブルを作り直して seed を当て、その結果と管理 API の Schema を body に渡す。seed が失敗するのはテストの前提が壊れている。
    ///
    pub def withAdminApi(seeding: Unit -> b \ ef2, body: (Schema, b) -> a \ ef): a \ (ef2 - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, Tenant}) + ef + IO =
        withPool(pool -> {
            let seeded = seed(seeding);
            body(AdminSchema.make(AdminRunner.make(pool, ProjectId.default())), seeded)
        })

    ///
    /// テーブルを作り直して seed を当て、コンテンツ API に問い合わせる ask を body に渡す。エンジンは定義から組み直す（目印を毎回見る）。
    ///
    pub def withContentApi(seeding: Unit -> b \ ef2, body: (String -> (Value, Option[String]) \ IO) -> a \ ef): a \ (ef2 - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, Tenant}) + ef + IO =
        withContentApiAndPool(seeding, (_, ask) -> body(ask))

    ///
    /// withContentApi に加えて pool も渡す。テストの途中で mutate したい時用。
    ///
    pub def withContentApiAndPool(seeding: Unit -> b \ ef2, body: (Pool, String -> (Value, Option[String]) \ IO) -> a \ ef): a \ (ef2 - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr, Tenant}) + ef + IO =
        withPool(pool -> {
            discard seed(seeding);
            let cache = ContentEngine.create();
            body(pool, queryText -> GraphqlTestKit.askEngine(engineOrBug(cache, pool), queryText))
        })

    ///
    /// 今の定義のエンジン。組めないのはテストの前提が壊れている。
    ///
    def engineOrBug(cache: ContentEngine.Cache, pool: Pool): Graphql.Engine \ IO = match ContentEngine.current(cache, pool, ProjectId.default()) {
        case Ok(engine)   => engine
        case Err(message) => bug!("engine: ${message}")
    }

    def seededOrBug(result: Result[DbFailure, Result[CmsErr.CmsFailure, b]]): b = match result {
        case Ok(Ok(seeded))  => seeded
        case Ok(Err(failure)) => bug!("seed: ${CmsErr.toMessage(failure)}")
        case Err(failure)    => bug!("seed: ${failure}")
    }

}
