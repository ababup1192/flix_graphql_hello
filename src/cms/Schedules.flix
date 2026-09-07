///
/// 予約公開。時刻を指定した publish / unpublish を積む。実行は app の Scheduler。
///
mod Schedules {

    ///
    /// 予約する。publishEntries を持つ人だけ。同じ entry の同じ操作の未実行の予約は置き換える。
    ///
    pub def schedule(entryId: EntryId, action: ScheduleAction, runAt: Timestamp.Timestamp, withDependencies: Bool): Schedule \ Db + CmsErr + IdGen + Tenant + Session =
        Session.require(Permission.PublishEntries);
        discard ContentEntries.get(entryId);
        discard SchedulesQueries.cancelPendingFor({ projectId = Tenant.currentId(), entryId = EntryId.text(entryId), action = ScheduleAction.text(action) });
        let id = IdGen.freshUlid();
        discard SchedulesQueries.insertSchedule({
            id = id, projectId = Tenant.currentId(), entryId = EntryId.text(entryId), action = ScheduleAction.text(action),
            runAt = runAt, withDependencies = withDependencies, requestedBy = Session.displayName() });
        find(id)

    ///
    /// 取り消す。未実行の物だけ。
    ///
    pub def cancel(id: String): Schedule \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.PublishEntries);
        let changed = SchedulesQueries.cancelSchedule({ id = id, projectId = Tenant.currentId() });
        if (changed == 0) CmsErr.notFound(Entity.Schedule, id) else find(id)

    ///
    /// 今のプロジェクトの予約。新しい順。entryId を渡せばその entry の物だけ。
    ///
    pub def list(entryId: Option[EntryId], first: Int32): List[Schedule] \ DbRead + DbErr + CmsErr + Tenant + Session =
        Session.require(Permission.ReadDraft);
        let limit = Int32.toInt64(Int32.max(1, Int32.min(200, first)));
        match entryId {
            case Some(id) => SchedulesQueries.listSchedulesOfEntry({ projectId = Tenant.currentId(), entryId = EntryId.text(id), limit = limit }) |> List.map(fromRow)
            case None     => SchedulesQueries.listSchedules({ projectId = Tenant.currentId(), limit = limit }) |> List.map(fromRow)
        }

    def find(id: String): Schedule \ DbRead + DbErr + CmsErr + Tenant =
        SchedulesQueries.findSchedule({ id = id, projectId = Tenant.currentId() }) |> Option.map(fromRow) |> CmsErr.orNotFound(Entity.Schedule, id)

    pub def fromRow(row: { id = String, entryId = String, action = String, runAt = Timestamp.Timestamp, withDependencies = Bool, status = String, requestedBy = String, lastError = String, createdAt = Timestamp.Timestamp, doneAt = Option[Timestamp.Timestamp] | r }): Schedule \ DbErr =
        { id = row#id,
          entryId = EntryId.parse(row#entryId) |> Rows.orRaise("scheduled_actions.entry_id", row#entryId),
          action = ScheduleAction.parse(row#action) |> Rows.orRaise("scheduled_actions.action", row#action),
          runAt = row#runAt, withDependencies = row#withDependencies,
          status = ScheduleStatus.parse(row#status) |> Rows.orRaise("scheduled_actions.status", row#status),
          requestedBy = row#requestedBy, lastError = row#lastError, createdAt = row#createdAt, doneAt = row#doneAt }

}
