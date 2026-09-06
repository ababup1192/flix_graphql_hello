-- content_fields.target_type_id: reference の参照先の型
ALTER TABLE content_fields ADD COLUMN target_type_id BIGINT;
ALTER TABLE content_fields ADD CONSTRAINT content_fields_target_type_id_fkey FOREIGN KEY (target_type_id) REFERENCES content_types(id);

-- entry_links: 中身（JSONB）の参照の写し。保存のたびに (entry_id, stage) の分を入れ直す。
-- 公開時の参照先の検査、取り下げ・削除の防止、逆参照はこの表の JOIN
CREATE TABLE entry_links (
    from_entry_id TEXT NOT NULL,
    stage TEXT NOT NULL,
    field_id BIGINT NOT NULL,
    to_entry_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    CONSTRAINT entry_links_from_fkey FOREIGN KEY (from_entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    CONSTRAINT entry_links_field_fkey FOREIGN KEY (field_id) REFERENCES content_fields(id) ON DELETE CASCADE,
    CONSTRAINT entry_links_stage_check CHECK (stage IN ('draft', 'published'))
);
CREATE INDEX entry_links_from_idx ON entry_links (from_entry_id, stage);
CREATE INDEX entry_links_to_idx ON entry_links (to_entry_id, stage);
