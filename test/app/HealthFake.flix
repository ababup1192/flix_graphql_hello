///
/// Health の偽の値。DB を使わずに Server を確かめる。
///
mod HealthFake {

    /// まだ 1 度も回っておらず、仕事も無い。
    pub def idle(): BackgroundJobs.Summary =
        { lastTickAt = None, pendingSchedules = 0i64, failedSchedules = 0i64, pendingDeliveries = 0i64, failedDeliveries = 0i64,
          overdueSchedules = 0i64, overdueDeliveries = 0i64 }

    /// tick も部分も直前に回っている。起動は 0 ミリ秒、今は 100 秒、間隔は 2 秒（止まったと見なすのは 30 秒）。
    pub def live(): Health.Liveness =
        { now = 100000i64, startedAt = 0i64, jobsOn = true,
          jobsIntervalMs = 2000i64, lastTickAt = Some(99000i64),
          watchIntervalMs = 2000i64, lastWatchAt = Some(99000i64),
          purgeOn = false, lastScheduleAt = Some(99000i64), lastWebhookAt = Some(99000i64), lastPurgeAt = Some(99000i64) }

    /// 上限 256 のうち 1 本（自分の /health）がつないでいる。
    pub def busy(): HttpServer.Connections =
        { active = 1, max = 256 }

    /// 上限 10 本のうち 1 本を使っていて、待ちは無い。
    pub def pool(): Pool.PoolStats =
        { active = 1, idle = 2, waiting = 0, total = 3, max = 10 }

    ///
    /// checkDb が常に Ok を返す。ワーカーは 1 度も回っていない事にし、runJobs は何もせず空を返す。
    /// tick は止まっておらず、自己回復の判断は何もしない。
    ///
    pub def ok(): Health[{}] =
        { checkDb = _ -> Ok(()), jobsSummary = _ -> idle(), runJobs = _ -> Nil, connections = _ -> busy(), poolStats = _ -> pool(),
          liveness = _ -> live(), heal = _ -> () }

    ///
    /// checkDb が常に message の Err を返す。jobsSummary は checkDb の結果をそのまま受けた印に、届いていなければ件数を -1 にする（本物と同じ形）。
    ///
    pub def failing(message: String): Health[{}] =
        { checkDb = _ -> Err(message), jobsSummary = db -> if (Result.isOk(db)) idle() else BackgroundJobs.summaryOf(None, None) | ok() }

    ///
    /// DB には届くが、仕事の tick が止まっている。
    ///
    pub def stalled(): Health[{}] =
        { liveness = _ -> { lastTickAt = None, lastScheduleAt = None, lastWebhookAt = None, lastPurgeAt = None | live() } | ok() }

    ///
    /// DB には届き tick も動いているが、接続が漏れてプールが張り付いている（10 本のうち 9 本が使われたまま）。
    /// idle が 1 本残っているので ping は通る。
    ///
    pub def saturated(): Health[{}] =
        { poolStats = _ -> { active = 9, idle = 1, waiting = 0, total = 10, max = 10 } | ok() }

}
