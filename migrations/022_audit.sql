-- 監査の記録。誰が・いつ・何を変えたか。業務の書き込みと同じ Tx で 1 行積むので、
-- 「変えたのに記録が無い」も「記録があるのに変わっていない」も起きない。
-- entry の変更は entry_versions が中身ごと持っているので、ここに積むのは版の残らない物
-- （メンバー・役割・鍵・型）だけ。
CREATE TABLE audit_events (
    id TEXT PRIMARY KEY,
    project_id BIGINT NOT NULL,
    actor TEXT NOT NULL,
    action TEXT NOT NULL,
    target_kind TEXT NOT NULL,
    target_id TEXT NOT NULL,
    detail JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE audit_events ADD CONSTRAINT audit_events_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
-- id は ULID なので、id の降順が新しい順
CREATE INDEX audit_events_project_idx ON audit_events (project_id, id DESC);

-- RLS。他の表と同じ印（app.project_id）で見えるが、SELECT と INSERT の policy しか作らない。
-- UPDATE と DELETE はどの policy にも当たらないので、FORCE の下ではアプリも表の所有者も書き換えられない（append-only）。
-- 保持の都合で古い行を消す時は、この policy を足す migration を書く（消せる事を記録に残す）。
ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_events FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_events_read ON audit_events FOR SELECT
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint);
CREATE POLICY audit_events_append ON audit_events FOR INSERT
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);
