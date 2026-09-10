// audit.q: 監査の記録。積むのと読むのだけ（更新も削除もしない。append-only）

query insertAuditEvent(id: String, projectId: Int64, actor: String, action: String, targetKind: String, targetId: String, detail: Json) -> exec {
    INSERT INTO audit_events (id, project_id, actor, action, target_kind, target_id, detail)
    VALUES (:id, :projectId, :actor, :action, :targetKind, :targetId, :detail)
}

// 新しい順。id が ULID なので id の降順で時刻順になる
query listAuditEvents(projectId: Int64, max: Int64) -> many {
    SELECT id, actor, action, target_kind, target_id, detail, created_at
    FROM audit_events WHERE project_id = :projectId ORDER BY id DESC LIMIT :max
}

// after より古い物（id は ULID で時刻順）
query listAuditEventsAfter(projectId: Int64, afterId: String, max: Int64) -> many {
    SELECT id, actor, action, target_kind, target_id, detail, created_at
    FROM audit_events WHERE project_id = :projectId AND id < :afterId ORDER BY id DESC LIMIT :max
}
