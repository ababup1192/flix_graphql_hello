///
/// アプリ用の DB ロール（cms_app）。表の所有者ではないので RLS が効き、DDL ができない。
/// 起動時に所有者の接続で作る（migration に書けないのは、パスワードを環境変数から入れるため）。
///
mod AppRole {

    ///
    /// ロールが無ければ作り、パスワードを入れ、public schema の全表と sequence の使用権を与える。
    /// 以後に migration が作る表にも効くよう ALTER DEFAULT PRIVILEGES も置く。
    ///
    /// WhyNot: 名前とパスワードを文字列で埋め込むのは、CREATE / ALTER ROLE がバインド変数を受けないため。
    /// 名前は識別子の規則で検査し、パスワードは quote_literal を通す。
    ///
    pub def ensure(connection: Jdbc.ConnectionConfig, name: String, password: String): Result[String, Unit] \ IO =
        if (not String.isMatch(regex = "^[a-z_][a-z0-9_]{0,62}$", name))
            Err("CMS_DB_APP_USER '${name}' はロール名の形ではありません（英小文字・数字・_）")
        else {
            let outcome = DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(connection, _ -> {
                let exists = Sql.fetch("SELECT 1 AS found FROM pg_roles WHERE rolname = $1", SqlValue.Str(name) :: Nil) |> List.nonEmpty;
                if (exists) () else discard Sql.execute("CREATE ROLE ${name} NOLOGIN NOBYPASSRLS", Nil);
                discard Sql.execute("ALTER ROLE ${name} LOGIN NOBYPASSRLS PASSWORD ${quoteLiteral(password)}", Nil);
                discard Sql.execute("GRANT USAGE ON SCHEMA public TO ${name}", Nil);
                discard Sql.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${name}", Nil);
                discard Sql.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${name}", Nil);
                discard Sql.execute("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${name}", Nil);
                discard Sql.execute("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${name}", Nil)
            })));
            Result.mapErr(failure -> "アプリ用のロール '${name}' を用意できません: ${failure}", outcome)
        }

    /// SQL の文字列リテラル（' を '' に）。
    def quoteLiteral(text: String): String =
        "'" + String.replace(src = "'", dst = "''", text) + "'"

}
