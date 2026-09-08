///
/// 死活監視と、バックグラウンドワーカーへの問い合わせ。GET /health と POST /jobs/tick が使う。
/// 本番は ofPool（プール・ワーカー・Listener を閉じ込める）、テストは固定の答えを返す値を入れる。
///
/// - checkDb: DB に届くか。届かなければ理由を Err に入れる
/// - jobsSummary: バックグラウンドワーカーのまとめ（最終実行時刻と待ち・失敗の件数）
/// - runJobs: 外部トリガーから 1 周回す。失敗した所の説明（空なら全部通った）
/// - connections: HTTP の同時接続の今の数と上限
/// - poolStats: DB の接続プールの数字（HTTP の接続数とは別）
/// - stall: 仕事の周か見張りの周が止まっていれば、その理由（止まっていなければ None）
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
    stall       = Unit -> Option[Health.Stall] \ ef,
    heal        = Unit -> Unit \ ef
}

mod Health {

    import java.lang.System

    ///
    /// 止まっている周。持っている値は、最後に回ってからの経過（ミリ秒）。
    ///
    pub enum Stall with Eq, ToString {
        case Jobs(Int64)
        case Watch(Int64)
    }

    /// /health の本文の reason に出す語。
    pub def stallReason(stall: Stall): String = match stall {
        case Stall.Jobs(_)  => "jobs stalled"
        case Stall.Watch(_) => "watch stalled"
    }

    /// リクエストの行に積むキー。
    pub def stallKey(stall: Stall): String = match stall {
        case Stall.Jobs(_)  => "jobs.stalled_ms"
        case Stall.Watch(_) => "watch.stalled_ms"
    }

    /// 最後に回ってからの経過（ミリ秒）。
    pub def stallMs(stall: Stall): Int64 = match stall {
        case Stall.Jobs(elapsed)  => elapsed
        case Stall.Watch(elapsed) => elapsed
    }

    ///
    /// 周が生きているかを見るための値。
    ///
    /// - now: 今（UNIX ミリ秒）
    /// - startedAt: プロセスが起動した時刻。まだ 1 度も回っていない周はここからの経過で見る
    /// - jobsOn: プロセス内のワーカーを回す設定か（CMS_JOBS）
    /// - jobsIntervalMs / watchIntervalMs: それぞれの周の間隔
    /// - lastTickAt / lastWatchAt: それぞれの周が最後に回った時刻
    ///
    pub type alias Liveness = {
        now = Int64, startedAt = Int64, jobsOn = Bool,
        jobsIntervalMs = Int64, lastTickAt = Option[Int64],
        watchIntervalMs = Int64, lastWatchAt = Option[Int64]
    }

    ///
    /// 止まっている周があれば返す。仕事の周を先に見る。CMS_JOBS=off の時は仕事の周を見ない。
    ///
    pub def stalled(live: Liveness): Option[Stall] =
        let jobs = if (live#jobsOn) elapsedOver(live, live#jobsIntervalMs, live#lastTickAt) |> Option.map(Stall.Jobs) else None;
        let watch = elapsedOver(live, live#watchIntervalMs, live#lastWatchAt) |> Option.map(Stall.Watch);
        jobs |> Option.withDefault(default = watch)

    /// 上限を超えていれば経過（ミリ秒）。まだ 1 度も回っていなければ起動からの経過で見る。
    def elapsedOver(live: Liveness, intervalMs: Int64, lastAt: Option[Int64]): Option[Int64] =
        let elapsed = live#now - (lastAt |> Option.getWithDefault(live#startedAt));
        if (elapsed > stallLimitMs(intervalMs)) Some(elapsed) else None

    ///
    /// 周が止まったと見なすまでの長さ（ミリ秒）。間隔の 3 倍。ただし 30 秒は待つ。
    ///
    /// WhyNot: 間隔の 3 倍だけにしないのは、既定の 2 秒では上限が 6 秒になり、DB が遅い時の 1 周（借り待ちの再試行で 10 秒級）で
    /// 止まっていない周まで 503 になるため。実験 3 回目で見えた停止は 3 分続いていて、30 秒でも十分に捕まる。
    ///
    pub def stallLimitMs(intervalMs: Int64): Int64 =
        Int64.max(intervalMs * 3i64, 30000i64)

    ///
    /// プールとワーカーと Listener の状態で答える。runJobs は仕事の行（Log）を出す。
    /// startedAt はプロセスが起動した時刻、jobsOn は CMS_JOBS、heal は自己回復の見張り（CMS_SELF_HEAL=off なら None）。
    ///
    pub def ofPool(pool: Pool, jobs: BackgroundJobs.State, listener: HttpServer.Listener,
                   startedAt: Int64, jobsOn: Bool, heal: Option[SelfHeal.Watch]): Health[{IO, Log}] =
        { checkDb     = _ -> ping(pool),
          jobsSummary = _ -> BackgroundJobs.summary(pool, jobs),
          runJobs     = _ -> BackgroundJobs.tick(pool, jobs),
          connections = _ -> HttpServer.connections(listener),
          poolStats   = _ -> Pool.stats(pool),
          stall       = _ -> stalled(liveness(jobs, startedAt, jobsOn)),
          heal        = _ -> BackgroundJobs.healCheck(pool, jobs, heal) }

    /// 今の周の生死を読む。
    def liveness(jobs: BackgroundJobs.State, startedAt: Int64, jobsOn: Bool): Liveness \ IO =
        { now = System.currentTimeMillis(), startedAt = startedAt, jobsOn = jobsOn,
          jobsIntervalMs = BackgroundJobs.intervalMs(), lastTickAt = Ref.get(jobs#lastTick),
          watchIntervalMs = BackgroundJobs.healIntervalMs(), lastWatchAt = Ref.get(jobs#lastWatch) }

    ///
    /// プールから接続を 1 本借りて SELECT 1 を投げる。借りられない・届かないは理由付きの Err。
    ///
    pub def ping(pool: Pool): Result[String, Unit] \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withConnection(pool, _ -> discard Sql.fetch("SELECT 1", Nil))))
            |> Result.mapErr(failure -> "${failure}")

}
