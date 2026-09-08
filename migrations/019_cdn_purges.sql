-- CDN の purge の outbox。Webhook の配信（webhook_deliveries）と同じ形で、dispatcher が拾って POST し、同じ間隔で再試行する。
-- 積むのはバックグラウンドの tick（projects.content_version > purged_version のプロジェクト）。purge_everything なので
-- 1 プロジェクトに何件も要らず、積む時に purged_version を content_version まで進める（同じ Tx）
CREATE TABLE cdn_purges (
    id TEXT PRIMARY KEY,
    project_id BIGINT NOT NULL,
    content_version BIGINT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    claimed_at TIMESTAMPTZ,
    last_status INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at TIMESTAMPTZ,
    CONSTRAINT cdn_purges_status_check CHECK (status IN ('pending', 'sending', 'delivered', 'failed'))
);
ALTER TABLE cdn_purges ADD CONSTRAINT cdn_purges_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX cdn_purges_due_idx ON cdn_purges (status, next_attempt_at);

-- purge を積んだ時点の版。content_version より小さければ purge が要る
ALTER TABLE projects ADD COLUMN purged_version BIGINT NOT NULL DEFAULT 0;
