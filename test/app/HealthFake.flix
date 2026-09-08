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

    ///
    /// checkDb が常に Ok を返す。ワーカーは 1 度も回っていない事にし、runJobs は何もせず空を返す。ログは捨て、時計は 0。
    ///
    pub def ok(): Health[{}] =
        { checkDb = _ -> Ok(()), jobsSummary = _ -> idle(), runJobs = _ -> Nil, connections = _ -> busy(), logLine = _ -> (), nowMillis = _ -> 0i64 }

    ///
    /// checkDb が常に message の Err を返す。
    ///
    pub def failing(message: String): Health[{}] =
        { checkDb = _ -> Err(message) | ok() }

}
