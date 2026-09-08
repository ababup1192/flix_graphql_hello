///
/// 死活監視と、バックグラウンドワーカーへの問い合わせ。GET /health と POST /jobs/tick が使う。
/// 本番は ofPool（プール・ワーカー・Listener を閉じ込める）、テストは固定の答えを返す値を入れる。
///
/// - checkDb: DB に届くか。届かなければ理由を Err に入れる
/// - jobsSummary: バックグラウンドワーカーのまとめ（最終実行時刻と待ち・失敗の件数）
/// - runJobs: 外部トリガーから 1 周回す。失敗した所の説明（空なら全部通った）
/// - connections: HTTP の同時接続の今の数と上限
/// - poolStats: DB の接続プールの数字（HTTP の接続数とは別）
/// - heal: 自己回復の判断を 1 回進める（Exit が決まればこの中でプロセスが終わる）
///
/// WhyNot: effect にしないのは、入力（プール・ワーカー・Listener）が起動時に固定で、読む所が Server の直下なので
/// 値で渡しても引数が 1 本しか増えないため。差し替えには当たるが、IdGen / ObjectStore のように深い所で使う物ではない。
/// ログを持たないのは、それは Log の effect で Route に付くため。
///
pub type alias Health[ef: Eff] = {
    checkDb     = Unit -> Result[String, Unit] \ ef,
    jobsSummary = Unit -> BackgroundJobs.Summary \ ef,
    runJobs     = Unit -> List[String] \ ef,
    connections = Unit -> HttpServer.Connections \ ef,
    poolStats   = Unit -> Pool.PoolStats \ ef,
    heal        = Unit -> Unit \ ef
}

mod Health {

    ///
    /// プールとワーカーと Listener の状態で答える。runJobs は仕事の行（Log）を出す。
    /// heal は自己回復の見張り（CMS_SELF_HEAL=off なら None）。
    ///
    pub def ofPool(pool: Pool, jobs: BackgroundJobs.State, listener: HttpServer.Listener, heal: Option[SelfHeal.Watch]): Health[{IO, Log}] =
        { checkDb     = _ -> ping(pool),
          jobsSummary = _ -> BackgroundJobs.summary(pool, jobs),
          runJobs     = _ -> BackgroundJobs.tick(pool, jobs),
          connections = _ -> HttpServer.connections(listener),
          poolStats   = _ -> Pool.stats(pool),
          heal        = _ -> BackgroundJobs.healCheck(pool, jobs, heal) }

    ///
    /// プールから接続を 1 本借りて SELECT 1 を投げる。借りられない・届かないは理由付きの Err。
    ///
    pub def ping(pool: Pool): Result[String, Unit] \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withConnection(pool, _ -> discard Sql.fetch("SELECT 1", Nil))))
            |> Result.mapErr(failure -> "${failure}")

}
