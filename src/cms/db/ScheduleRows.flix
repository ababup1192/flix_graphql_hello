///
/// scheduled_actions の行とドメインの値の変換。列名を知るのはここだけ。
///
mod ScheduleRows {

    pub def toSchedule(row: { id = String, entryId = String, action = String, runAt = Timestamp.Timestamp, withDependencies = Bool, status = String, requestedBy = String, lastError = String, createdAt = Timestamp.Timestamp, doneAt = Option[Timestamp.Timestamp] | r }): Schedule \ DbErr =
        { id = row#id,
          entryId = EntryId.parse(row#entryId) |> Rows.orRaise("scheduled_actions.entry_id", row#entryId),
          action = ScheduleAction.parse(row#action) |> Rows.orRaise("scheduled_actions.action", row#action),
          runAt = row#runAt, withDependencies = row#withDependencies,
          status = ScheduleStatus.parse(row#status) |> Rows.orRaise("scheduled_actions.status", row#status),
          requestedBy = row#requestedBy, lastError = row#lastError, createdAt = row#createdAt, doneAt = row#doneAt }

}
