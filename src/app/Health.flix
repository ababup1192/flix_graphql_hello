///
/// 死活監視の問い合わせ。GET /health が DB に届くかを確かめるために使う。
/// どう確かめるか（プールで SELECT 1 する・テストでは固定の答えを返す）はハンドラが決める。
///
pub eff Health {
    ///
    /// DB に届くか。届かなければ理由を Err に入れる。
    ///
    def checkDb(): Result[String, Unit]
}

mod Health {

    ///
    /// Health.checkDb をプールからの SELECT 1 に置き換えるハンドラ。
    ///
    pub def runWithPool(pool: Pool, f: Unit -> a \ ef): a \ (ef - Health) + IO =
        run f() with handler Health {
            def checkDb(resume) = resume(ping(pool))
        }

    ///
    /// プールから接続を 1 本借りて SELECT 1 を投げる。借りられない・届かないは理由付きの Err。
    ///
    pub def ping(pool: Pool): Result[String, Unit] \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withConnection(pool, _ -> discard Sql.fetch("SELECT 1", Nil))))
            |> Result.mapErr(failure -> "${failure}")

}
