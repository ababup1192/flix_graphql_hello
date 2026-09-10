-- entry_links: 参照の索引を、スキーマではなくデータの写しにする。
--
-- field_id は content_fields への FK（ON DELETE CASCADE）だったので、フィールドを消すと索引ごと消えた。
-- 中身（JSONB）は消えないので配信は参照を返し続け、impact と publishCheck だけが
-- 「壊れる物は無い」「公開できます」と答えていた。api_id なら消えても足し直しても行が動かない。
--
-- apiId の一意は (type_id, api_id) でプロジェクト内では一意でないので、読む側は
-- from_entry_id → entries.type_id を辿って content_fields と突き合わせる。
ALTER TABLE entry_links ADD COLUMN field_api_id TEXT;
UPDATE entry_links AS l SET field_api_id = f.api_id FROM content_fields AS f WHERE f.id = l.field_id;
ALTER TABLE entry_links ALTER COLUMN field_api_id SET NOT NULL;
ALTER TABLE entry_links DROP COLUMN field_id;

-- entry_contents: テナントの守りの 3 本目（RLS）に入れる。
--
-- 中身そのものを持つ表なのに project_id が無く、012_rls.sql の対象から漏れていた。
-- 守りが entries 側の条件だけだったので、条件を書き忘れた query 1 本で他のプロジェクトが読めた。
ALTER TABLE entry_contents ADD COLUMN project_id BIGINT;
UPDATE entry_contents AS c SET project_id = e.project_id FROM entries AS e WHERE e.id = c.entry_id;
ALTER TABLE entry_contents ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE entry_contents ADD CONSTRAINT entry_contents_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);

ALTER TABLE entry_contents ENABLE ROW LEVEL SECURITY;
ALTER TABLE entry_contents FORCE ROW LEVEL SECURITY;
CREATE POLICY entry_contents_project ON entry_contents
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);
