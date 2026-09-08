///
/// 時刻の来た予約（scheduled_actions）を拾い、そのプロジェクトの印と System の主体で publish / unpublish を実行する。
/// 実行は既存のユースケースをそのまま呼ぶので、公開の検査も Webhook の積み込みも通常の公開と同じ。
///
mod Scheduler {

    def batchSize(): Int64 = 20i64

    ///
    /// 時刻の来た予約を拾って実行する。実行した数を返す。業務エラーは failed に理由を書き、次へ進む。
    ///
    pub def tick(pool: Pool): Result[String, Int32] \ {IO, Log} =
        DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> SchedulesQueries.claimDueSchedules(batchSize())))
            |> Result.mapErr(failure -> "予約を拾えません: ${failure}")
            |> Result.flatMap(claimed -> Result.traverse(runOne(pool), claimed) |> Result.map(List.length))

    ///
    /// 1 件実行して結果を書く。
    ///
    def runOne(pool: Pool, claimed: { id = String, projectId = Int64, projectSlug = String, entryId = String, action = String, withDependencies = Bool }): Result[String, Unit] \ {IO, Log} =
        let projectId = ProjectId.ProjectId(claimed#projectId);
        let labels = Log.Fields.empty() |> Log.Fields.str("project", claimed#projectSlug) |> Log.Fields.str("id", claimed#entryId);
        let outcome = match (EntryId.parse(claimed#entryId), ScheduleAction.parse(claimed#action)) {
            case (Some(entryId), Some(action)) =>
                Tenant.runWith(projectId, () -> Session.runWith(Actor.System, () -> IdGen.runWithRandom(() ->
                    DbRunner.transact(pool, Some(projectId), () -> match action {
                        case ScheduleAction.Publish   => discard ContentEntries.publish(entryId, "scheduler", claimed#withDependencies)
                        case ScheduleAction.Unpublish => discard ContentEntries.unpublish(entryId)
                    }))))
                    |> Result.map(Result.mapErr(failure -> (CmsErr.toMessage(failure), Log.Fields.empty() |> LogFields.failure(failure))))
            // 知らない操作や壊れた id は failed にして先へ進む（新しい版が積んだ物を古い版が拾った時など）
            case _ => Ok(Err(("知らない予約です: ${claimed#action} ${claimed#entryId}", Log.Fields.empty())))
        };
        match outcome {
            case Err(failure)     => Err("予約を実行できません: ${failure}")
            case Ok(Ok(()))       => { JobLog.write({ kind = JobLog.JobKind.Schedule, id = claimed#id, outcome = JobLog.JobOutcome.Done, detail = "${claimed#action} ${claimed#entryId}" }, labels); record(pool, projectId, () -> discard SchedulesQueries.markScheduleDone({ id = claimed#id, projectId = claimed#projectId })) }
            case Ok(Err((message, fields))) => { JobLog.write({ kind = JobLog.JobKind.Schedule, id = claimed#id, outcome = JobLog.JobOutcome.Failed, detail = message }, labels |> Log.Fields.merge(fields)); record(pool, projectId, () -> discard SchedulesQueries.markScheduleFailed({ id = claimed#id, projectId = claimed#projectId, lastError = message })) }
        }

    def record(pool: Pool, projectId: ProjectId, write: Unit -> Unit \ DbWrite): Result[String, Unit] \ IO =
        DbRunner.retrying(() -> TenantTx.withLazyTx(pool, projectId, write)) |> Result.mapErr(failure -> "予約の結果を書けません: ${failure}")

}
