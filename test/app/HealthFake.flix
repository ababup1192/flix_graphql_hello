///
/// Health の偽の値。DB を使わずに Server を確かめる。
///
mod HealthFake {

    /// まだ 1 度も回っておらず、仕事も無い。
    pub def idle(): BackgroundJobs.Summary =
        { lastTickAt = None, pendingSchedules = 0i64, failedSchedules = 0i64, pendingDeliveries = 0i64, failedDeliveries = 0i64 }

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
          stall = _ -> None, heal = _ -> () }

    ///
    /// checkDb が常に message の Err を返す。
    ///
    pub def failing(message: String): Health[{}] =
        { checkDb = _ -> Err(message) | ok() }

    ///
    /// DB には届くが、仕事の tick が止まっている。
    ///
    pub def stalled(): Health[{}] =
        { stall = _ -> Some(Health.Stall.Jobs(120000i64)) | ok() }

}
