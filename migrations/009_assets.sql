-- assets: 画像やファイルのメタデータ。中身は S3 互換ストレージ（R2 / MinIO）に key で置き、DB は場所と属性だけ持つ。
-- pending は署名付き URL を出した直後、ready はブラウザが置いた後に confirm が確かめた状態
CREATE TABLE assets (
    id TEXT PRIMARY KEY,
    project_id BIGINT NOT NULL,
    key TEXT NOT NULL,
    file_name TEXT NOT NULL,
    mime TEXT NOT NULL,
    size BIGINT NOT NULL,
    -- 画像の寸法。0 は不明（画像でない、または confirm で渡されなかった）
    width INTEGER NOT NULL DEFAULT 0,
    height INTEGER NOT NULL DEFAULT 0,
    alt TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT assets_key_key UNIQUE (key),
    CONSTRAINT assets_status_check CHECK (status IN ('pending', 'ready'))
);
ALTER TABLE assets ADD CONSTRAINT assets_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX assets_project_idx ON assets (project_id, created_at DESC);

-- フィールド種別に asset と richText を足す
ALTER TABLE content_fields DROP CONSTRAINT content_fields_kind_check;
ALTER TABLE content_fields ADD CONSTRAINT content_fields_kind_check
    CHECK (kind IN ('text','textArea','slug','number','boolean','select','reference','object','blocks','asset','richText'));
