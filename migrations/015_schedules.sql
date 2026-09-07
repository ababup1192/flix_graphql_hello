-- 予約公開。時刻になったら Scheduler が拾って publish / unpublish を実行する。
-- id は ULID。中身は持たない（entry の id と操作だけ）ので RLS は掛けず、Scheduler はプロジェクトを跨いで拾う（webhook_deliveries と同じ考え）
CREATE TABLE scheduled_actions (
    id TEXT PRIMARY KEY,
    project_id BIGINT NOT NULL,
    entry_id TEXT NOT NULL,
    action TEXT NOT NULL,
    run_at TIMESTAMPTZ NOT NULL,
    with_dependencies BOOLEAN NOT NULL DEFAULT false,
    status TEXT NOT NULL DEFAULT 'pending',
    requested_by TEXT NOT NULL DEFAULT '',
    last_error TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    done_at TIMESTAMPTZ,
    CONSTRAINT scheduled_actions_action_check CHECK (action IN ('publish', 'unpublish')),
    CONSTRAINT scheduled_actions_status_check CHECK (status IN ('pending', 'running', 'done', 'failed', 'cancelled'))
);
ALTER TABLE scheduled_actions ADD CONSTRAINT scheduled_actions_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX scheduled_actions_due_idx ON scheduled_actions (status, run_at);
CREATE INDEX scheduled_actions_entry_idx ON scheduled_actions (project_id, entry_id, id DESC);

-- 拾った時刻。実行中に落ちた行（running / sending のまま残った物）を一定時間後に pending へ戻すため
ALTER TABLE scheduled_actions ADD COLUMN claimed_at TIMESTAMPTZ;
ALTER TABLE webhook_deliveries ADD COLUMN claimed_at TIMESTAMPTZ;
