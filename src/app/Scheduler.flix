///
/// 時刻の来た予約（scheduled_actions）を拾い、そのプロジェクトの印と System の認証済みユーザーで publish / unpublish を実行する。
/// 実行は既存のユースケースをそのまま呼ぶので、公開の検査も Webhook の積み込みも通常の公開と同じ。
///
/// 1 回の tick はチャンク（既定 100 件）を claim して実行する事を、予算（既定 10 秒）に達するまで繰り返す。
/// claim がチャンクに満たなければ時刻の来た予約は尽きているので終わる。予算に達したら残りは次の tick（か他の台）に譲る。
///
mod Scheduler {

    import java.lang.System

    ///
    /// tick の設定。CMS_SCHEDULER_CHUNK_SIZE / CMS_SCHEDULER_TICK_BUDGET_SECONDS。
    ///
    /// - chunkSize: 1 回の claim で拾う件数
    /// - budgetMs: 1 回の tick で claim を繰り返す上限（ミリ秒）。直前のチャンクの終わりでこれに達していたら拾わない
    ///
    pub type alias Config = { chunkSize = Int64, budgetMs = Int64 }

    /// CMS_SCHEDULER_CHUNK_SIZE の既定。
    pub def defaultChunkSize(): Int64 = 100i64

    ///
    /// CMS_SCHEDULER_TICK_BUDGET_SECONDS の既定（秒）。
    ///
    /// WhyNot: 30 秒に寄せないのは、/health の stall の判断（`Health.stallLimitMs`。間隔の 3 倍、ただし 30 秒は待つ）が
    /// 「最後に tick が終わってから」で数えるので、予算 + 最後のチャンクの実行が 30 秒に近付くと止まっていない tick が 503 になるため。
    /// 停止の drain（CMS_JOBS_DRAIN_SECONDS。既定 15）と SIGTERM の待ち（既定 20）も同じ tick を待つ。10 秒ならどれにも収まる。
    ///
    pub def defaultBudgetSeconds(): Int64 = 10i64

    /// 既定の設定（チャンク 100 件、予算 10 秒）。テストと、環境変数を読まない所で使う。
    pub def defaultConfig(): Config = { chunkSize = defaultChunkSize(), budgetMs = defaultBudgetSeconds() * 1000i64 }

    /// 環境変数から設定を読む。
    pub def configFromEnv(): Config \ Sys.Env =
        { chunkSize = chunkSize(Sys.Env.getVar("CMS_SCHEDULER_CHUNK_SIZE")),
          budgetMs  = budgetSeconds(Sys.Env.getVar("CMS_SCHEDULER_TICK_BUDGET_SECONDS")) * 1000i64 }

    /// CMS_SCHEDULER_CHUNK_SIZE の値。無い・数字でない・1 未満なら既定の 100。
    pub def chunkSize(raw: Option[String]): Int64 =
        raw |> Option.flatMap(Int64.fromString) |> Option.filter(count -> count >= 1i64) |> Option.getWithDefault(defaultChunkSize())

    /// CMS_SCHEDULER_TICK_BUDGET_SECONDS の値を秒にする。無い・数字でない・1 未満なら既定の 10。
    pub def budgetSeconds(raw: Option[String]): Int64 =
        raw |> Option.flatMap(Int64.fromString) |> Option.filter(seconds -> seconds >= 1i64) |> Option.getWithDefault(defaultBudgetSeconds())

    ///
    /// 次のチャンクを拾うかの判断に使う値。
    ///
    /// - startedAt / now: tick を始めた時刻と今（UNIX ミリ秒）
    /// - budgetMs: tick の予算（ミリ秒）
    /// - lastChunkSize: 直前の claim で拾えた件数
    /// - chunkSize: 1 回の claim で拾う件数
    ///
    pub type alias Progress = { startedAt = Int64, now = Int64, budgetMs = Int64, lastChunkSize = Int32, chunkSize = Int64 }

    ///
    /// 次のチャンクを拾うか。直前のチャンクが満杯（まだ残っているかもしれない）で、予算にまだ達していない時だけ true。
    ///
    /// WhyNot: 満杯でなくても予算が残っていれば拾いに行く形にしないのは、満杯でない claim は時刻の来た予約が尽きた印で、
    /// もう 1 回引いても 0 件の UPDATE が 1 本増えるだけのため。
    ///
    pub def canClaimMore(progress: Progress): Bool =
        Int32.toInt64(progress#lastChunkSize) == progress#chunkSize and progress#now - progress#startedAt < progress#budgetMs

    ///
    /// 時刻の来た予約を既定の設定で拾って実行する。実行した数を返す。業務エラーは failed に理由を書き、次へ進む。
    ///
    pub def tick(pool: Pool): Result[String, Int32] \ {IO, Log} = tickWith(defaultConfig(), pool)

    ///
    /// 時刻の来た予約をチャンクごとに拾って実行する。予算に達するか、チャンクが満杯でなくなるまで繰り返す。実行した数を返す。
    /// DB の失敗が出た所で止まる（それまでに実行した分は各自の Tx で書けている）。
    ///
    /// WhyNot: チャンクの間で heartbeat（BackgroundJobs の lastTick）を進めないのは、/health の stall の上限が最短でも 30 秒で、
    /// 予算の 10 秒 + 最後のチャンクの実行では届かないため。lastTick は「tick が終わった時刻」の意味を保つ。予算を伸ばすなら上限と一緒に見る。
    ///
    pub def tickWith(config: Config, pool: Pool): Result[String, Int32] \ {IO, Log} =
        claimAndRun(config, pool, System.currentTimeMillis(), 0)

    /// 1 チャンク拾って実行し、続けるなら再帰する。ran はここまでに実行した数。
    def claimAndRun(config: Config, pool: Pool, startedAt: Int64, ran: Int32): Result[String, Int32] \ {IO, Log} =
        // 時刻の来た予約を 1 つの Tx で拾う（プロジェクトを跨ぐので RLS の印は無し。SKIP LOCKED で他の台と重ならない）
        DbRunner.withTx(pool, None, () -> SchedulesQueries.claimDueSchedules(config#chunkSize))
            |> Result.mapErr(failure -> "予約を拾えません: ${failure}")
            // 1 件ずつ実行して結果を書く。DB の失敗が出た所で止まる
            |> Result.flatMap(claimed -> Result.traverse(runOne(pool), claimed) |> Result.map(List.length))
            |> Result.flatMap(count -> {
                let progress = { startedAt = startedAt, now = System.currentTimeMillis(), budgetMs = config#budgetMs, lastChunkSize = count, chunkSize = config#chunkSize };
                if (canClaimMore(progress)) claimAndRun(config, pool, startedAt, ran + count) else Ok(ran + count)
            })

    ///
    /// 予約 1 件の実行の結果。外の Err は DB の失敗（tick を止める）、内の Err は failed に書く理由（文言とログの属性）。
    ///
    type alias ActionOutcome = Result[DbError.DbFailure, Result[(String, Log.Fields), Unit]]

    ///
    /// 1 件実行して結果を書く。
    ///
    def runOne(pool: Pool, claimed: { id = String, projectId = Int64, projectSlug = String, entryId = String, action = String, withDependencies = Bool, runAt = Timestamp.Timestamp }): Result[String, Unit] \ {IO, Log} =
        let projectId = ProjectId.ProjectId(claimed#projectId);
        let labels = Log.Fields.empty() |> Log.Fields.str("project", claimed#projectSlug) |> Log.Fields.str("id", claimed#entryId);
        // 行の文字列を entry id と操作に読み、読めた物だけ実行する
        let outcome = match (EntryId.parse(claimed#entryId), ScheduleAction.parse(claimed#action)) {
            case (Some(entryId), Some(action)) => runAction(pool, projectId, entryId, action, claimed#withDependencies, claimed#runAt)
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
    def runAction(pool: Pool, projectId: ProjectId, entryId: EntryId, action: ScheduleAction, withDependencies: Bool, runAt: Timestamp.Timestamp): ActionOutcome \ {IO, Log} =
        match Tenant.runWith(projectId, () -> IdGen.runWithRandom(() ->
            DbRunner.transact(pool, Some(projectId), Actor.System, () -> match action {
                case ScheduleAction.Publish   => discard ContentEntries.publishScheduled(Session.grant(), entryId, runAt, withDependencies)
                case ScheduleAction.Unpublish => discard ContentEntries.unpublish(Session.grant(), entryId)
            }))) {
            case Ok(())                                          => Ok(Ok(()))
            case Err(ApplicationFailure.Domain(failure))         => Ok(Err((CmsErr.toMessage(failure), Log.Fields.empty() |> LogFields.failure(failure))))
            case Err(ApplicationFailure.Infrastructure(failure)) => Err(failure)
        }

    def record(pool: Pool, projectId: ProjectId, write: Unit -> Unit \ DbWrite): Result[String, Unit] \ IO =
        DbRunner.withTx(pool, Some(projectId), write) |> Result.mapErr(failure -> "予約の結果を書けません: ${failure}")

}
