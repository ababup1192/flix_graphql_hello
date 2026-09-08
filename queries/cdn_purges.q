// cdn_purges.q: CDN の purge の outbox（tick が積み、dispatcher が送る）

// ---- 積む ----

// unscoped: tick が全プロジェクトを見る。版が進んだプロジェクトを拾い、purged_version を content_version まで進める（同じ Tx で行を積む）
query claimPurgeTargets() -> many {
    UPDATE projects SET purged_version = content_version WHERE content_version > purged_version RETURNING id, content_version
}

query insertPurge(id: String, projectId: Int64, contentVersion: Int64) -> exec {
    INSERT INTO cdn_purges (id, project_id, content_version) VALUES (:id, :projectId, :contentVersion)
}

// ---- 送る ----

// unscoped: dispatcher はプロジェクトを跨いで送る番の物を拾う。複数台でも同じ行を二重に拾わない（SKIP LOCKED）
// 同じプロジェクトの古い物が未完（pending / sending）なら拾わない。プロジェクト slug はログの行（project）に出す
query claimDuePurges(limit: Int64) -> many {
    UPDATE cdn_purges AS c SET status = 'sending', attempts = attempts + 1, claimed_at = now()
    FROM projects AS p
    WHERE p.id = c.project_id AND c.id IN (
        SELECT d.id FROM cdn_purges AS d
        WHERE d.status = 'pending' AND d.next_attempt_at <= now()
          AND NOT EXISTS (
              SELECT 1 FROM cdn_purges AS e
              WHERE e.project_id = d.project_id AND e.id < d.id AND e.status IN ('pending', 'sending')
          )
        ORDER BY d.id LIMIT :limit FOR UPDATE OF d SKIP LOCKED
    )
    RETURNING c.id, c.project_id, p.slug AS project_slug, c.content_version, c.attempts
}

query markPurgeDelivered(id: String, projectId: Int64, lastStatus: Int32) -> exec {
    UPDATE cdn_purges SET status = 'delivered', delivered_at = now(), last_status = :lastStatus, last_error = ''
    WHERE id = :id AND project_id = :projectId
}

query markPurgeRetry(id: String, projectId: Int64, delaySeconds: Int64, lastStatus: Int32, lastError: String) -> exec {
    UPDATE cdn_purges SET status = 'pending', next_attempt_at = now() + make_interval(secs => :delaySeconds), last_status = :lastStatus, last_error = :lastError
    WHERE id = :id AND project_id = :projectId
}

query markPurgeFailed(id: String, projectId: Int64, lastStatus: Int32, lastError: String) -> exec {
    UPDATE cdn_purges SET status = 'failed', last_status = :lastStatus, last_error = :lastError
    WHERE id = :id AND project_id = :projectId
}

// ---- 回復と掃除 ----

// unscoped: 送っている最中に落ちた行の回復（purge は何度送っても同じなので二重は問題にならない）
query recoverStuckPurges(staleMinutes: Int64) -> exec {
    UPDATE cdn_purges SET status = 'pending', next_attempt_at = now()
    WHERE status = 'sending' AND claimed_at < now() - make_interval(mins => :staleMinutes::int)
}

// unscoped: 古い記録の掃除
query purgeOldPurges(keepDays: Int64) -> exec {
    DELETE FROM cdn_purges WHERE status IN ('delivered', 'failed') AND created_at < now() - make_interval(days => :keepDays::int)
}

// ---- 読む（テストと管理用）----

query listPurges(projectId: Int64) -> many {
    SELECT id, content_version, status, attempts, last_status, last_error FROM cdn_purges WHERE project_id = :projectId ORDER BY id
}
