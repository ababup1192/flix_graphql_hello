-- projects: 型と entry の集まり。1 つの DB に複数持てる（クラウド提供とセルフホストを同じコードで動かすため）。
-- 既定の 1 つ（id 1 / default）を先に作り、既存の行はそこに付ける
CREATE TABLE projects (
    id BIGSERIAL PRIMARY KEY,
    slug TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT projects_slug_key UNIQUE (slug)
);
INSERT INTO projects (id, slug, name) VALUES (1, 'default', 'default');
SELECT setval('projects_id_seq', 1);

ALTER TABLE content_types ADD COLUMN project_id BIGINT NOT NULL DEFAULT 1;
ALTER TABLE content_types ALTER COLUMN project_id DROP DEFAULT;
ALTER TABLE content_types ADD CONSTRAINT content_types_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
ALTER TABLE content_types DROP CONSTRAINT content_types_api_id_key;
ALTER TABLE content_types ADD CONSTRAINT content_types_project_api_id_key UNIQUE (project_id, api_id);

ALTER TABLE entries ADD COLUMN project_id BIGINT NOT NULL DEFAULT 1;
ALTER TABLE entries ALTER COLUMN project_id DROP DEFAULT;
ALTER TABLE entries ADD CONSTRAINT entries_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX entries_project_idx ON entries (project_id);
