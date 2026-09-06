-- entry_unique_values: unique なフィールドの公開中の値。DB の PK で一意を守り、実行時の DDL を要らなくする
CREATE TABLE entry_unique_values (
    type_id BIGINT NOT NULL,
    field_id BIGINT NOT NULL,
    value TEXT NOT NULL,
    entry_id TEXT NOT NULL,
    PRIMARY KEY (type_id, field_id, value),
    CONSTRAINT entry_unique_values_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    CONSTRAINT entry_unique_values_field_id_fkey FOREIGN KEY (field_id) REFERENCES content_fields(id) ON DELETE CASCADE
);
CREATE INDEX entry_unique_values_entry_id_idx ON entry_unique_values (entry_id);

-- entry_versions: 公開時と明示的な保存だけ積む履歴。自動保存は積まない
CREATE TABLE entry_versions (
    id BIGSERIAL PRIMARY KEY,
    entry_id TEXT NOT NULL,
    version INTEGER NOT NULL,
    data JSONB NOT NULL,
    author TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT entry_versions_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    CONSTRAINT entry_versions_reason_check CHECK (reason IN ('publish', 'save'))
);
CREATE INDEX entry_versions_entry_id_idx ON entry_versions (entry_id, id);
