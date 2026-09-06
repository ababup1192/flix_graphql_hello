-- content_fields.parent_field_id: object / blocks の子。親を消せば子も消える。
-- apiId の一意は型の中全体（(type_id, api_id)）のまま。子の名前も型の中で重ねない
ALTER TABLE content_fields ADD COLUMN parent_field_id BIGINT;
ALTER TABLE content_fields ADD CONSTRAINT content_fields_parent_field_id_fkey FOREIGN KEY (parent_field_id) REFERENCES content_fields(id) ON DELETE CASCADE;
CREATE INDEX content_fields_parent_idx ON content_fields (parent_field_id);
