///
/// 予約公開。時刻を指定した publish / unpublish を積む。実行は app の Scheduler。
///
mod Schedules {

    ///
    /// 予約する。publishEntries の証明を受ける。同じ entry の同じ操作の未実行の予約は置き換える。
    ///
    pub def schedule(proof: Granted[PublishEntries], entryId: EntryId, action: ScheduleAction, runAt: Timestamp.Timestamp, withDependencies: Bool): Schedule \ Db + CmsErr + IdGen + Tenant + Session =
        discard ContentEntries.get(Session.readDraftOfPublisher(proof), entryId);
        discard SchedulesQueries.cancelPendingFor({ projectId = Tenant.currentId(), entryId = EntryId.text(entryId), action = ScheduleAction.text(action) });
        let id = IdGen.freshUlid();
        discard SchedulesQueries.insertSchedule({
            id = id, projectId = Tenant.currentId(), entryId = EntryId.text(entryId), action = ScheduleAction.text(action),
            runAt = runAt, withDependencies = withDependencies, requestedBy = Session.displayName() });
        find(id)

    ///
    /// 取り消す。未実行の物だけ。
    ///
    pub def cancel(_proof: Granted[PublishEntries], id: String): Schedule \ Db + CmsErr + Tenant =
        let changed = SchedulesQueries.cancelSchedule({ id = id, projectId = Tenant.currentId() });
        if (changed == 0) CmsErr.notFound(Entity.Schedule, id) else find(id)

    ///
    /// 今のプロジェクトの予約。新しい順。entryId を渡せばその entry の物だけ。
    ///
    pub def list(_proof: Granted[ReadDraft], entryId: Option[EntryId], first: Int32): List[Schedule] \ DbRead + Tenant =
        let limit = Int32.toInt64(first);
        match entryId {
            case Some(id) => SchedulesQueries.listSchedulesOfEntry({ projectId = Tenant.currentId(), entryId = EntryId.text(id), limit = limit }) |> List.map(ScheduleRows.toSchedule)
            case None     => SchedulesQueries.listSchedules({ projectId = Tenant.currentId(), limit = limit }) |> List.map(ScheduleRows.toSchedule)
        }

    def find(id: String): Schedule \ DbRead + CmsErr + Tenant =
        SchedulesQueries.findSchedule({ id = id, projectId = Tenant.currentId() }) |> Option.map(ScheduleRows.toSchedule) |> CmsErr.orNotFound(Entity.Schedule, id)

}
