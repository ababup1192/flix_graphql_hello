///
/// ScheduleRows: scheduled_actions の行とドメインの Schedule の往復。純粋（DbErr は Result に落として見る）。
///
/// 観点:
/// - 往復: ScheduleAction × ScheduleStatus の全組、doneAt の None / Some、ULID と entry id はそのまま
/// - 境界: 規則外の entry id、知らない action / status は DbErr
///
mod TestScheduleRows {

    def at(millis: Int64): Timestamp.Timestamp = Timestamp.fromEpochMillis(millis)

    def ulid(): String = "01ARYZ6S41TSV4RRFFQ69G5FAV"

    def row(action: String, status: String, doneAt: Option[Timestamp.Timestamp]): { id = String, entryId = String, action = String, runAt = Timestamp.Timestamp, withDependencies = Bool, status = String, requestedBy = String, lastError = String, createdAt = Timestamp.Timestamp, doneAt = Option[Timestamp.Timestamp] } =
        { id = ulid(), entryId = "post-01_A", action = action, runAt = at(1725000000123i64), withDependencies = true, status = status,
          requestedBy = "山田", lastError = "参照先が未公開", createdAt = at(1725000000001i64), doneAt = doneAt }

    /// action × status の全組で往復し、doneAt の None / Some と他の列はそのまま。
    @Test
    def testScheduleRoundTrip(): Unit \ Assert =
        let actions = List#{ScheduleAction.Publish, ScheduleAction.Unpublish};
        let statuses = List#{ScheduleStatus.Pending, ScheduleStatus.Running, ScheduleStatus.Done, ScheduleStatus.Failed, ScheduleStatus.Cancelled};
        let table = actions |> List.flatMap(action -> statuses |> List.map(status -> (action, status, if (status == ScheduleStatus.Done) Some(at(1725000000999i64)) else None)));
        Assert.assertEq(expected = table |> List.map(match (action, status, doneAt) -> Ok((ulid(), CmsTestKit.entryId("post-01_A"), action, at(1725000000123i64), true, status, "山田", "参照先が未公開", at(1725000000001i64), doneAt))),
            table |> List.map(match (action, status, doneAt) -> DbErr.runWithResult(() -> {
                let found = ScheduleRows.toSchedule(row(ScheduleAction.text(action), ScheduleStatus.text(status), doneAt));
                (found#id, found#entryId, found#action, found#runAt, found#withDependencies, found#status, found#requestedBy, found#lastError, found#createdAt, found#doneAt)
            })))

    /// 規則外の entry id、知らない action、知らない status は DbErr。
    @Test
    def testToScheduleRejects(): Unit \ Assert =
        let table = List#{
            { entryId = "post 01" | row("publish", "pending", None) },
            row("archive", "pending", None),
            row("publish", "queued", None)
        };
        Assert.assertEq(expected = List.repeat(List.length(table), true),
            table |> List.map(found -> DbErr.runWithResult(() -> ScheduleRows.toSchedule(found)) |> Result.isErr))

}
