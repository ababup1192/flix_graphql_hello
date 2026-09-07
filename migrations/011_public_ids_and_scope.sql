-- 外向きの id（GraphQL の ID に出す物）を連番から乱数の public_id に。内部の主キー（bigint）は JOIN と RLS 用に残す。
-- 連番は存在する id と規模が推測できるので外に出さない。既存の行は乱数で埋め、以後はアプリ（IdGen）が振る。
ALTER TABLE users ADD COLUMN public_id TEXT NOT NULL DEFAULT '';
UPDATE users SET public_id = substr(md5(random()::text || id::text), 1, 12);
ALTER TABLE users ALTER COLUMN public_id DROP DEFAULT;
ALTER TABLE users ADD CONSTRAINT users_public_id_key UNIQUE (public_id);

ALTER TABLE organizations ADD COLUMN public_id TEXT NOT NULL DEFAULT '';
UPDATE organizations SET public_id = substr(md5(random()::text || id::text), 1, 12);
ALTER TABLE organizations ALTER COLUMN public_id DROP DEFAULT;
ALTER TABLE organizations ADD CONSTRAINT organizations_public_id_key UNIQUE (public_id);

ALTER TABLE projects ADD COLUMN public_id TEXT NOT NULL DEFAULT '';
UPDATE projects SET public_id = substr(md5(random()::text || id::text), 1, 12);
ALTER TABLE projects ALTER COLUMN public_id DROP DEFAULT;
ALTER TABLE projects ADD CONSTRAINT projects_public_id_key UNIQUE (public_id);

ALTER TABLE invitations ADD COLUMN public_id TEXT NOT NULL DEFAULT '';
UPDATE invitations SET public_id = substr(md5(random()::text || id::text), 1, 12);
ALTER TABLE invitations ALTER COLUMN public_id DROP DEFAULT;
ALTER TABLE invitations ADD CONSTRAINT invitations_public_id_key UNIQUE (public_id);

ALTER TABLE api_keys ADD COLUMN public_id TEXT NOT NULL DEFAULT '';
UPDATE api_keys SET public_id = substr(md5(random()::text || id::text), 1, 12);
ALTER TABLE api_keys ALTER COLUMN public_id DROP DEFAULT;
ALTER TABLE api_keys ADD CONSTRAINT api_keys_public_id_key UNIQUE (public_id);

-- 子表にも project_id を持たせる。RLS の policy を親を引かずに書け、生成器の検査（project_id の条件）も親と同じ形になる
ALTER TABLE content_fields ADD COLUMN project_id BIGINT NOT NULL DEFAULT 0;
UPDATE content_fields SET project_id = t.project_id FROM content_types AS t WHERE t.id = content_fields.type_id;
ALTER TABLE content_fields ALTER COLUMN project_id DROP DEFAULT;
ALTER TABLE content_fields ADD CONSTRAINT content_fields_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX content_fields_project_idx ON content_fields (project_id);

ALTER TABLE entry_versions ADD COLUMN project_id BIGINT NOT NULL DEFAULT 0;
UPDATE entry_versions SET project_id = e.project_id FROM entries AS e WHERE e.id = entry_versions.entry_id;
ALTER TABLE entry_versions ALTER COLUMN project_id DROP DEFAULT;
ALTER TABLE entry_versions ADD CONSTRAINT entry_versions_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX entry_versions_project_idx ON entry_versions (project_id);

ALTER TABLE entry_links ADD COLUMN project_id BIGINT NOT NULL DEFAULT 0;
UPDATE entry_links SET project_id = e.project_id FROM entries AS e WHERE e.id = entry_links.from_entry_id;
ALTER TABLE entry_links ALTER COLUMN project_id DROP DEFAULT;
ALTER TABLE entry_links ADD CONSTRAINT entry_links_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX entry_links_project_idx ON entry_links (project_id);
