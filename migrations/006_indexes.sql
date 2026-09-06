-- CASCADE と検索が全走査にならないための索引と、kind の CHECK（content_types.kind と揃える）
CREATE INDEX entry_links_field_idx ON entry_links (field_id);
CREATE INDEX entry_unique_values_field_idx ON entry_unique_values (field_id);
CREATE INDEX content_fields_target_idx ON content_fields (target_type_id);
ALTER TABLE content_fields ADD CONSTRAINT content_fields_kind_check
    CHECK (kind IN ('text', 'textArea', 'slug', 'number', 'boolean', 'select', 'reference', 'object', 'blocks'));
