// audit.q: 監査の記録。積むのと読むのだけ（更新も削除もしない。append-only）

query insertAuditEvent(id: String, projectId: Int64, actorKind: String, actorId: String, actor: String, action: String, targetKind: String, targetId: String, detail: Json) -> exec {
    INSERT INTO audit_events (id, project_id, actor_kind, actor_id, actor, action, target_kind, target_id, detail)
    VALUES (:id, :projectId, :actorKind, :actorId, :actor, :action, :targetKind, :targetId, :detail)
}

// 新しい順。id が ULID なので id の降順で時刻順になる。絞り込みは全部任意（NULL なら効かない）。
// afterId より古い物、actorKind、action の前方一致、時刻の範囲（sinceId 以上 untilId 未満。ULID の下限に変換した物）
query listAuditEvents(projectId: Int64, afterId: Option[String], actorKind: Option[String], actionPrefix: Option[String], sinceId: Option[String], untilId: Option[String], max: Int64) -> many {
    SELECT id, actor_kind, actor_id, actor, action, target_kind, target_id, detail, created_at
    FROM audit_events
    WHERE project_id = :projectId
      AND (:afterId IS NULL OR id < :afterId)
      AND (:actorKind IS NULL OR actor_kind = :actorKind)
      AND (:actionPrefix IS NULL OR action LIKE :actionPrefix || '%')
      AND (:sinceId IS NULL OR id >= :sinceId)
      AND (:untilId IS NULL OR id < :untilId)
    ORDER BY id DESC LIMIT :max
}
