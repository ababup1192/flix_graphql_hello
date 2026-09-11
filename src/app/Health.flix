///
/// 死活監視と、バックグラウンドワーカーへの問い合わせ。GET /health と POST /jobs/tick が使う。
/// 本番は ofPool（プール・ワーカー・Listener を閉じ込める）、テストは固定の答えを返す値を入れる。
///
/// - checkDb: DB に届くか。届かなければ理由を Err に入れる
/// - jobsSummary: バックグラウンドワーカーのまとめ（最終実行時刻と待ち・失敗の件数）。checkDb の結果を渡し、届いていない時は件数を数えない（-1）
/// - runJobs: 外部トリガーから 1 tick回す。失敗した所の説明（空なら全部通った）
/// - connections: HTTP の同時接続の今の数と上限
/// - poolStats: DB の接続プールの数字（HTTP の接続数とは別）
/// - liveness: tickの生死を読むための値（止まっているかは Health.stalled、行ごとの段は Health.componentLevels が出す）
/// - heal: checkDb の結果を渡して自己回復の判断を 1 回進める（Exit が決まればこの中でプロセスが終わる）
/// - now: 今の時刻（epoch ミリ秒）。監査の書き出しのファイル名の日付に使う
///
/// WhyNot: effect にしないのは、入力（プール・ワーカー・Listener）が起動時に固定で、読む所が Server の直下なので
/// 値で渡しても引数が 1 本しか増えないため。差し替えには当たるが、IdGen / ObjectStore のように深い所で使う物ではない。
/// ログを持たないのは、それは Log の effect で Route に付くため。
///
pub type alias Health[ef: Eff] = {
    checkDb     = Unit -> Result[String, Unit] \ ef,
    jobsSummary = Result[String, Unit] -> BackgroundJobs.Summary \ ef,
    runJobs     = Unit -> List[String] \ ef,
    connections = Unit -> HttpServer.Connections \ ef,
    poolStats   = Unit -> Pool.PoolStats \ ef,
    liveness    = Unit -> Health.Liveness \ ef,
    heal        = Result[String, Unit] -> Unit \ ef,
    now         = Unit -> Int64 \ ef
}

mod Health {

    import java.lang.System

    ///
    /// 止まっているtick。持っている値は、最後に回ってからの経過（ミリ秒）。
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
    /// tickが生きているかを見るための値。
    ///
    /// - now: 今（UNIX ミリ秒）
    /// - startedAt: プロセスが起動した時刻。まだ 1 度も回っていないtickはここからの経過で見る
    /// - jobsOn: プロセス内のワーカーを回す設定か（CMS_JOBS）
    /// - jobsIntervalMs / watchIntervalMs: それぞれのtickの間隔
    /// - lastTickAt / lastWatchAt: それぞれのtickが最後に回った時刻
    /// - purgeOn: CDN の purge の送り先があるか（無ければ purge の行を出さない）
    /// - lastScheduleAt / lastWebhookAt / lastPurgeAt: tickの部分ごとに、最後に失敗せずに通った時刻
    ///
    pub type alias Liveness = {
        now = Int64, startedAt = Int64, jobsOn = Bool,
        jobsIntervalMs = Int64, lastTickAt = Option[Int64],
        watchIntervalMs = Int64, lastWatchAt = Option[Int64],
        purgeOn = Bool,
        lastScheduleAt = Option[Int64], lastWebhookAt = Option[Int64], lastPurgeAt = Option[Int64]
    }

    ///
    /// 止まっているtickがあれば返す。仕事のtickを先に見る。CMS_JOBS=off の時は仕事のtickを見ない。
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
    /// tickが止まったと見なすまでの長さ（ミリ秒）。間隔の 3 倍。ただし 30 秒は待つ。
    ///
    /// WhyNot: 間隔の 3 倍だけにしないのは、既定の 2 秒では上限が 6 秒になり、DB が遅い時の 1 tick（借り待ちの再試行で 10 秒級）で
    /// 止まっていないtickまで 503 になるため。実験 3 回目で見えた停止は 3 分続いていて、30 秒でも十分に捕まる。
    ///
    pub def stallLimitMs(intervalMs: Int64): Int64 =
        Int64.max(intervalMs * 3i64, 30000i64)

    ///
    /// プールが張り付いたと見なす、使用中の割合（パーセント）。
    ///
    pub def saturationLimitPercent(): Int32 = 90

    ///
    /// DB の接続プールが張り付いていれば、使用中の割合（パーセント）。max が 0（まだプールができていない）なら見ない。
    ///
    /// WhyNot: checkDb だけで足りないのは、接続が漏れて active が max の近くに居座っても、idle が 1 本でも残っていれば
    /// ping は通り、status が ok の 200 のままになるため（漏れの実例は active=9 / idle=1）。
    ///
    /// WhyNot: ここで接続を借りて確かめないのは、DB が止まっている間に /health 自体が借り待ちで返らなくなるため。
    /// Pool.stats は Hikari が持っている数字を読むだけで、待ちが増えない。
    ///
    pub def saturation(stats: Pool.PoolStats): Option[Int32] =
        if (stats#max <= 0) None
        else {
            let percent = stats#active * 100 / stats#max;
            if (percent >= saturationLimitPercent()) Some(percent) else None
        }

    /// /health の本文の reason に出す語。
    pub def saturationReason(percent: Int32): String = "pool saturated (${percent}%)"

    /// リクエストの行に積むキー。
    pub def saturationKey(): String = "pool.used_percent"

    ///
    /// 行ごとの段。ステータスページの色に写す（Statuspage の 4 段と同じ並び）。
    ///
    pub enum Level with Eq, ToString {
        case Operational
        case Degraded
        case PartialOutage
        case MajorOutage
    }

    /// /health の JSON に出す語。
    pub def levelJson(level: Level): String = match level {
        case Level.Operational   => "operational"
        case Level.Degraded      => "degraded"
        case Level.PartialOutage => "partial_outage"
        case Level.MajorOutage   => "major_outage"
    }

    /// DB に届かない時に全行に付ける理由。
    pub def unreachableReason(): String = "db unreachable"

    ///
    /// 行ごとの段と理由。DB に届かなければ全行が major_outage、部分の最終成功時刻が上限より古ければその行だけ partial_outage、
    /// 期限を過ぎた仕事が残っていれば degraded。仕事を回さないプロセス（CMS_JOBS=off）と送り先の無い purge は行を出さない。
    ///
    /// WhyNot: コンテンツ / 管理 / Account を 3 行に割らないのは、同じプロセスの同じ DB の上で、内側から見える壊れ方が
    /// 3 つに同時に効くため。割っても必ず同じ色になる。3 行の差は外形（実際にその経路を叩く）でしか出ない。
    ///
    /// WhyNot: この段を稼働率の根拠にしないのは、ここで見ているのが「プロセスと DB が生きている」だけで、
    /// リゾルバが壊れて 200 のまま誤答する形を拾えないため。稼働率は外形の実応答で塗る。
    ///
    pub def componentLevels(live: Liveness, summary: BackgroundJobs.Summary, dbOk: Bool, saturation: Option[Int32]): List[(String, Level, Option[String])] =
        let api =
            if (not dbOk) ("api", Level.MajorOutage, Some(unreachableReason()))
            else match saturation {
                case Some(percent) => ("api", Level.Degraded, Some(saturationReason(percent)))
                case None          => ("api", Level.Operational, None)
            };
        let jobs =
            if (not live#jobsOn) Nil
            else {
                let purge = if (live#purgeOn) partLevel(live, "cdnPurge", live#lastPurgeAt, 0i64, dbOk) :: Nil else Nil;
                partLevel(live, "schedule", live#lastScheduleAt, summary#overdueSchedules, dbOk) ::
                partLevel(live, "webhook", live#lastWebhookAt, summary#overdueDeliveries, dbOk) :: purge
            };
        api :: jobs

    /// tickの 1 部分の段。止まっている（時刻が古い）が先で、捌けていない（overdue）が次。
    def partLevel(live: Liveness, name: String, lastAt: Option[Int64], overdue: Int64, dbOk: Bool): (String, Level, Option[String]) =
        if (not dbOk) (name, Level.MajorOutage, Some(unreachableReason()))
        else match elapsedOver(live, live#jobsIntervalMs, lastAt) {
            case Some(_) => (name, Level.PartialOutage, Some("${name} stalled"))
            case None    =>
                if (overdue > 0i64) (name, Level.Degraded, Some("${name} behind (${overdue})"))
                else (name, Level.Operational, None)
        }

    ///
    /// プールとワーカーと Listener の状態で答える。runJobs は仕事の行（Log）を出す。
    /// startedAt はプロセスが起動した時刻、jobsOn は CMS_JOBS、heal は自己回復のwatch（CMS_SELF_HEAL=off なら None）、
    /// borrowTimeoutMs は checkDb が接続を借りるのを待つ上限（CMS_DB_BORROW_TIMEOUT_SECONDS）。
    ///
    /// WhyNot: checkDb にプールの borrowTimeoutMs をそのまま使わせないのは、Hikari の借り待ちは満杯の時に他のリクエストの
    /// 列に並ぶ形で、DB が止まっている間は /health がプールの設定ぶん張り付き、Docker の HEALTHCHECK の方が先に切れるため。
    /// この呼び出しだけの上限で切る。
    ///
    pub def ofPool(pool: Pool, jobs: BackgroundJobs.State, listener: HttpServer.Listener,
                   startedAt: Int64, jobsOn: Bool, heal: Option[SelfHeal.Watch], borrowTimeoutMs: Int32): Health[{IO, Log}] =
        { checkDb     = _ -> pingWithin(pool, borrowTimeoutMs),
          jobsSummary = db -> BackgroundJobs.summary(pool, jobs, Result.isOk(db)),
          runJobs     = _ -> BackgroundJobs.tick(pool, jobs),
          connections = _ -> HttpServer.connections(listener),
          poolStats   = _ -> Pool.stats(pool),
          liveness    = _ -> liveness(jobs, startedAt, jobsOn),
          heal        = db -> BackgroundJobs.healCheck(pool, jobs, heal, Result.isOk(db)),
          now         = _ -> System.currentTimeMillis() }

    /// 今のtickの生死を読む。
    def liveness(jobs: BackgroundJobs.State, startedAt: Int64, jobsOn: Bool): Liveness \ IO =
        { now = System.currentTimeMillis(), startedAt = startedAt, jobsOn = jobsOn,
          jobsIntervalMs = BackgroundJobs.intervalMs(), lastTickAt = Ref.get(jobs#lastTick),
          watchIntervalMs = BackgroundJobs.healIntervalMs(), lastWatchAt = Ref.get(jobs#lastWatch),
          purgeOn = Option.nonEmpty(jobs#purge),
          lastScheduleAt = Ref.get(jobs#lastSchedule), lastWebhookAt = Ref.get(jobs#lastWebhook), lastPurgeAt = Ref.get(jobs#lastPurge) }

    ///
    /// プールから接続を 1 本借りて SELECT 1 を投げる。借りられない・届かないは理由付きの Err。
    ///
    pub def ping(pool: Pool): Result[String, Unit] \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withConnection(pool, _ -> discard Sql.fetch("SELECT 1", Nil))))
            |> Result.mapErr(DbError.describeFailure)

    ///
    /// `ping` に、この呼び出しだけの借り待ちの上限を付けた形。上限までに借りられなければ `timeout` の Err。
    /// /health が使う（起動時の確認と自己回復のwatchは `ping`）。
    ///
    pub def pingWithin(pool: Pool, borrowTimeoutMs: Int32): Result[String, Unit] \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Pool.withConnectionTimeout(pool, borrowTimeoutMs, _ -> discard Sql.fetch("SELECT 1", Nil))))
            |> Result.mapErr(DbError.describeFailure)

}
