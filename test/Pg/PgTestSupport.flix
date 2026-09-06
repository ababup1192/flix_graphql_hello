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
    pub def resetSchema(): Unit \ DbWrite + RawSql + IO =
        discard Sql.execute("DROP TABLE IF EXISTS entry_versions, entry_unique_values, entry_contents, entries, content_fields, content_types, sqlfx_migrations CASCADE", Nil);
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
    pub def withDb(body: Unit -> a \ ef): Result[DbFailure, Result[CmsErr.CmsFailure, a]] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, RawSql, CmsErr}) + IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(config(), _ -> {
            resetSchema();
            CmsErr.runWithResult(body)
        })))

}
