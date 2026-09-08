///
/// 時刻の来た予約（scheduled_actions）を拾い、そのプロジェクトの印と System の認証済みユーザーで publish / unpublish を実行する。
/// 実行は既存のユースケースをそのまま呼ぶので、公開の検査も Webhook の積み込みも通常の公開と同じ。
///
mod Scheduler {

    def batchSize(): Int64 = 20i64

    ///
    /// 時刻の来た予約を拾って実行する。実行した数を返す。業務エラーは failed に理由を書き、次へ進む。
    ///
    pub def tick(pool: Pool): Result[String, Int32] \ {IO, Log} =
        // 時刻の来た予約を 1 つの Tx で拾う（プロジェクトを跨ぐので RLS の印は無し。SKIP LOCKED で他の台と重ならない）
        DbRunner.withTx(pool, None, () -> SchedulesQueries.claimDueSchedules(batchSize()))
            |> Result.mapErr(failure -> "予約を拾えません: ${failure}")
            // 1 件ずつ実行して結果を書く。DB の失敗が出た所で止まる
            |> Result.flatMap(claimed -> Result.traverse(runOne(pool), claimed) |> Result.map(List.length))

    ///
    /// 予約 1 件の実行の結果。外の Err は DB の失敗（tick を止める）、内の Err は failed に書く理由（文言とログの属性）。
    ///
    type alias ActionOutcome = Result[DbError.DbFailure, Result[(String, Log.Fields), Unit]]

    ///
    /// 1 件実行して結果を書く。
    ///
    def runOne(pool: Pool, claimed: { id = String, projectId = Int64, projectSlug = String, entryId = String, action = String, withDependencies = Bool }): Result[String, Unit] \ {IO, Log} =
        let projectId = ProjectId.ProjectId(claimed#projectId);
        let labels = Log.Fields.empty() |> Log.Fields.str("project", claimed#projectSlug) |> Log.Fields.str("id", claimed#entryId);
        // 行の文字列を entry id と操作に読み、読めた物だけ実行する
        let outcome = match (EntryId.parse(claimed#entryId), ScheduleAction.parse(claimed#action)) {
            case (Some(entryId), Some(action)) => runAction(pool, projectId, entryId, action, claimed#withDependencies)
            // 知らない操作や壊れた id は failed にして先へ進む（新しい版が積んだ物を古い版が拾った時など）
            case _ => Ok(Err(("知らない予約です: ${claimed#action} ${claimed#entryId}", Log.Fields.empty())))
        };
        // 仕事の行を出し、done / failed を別の Tx で書く
        match outcome {
            case Err(failure)     => Err("予約を実行できません: ${failure}")
            case Ok(Ok(()))       => { JobLog.write({ kind = JobLog.JobKind.Schedule, id = claimed#id, outcome = JobLog.JobOutcome.Done, detail = "${claimed#action} ${claimed#entryId}" }, labels); record(pool, projectId, () -> discard SchedulesQueries.markScheduleDone({ id = claimed#id, projectId = claimed#projectId })) }
            case Ok(Err((message, fields))) => { JobLog.write({ kind = JobLog.JobKind.Schedule, id = claimed#id, outcome = JobLog.JobOutcome.Failed, detail = message }, labels |> Log.Fields.merge(fields)); record(pool, projectId, () -> discard SchedulesQueries.markScheduleFailed({ id = claimed#id, projectId = claimed#projectId, lastError = message })) }
        }

    ///
    /// そのプロジェクトの RLS の印を置き、System の認証済みユーザーで開いた Tx で publish / unpublish を実行する。
    /// 業務エラーは failed に書く理由にし、DB の失敗はそのまま返す。
    ///
    def runAction(pool: Pool, projectId: ProjectId, entryId: EntryId, action: ScheduleAction, withDependencies: Bool): ActionOutcome \ {IO, Log} =
        match Tenant.runWith(projectId, () -> IdGen.runWithRandom(() ->
            DbRunner.transact(pool, Some(projectId), Actor.System, () -> match action {
                case ScheduleAction.Publish   => discard ContentEntries.publish(Session.grant(), entryId, "scheduler", withDependencies)
                case ScheduleAction.Unpublish => discard ContentEntries.unpublish(Session.grant(), entryId)
            }))) {
            case Ok(())                                          => Ok(Ok(()))
            case Err(ApplicationFailure.Domain(failure))         => Ok(Err((CmsErr.toMessage(failure), Log.Fields.empty() |> LogFields.failure(failure))))
            case Err(ApplicationFailure.Infrastructure(failure)) => Err(failure)
        }

    def record(pool: Pool, projectId: ProjectId, write: Unit -> Unit \ DbWrite): Result[String, Unit] \ IO =
        DbRunner.withTx(pool, Some(projectId), write) |> Result.mapErr(failure -> "予約の結果を書けません: ${failure}")

}
