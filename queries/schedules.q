// schedules.q: 予約公開

query insertSchedule(id: String, projectId: Int64, entryId: String, action: String, runAt: Timestamp, withDependencies: Bool, requestedBy: String) -> exec {
    INSERT INTO scheduled_actions (id, project_id, entry_id, action, run_at, with_dependencies, requested_by)
    VALUES (:id, :projectId, :entryId, :action, :runAt, :withDependencies, :requestedBy)
}

// 同じ entry の同じ操作の未実行の予約を取り消す（予約し直しは置き換え）
query cancelPendingFor(projectId: Int64, entryId: String, action: String) -> exec {
    UPDATE scheduled_actions SET status = 'cancelled' WHERE project_id = :projectId AND entry_id = :entryId AND action = :action AND status = 'pending'
}

query cancelSchedule(id: String, projectId: Int64) -> exec {
    UPDATE scheduled_actions SET status = 'cancelled' WHERE id = :id AND project_id = :projectId AND status = 'pending'
}

query findSchedule(id: String, projectId: Int64) -> one {
    SELECT id, entry_id, action, run_at, with_dependencies, status, requested_by, last_error, created_at, done_at
    FROM scheduled_actions WHERE id = :id AND project_id = :projectId
}

query listSchedules(projectId: Int64, limit: Int64) -> many {
    SELECT id, entry_id, action, run_at, with_dependencies, status, requested_by, last_error, created_at, done_at
    FROM scheduled_actions WHERE project_id = :projectId ORDER BY id DESC LIMIT :limit
}

query listSchedulesOfEntry(projectId: Int64, entryId: String, limit: Int64) -> many {
    SELECT id, entry_id, action, run_at, with_dependencies, status, requested_by, last_error, created_at, done_at
    FROM scheduled_actions WHERE project_id = :projectId AND entry_id = :entryId ORDER BY id DESC LIMIT :limit
}

// unscoped: Scheduler はプロジェクトを跨いで時刻の来た物を拾い、1 件ずつそのプロジェクトの印で実行する（SKIP LOCKED で二重に拾わない）
query claimDueSchedules(limit: Int64) -> many {
    UPDATE scheduled_actions SET status = 'running', claimed_at = now()
    WHERE id IN (
        SELECT id FROM scheduled_actions WHERE status = 'pending' AND run_at <= now()
        ORDER BY run_at LIMIT :limit FOR UPDATE SKIP LOCKED
    )
    RETURNING id, project_id, entry_id, action, with_dependencies
}

// unscoped: 実行中に落ちた行の回復。拾ってから staleMinutes 分たっても終わっていなければ pending に戻す（公開は冪等なので再実行してよい）
query recoverStuckSchedules(staleMinutes: Int64) -> exec {
    UPDATE scheduled_actions SET status = 'pending'
    WHERE status = 'running' AND claimed_at < now() - make_interval(mins => :staleMinutes::int)
}

// unscoped: 古い記録の掃除
query purgeOldSchedules(keepDays: Int64) -> exec {
    DELETE FROM scheduled_actions WHERE status IN ('done', 'failed', 'cancelled') AND created_at < now() - make_interval(days => :keepDays::int)
}

// unscoped: /health の件数
query countSchedules() -> one {
    SELECT count(*) FILTER (WHERE status = 'pending')::bigint AS pending, count(*) FILTER (WHERE status = 'failed')::bigint AS failed FROM scheduled_actions
}

query markScheduleDone(id: String, projectId: Int64) -> exec {
    UPDATE scheduled_actions SET status = 'done', done_at = now() WHERE id = :id AND project_id = :projectId
}

query markScheduleFailed(id: String, projectId: Int64, lastError: String) -> exec {
    UPDATE scheduled_actions SET status = 'failed', done_at = now(), last_error = :lastError WHERE id = :id AND project_id = :projectId
}
