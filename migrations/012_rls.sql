-- プロジェクトの中身の表に RLS。Tx の先頭で置いた app.project_id（tenant.q の stampProject）と一致する行しか見えず、入らない。
-- 印の無い Tx は 0 行（current_setting の第 2 引数 true は「無ければ NULL」で、NULL との比較は偽）。
-- FORCE で表の所有者にも効かせる。アプリのロール分離（cms_app）は起動時に作る（deploy/README.md）。
ALTER TABLE content_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE content_types FORCE ROW LEVEL SECURITY;
CREATE POLICY content_types_project ON content_types
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);

ALTER TABLE content_fields ENABLE ROW LEVEL SECURITY;
ALTER TABLE content_fields FORCE ROW LEVEL SECURITY;
CREATE POLICY content_fields_project ON content_fields
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);

ALTER TABLE entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE entries FORCE ROW LEVEL SECURITY;
CREATE POLICY entries_project ON entries
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);

ALTER TABLE entry_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE entry_versions FORCE ROW LEVEL SECURITY;
CREATE POLICY entry_versions_project ON entry_versions
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);

ALTER TABLE entry_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE entry_links FORCE ROW LEVEL SECURITY;
CREATE POLICY entry_links_project ON entry_links
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);

ALTER TABLE assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE assets FORCE ROW LEVEL SECURITY;
CREATE POLICY assets_project ON assets
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);
