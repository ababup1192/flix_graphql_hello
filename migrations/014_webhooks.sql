-- Webhook。登録（webhooks）と配信の記録（webhook_deliveries。outbox）。
-- 配信行は公開などと同じ Tx で積み、dispatcher が拾って POST する。Tx が失敗すれば配信も残らない。
CREATE TABLE webhooks (
    id BIGSERIAL PRIMARY KEY,
    public_id TEXT NOT NULL,
    project_id BIGINT NOT NULL,
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    -- HMAC の鍵。作った時に 1 度だけ返す
    secret TEXT NOT NULL,
    events TEXT[] NOT NULL,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT webhooks_public_id_key UNIQUE (public_id)
);
ALTER TABLE webhooks ADD CONSTRAINT webhooks_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX webhooks_project_idx ON webhooks (project_id);
ALTER TABLE webhooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhooks FORCE ROW LEVEL SECURITY;
CREATE POLICY webhooks_project ON webhooks
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);

-- id は ULID（時刻順）。payload は id と出来事だけで中身を持たないので、この表には RLS を掛けない（dispatcher がプロジェクトを跨いで拾う）
CREATE TABLE webhook_deliveries (
    id TEXT PRIMARY KEY,
    project_id BIGINT NOT NULL,
    webhook_id BIGINT NOT NULL,
    event TEXT NOT NULL,
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_status INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at TIMESTAMPTZ,
    CONSTRAINT webhook_deliveries_status_check CHECK (status IN ('pending', 'sending', 'delivered', 'failed'))
);
ALTER TABLE webhook_deliveries ADD CONSTRAINT webhook_deliveries_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
ALTER TABLE webhook_deliveries ADD CONSTRAINT webhook_deliveries_webhook_id_fkey FOREIGN KEY (webhook_id) REFERENCES webhooks(id) ON DELETE CASCADE;
CREATE INDEX webhook_deliveries_due_idx ON webhook_deliveries (status, next_attempt_at);
CREATE INDEX webhook_deliveries_webhook_idx ON webhook_deliveries (webhook_id, id DESC);
