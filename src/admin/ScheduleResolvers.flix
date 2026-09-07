///
/// 管理 API の Schedule（予約公開）のリゾルバ。
///
mod ScheduleResolvers {

    /// type Schedule のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ScheduleResolvers[AdminEff] =
        {
            id               = (_context, source) -> Ok(AdminMapping.idOfUlid(source#id)),
            entryId          = (_context, source) -> Ok(AdminMapping.idOfEntry(source#entryId)),
            action           = (_context, source) -> Ok(AdminMapping.scheduleActionToGql(source#action)),
            runAt            = (_context, source) -> Ok(Timestamp.toIso8601(source#runAt)),
            withDependencies = (_context, source) -> Ok(source#withDependencies),
            status           = (_context, source) -> Ok(AdminMapping.scheduleStatusToGql(source#status)),
            requestedBy      = (_context, source) -> Ok(source#requestedBy),
            lastError        = (_context, source) -> Ok(source#lastError),
            overdue          = (_context, source) -> Ok(isOverdue(source)),
            createdAt        = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            doneAt           = (_context, source) -> Ok(source#doneAt |> Option.map(Timestamp.toIso8601))
        }


    ///
    /// 未実行で、時刻が既に過ぎている。
    ///
    /// WhyNot: リゾルバのラムダの中に直に書かないのは、Flix 0.75.3 が Clock を呼ぶ比較を含むラムダで JVM の VerifyError を出すため
    /// （GraphQL 越しでだけ起きる。関数に分ければ通る）。
    ///
    def isOverdue(schedule: Schedule): Bool \ Time.Clock.Clock =
        let now = Time.Clock.now();
        let pending = schedule#status == ScheduleStatus.Pending;
        pending and Timestamp.toEpochMillis(schedule#runAt) <= now

}
