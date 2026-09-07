///
/// 死活監視と、バックグラウンドワーカーへの問い合わせ。GET /health と POST /jobs/tick が使う。
/// どう確かめるか（プールで SELECT 1 する・テストでは固定の答えを返す）はハンドラが決める。
///
pub eff Health {
    ///
    /// DB に届くか。届かなければ理由を Err に入れる。
    ///
    def checkDb(): Result[String, Unit]
    ///
    /// バックグラウンドワーカーが最後に 1 周した時刻（ISO 8601）。まだなら None。
    ///
    def jobsLastTick(): Option[String]
    ///
    /// 外部トリガーから 1 周回す。失敗した所の説明（空なら全部通った）。
    ///
    def runJobs(): List[String]
}

mod Health {

    ///
    /// プールと ワーカーの状態で答えるハンドラ。
    ///
    pub def runWithPool(pool: Pool, jobs: BackgroundJobs.State, f: Unit -> a \ ef): a \ (ef - Health) + IO =
        run f() with handler Health {
            def checkDb(resume)      = resume(ping(pool))
            def jobsLastTick(resume) = resume(BackgroundJobs.lastTickAt(jobs))
            def runJobs(resume)      = resume(BackgroundJobs.tick(pool, jobs))
        }

    ///
    /// プールから接続を 1 本借りて SELECT 1 を投げる。借りられない・届かないは理由付きの Err。
    ///
    pub def ping(pool: Pool): Result[String, Unit] \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withConnection(pool, _ -> discard Sql.fetch("SELECT 1", Nil))))
            |> Result.mapErr(failure -> "${failure}")

}
