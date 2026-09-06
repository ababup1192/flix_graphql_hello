-- entries: entry の身元。中身は entry_contents に stage ごとの行で持つ。version は楽観ロック
CREATE TABLE entries (
    id TEXT PRIMARY KEY,
    type_id BIGINT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    stage TEXT NOT NULL DEFAULT 'draft',
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT entries_type_id_fkey FOREIGN KEY (type_id) REFERENCES content_types(id),
    CONSTRAINT entries_stage_check CHECK (stage IN ('draft', 'published'))
);
CREATE INDEX entries_type_id_idx ON entries (type_id, updated_at);

-- entry_contents: stage ごとの中身。draft と published の 2 行まで。publish は draft の行を published の行へ写す
CREATE TABLE entry_contents (
    entry_id TEXT NOT NULL,
    stage TEXT NOT NULL,
    data JSONB NOT NULL DEFAULT '{}',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (entry_id, stage),
    CONSTRAINT entry_contents_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    CONSTRAINT entry_contents_stage_check CHECK (stage IN ('draft', 'published'))
);
