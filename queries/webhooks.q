// webhooks.q: Webhook の登録と配信の記録

// ---- webhooks ----

query insertWebhook(publicId: String, projectId: Int64, name: String, url: String, secret: String, events: List[String], active: Bool) -> one {
    INSERT INTO webhooks (public_id, project_id, name, url, secret, events, active)
    VALUES (:publicId, :projectId, :name, :url, :secret, :events, :active) RETURNING id
}

query listWebhooks(projectId: Int64) -> many {
    SELECT id, public_id, name, url, events, active, created_at FROM webhooks WHERE project_id = :projectId ORDER BY id
}

query findWebhookByPublicId(publicId: String, projectId: Int64) -> one {
    SELECT id, public_id, name, url, events, active, created_at FROM webhooks WHERE public_id = :publicId AND project_id = :projectId
}

// 配信する時に url と secret を引く
query findWebhookForDelivery(id: Int64, projectId: Int64) -> one {
    SELECT id, url, secret, active FROM webhooks WHERE id = :id AND project_id = :projectId
}

// この出来事を受ける有効な Webhook
query listActiveWebhooksForEvent(projectId: Int64, event: String) -> many {
    SELECT id FROM webhooks WHERE project_id = :projectId AND active AND :event = ANY(events)
}

query updateWebhook(publicId: String, projectId: Int64, name: String, url: String, events: List[String], active: Bool) -> exec {
    UPDATE webhooks SET name = :name, url = :url, events = :events, active = :active WHERE public_id = :publicId AND project_id = :projectId
}

query deleteWebhook(publicId: String, projectId: Int64) -> exec {
    DELETE FROM webhooks WHERE public_id = :publicId AND project_id = :projectId
}

// ---- deliveries ----

query insertDelivery(id: String, projectId: Int64, webhookId: Int64, event: String, payload: Json) -> exec {
    INSERT INTO webhook_deliveries (id, project_id, webhook_id, event, payload) VALUES (:id, :projectId, :webhookId, :event, :payload)
}

query listDeliveries(webhookId: Int64, projectId: Int64, limit: Int64) -> many {
    SELECT id, event, status, attempts, next_attempt_at, last_status, last_error, created_at, delivered_at
    FROM webhook_deliveries WHERE webhook_id = :webhookId AND project_id = :projectId ORDER BY id DESC LIMIT :limit
}

query findDelivery(id: String, projectId: Int64) -> one {
    SELECT id, event, status, attempts, next_attempt_at, last_status, last_error, created_at, delivered_at
    FROM webhook_deliveries WHERE id = :id AND project_id = :projectId
}

// 管理 API からの再送。今すぐ送る番にする
query resetDelivery(id: String, projectId: Int64) -> exec {
    UPDATE webhook_deliveries SET status = 'pending', next_attempt_at = now(), last_error = ''
    WHERE id = :id AND project_id = :projectId AND status <> 'sending'
}

// unscoped: dispatcher はプロジェクトを跨いで送る番の物を拾い、1 件ずつそのプロジェクトの印で送る。複数台でも同じ行を二重に拾わない（SKIP LOCKED）
query claimDueDeliveries(limit: Int64) -> many {
    UPDATE webhook_deliveries SET status = 'sending', attempts = attempts + 1, claimed_at = now()
    WHERE id IN (
        SELECT id FROM webhook_deliveries WHERE status = 'pending' AND next_attempt_at <= now()
        ORDER BY next_attempt_at LIMIT :limit FOR UPDATE SKIP LOCKED
    )
    RETURNING id, project_id, webhook_id, event, payload, attempts
}

// unscoped: 送っている最中に落ちた行の回復。受け手には届いているかもしれないので、受け手は X-Cms-Delivery で重複を見分ける
query recoverStuckDeliveries(staleMinutes: Int64) -> exec {
    UPDATE webhook_deliveries SET status = 'pending', next_attempt_at = now()
    WHERE status = 'sending' AND claimed_at < now() - make_interval(mins => :staleMinutes::int)
}

// unscoped: 古い記録の掃除
query purgeOldDeliveries(keepDays: Int64) -> exec {
    DELETE FROM webhook_deliveries WHERE status IN ('delivered', 'failed') AND created_at < now() - make_interval(days => :keepDays::int)
}

query markDelivered(id: String, projectId: Int64, lastStatus: Int32) -> exec {
    UPDATE webhook_deliveries SET status = 'delivered', delivered_at = now(), last_status = :lastStatus, last_error = ''
    WHERE id = :id AND project_id = :projectId
}

query markRetry(id: String, projectId: Int64, delaySeconds: Int64, lastStatus: Int32, lastError: String) -> exec {
    UPDATE webhook_deliveries SET status = 'pending', next_attempt_at = now() + make_interval(secs => :delaySeconds), last_status = :lastStatus, last_error = :lastError
    WHERE id = :id AND project_id = :projectId
}

query markFailed(id: String, projectId: Int64, lastStatus: Int32, lastError: String) -> exec {
    UPDATE webhook_deliveries SET status = 'failed', last_status = :lastStatus, last_error = :lastError
    WHERE id = :id AND project_id = :projectId
}
