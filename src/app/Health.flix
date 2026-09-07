///
/// 死活監視と、バックグラウンドワーカーへの問い合わせ。GET /health と POST /jobs/tick が使う。
/// 本番は ofPool（プール・ワーカー・Listener を閉じ込める）、テストは固定の答えを返す値を入れる。
///
/// - checkDb: DB に届くか。届かなければ理由を Err に入れる
/// - jobsSummary: バックグラウンドワーカーのまとめ（最終実行時刻と待ち・失敗の件数）
/// - runJobs: 外部トリガーから 1 周回す。失敗した所の説明（空なら全部通った）
/// - connections: HTTP の同時接続の今の数と上限
///
/// WhyNot: effect にしないのは、入力（プール・ワーカー・Listener）が起動時に固定で、読む所が Server の直下なので
/// 値で渡しても引数が 1 本しか増えないため。差し替えには当たるが、IdGen / ObjectStore のように深い所で使う物ではない。
///
pub type alias Health[ef: Eff] = {
    checkDb     = Unit -> Result[String, Unit] \ ef,
    jobsSummary = Unit -> BackgroundJobs.Summary \ ef,
    runJobs     = Unit -> List[String] \ ef,
    connections = Unit -> HttpServer.Connections \ ef
}

mod Health {

    ///
    /// プールとワーカーと Listener の状態で答える。
    ///
    pub def ofPool(pool: Pool, jobs: BackgroundJobs.State, listener: HttpServer.Listener): Health[IO] =
        { checkDb     = _ -> ping(pool),
          jobsSummary = _ -> BackgroundJobs.summary(pool, jobs),
          runJobs     = _ -> BackgroundJobs.tick(pool, jobs),
          connections = _ -> HttpServer.connections(listener) }

    ///
    /// プールから接続を 1 本借りて SELECT 1 を投げる。借りられない・届かないは理由付きの Err。
    ///
    pub def ping(pool: Pool): Result[String, Unit] \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withConnection(pool, _ -> discard Sql.fetch("SELECT 1", Nil))))
            |> Result.mapErr(failure -> "${failure}")

}
