-- content_types: content type の定義。singular / plural は空なら api_id から導いた値を入れる（NULL にしない）
CREATE TABLE content_types (
    id BIGSERIAL PRIMARY KEY,
    api_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    singular TEXT NOT NULL,
    plural TEXT NOT NULL,
    preview_url TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT content_types_api_id_key UNIQUE (api_id),
    CONSTRAINT content_types_kind_check CHECK (kind IN ('collection', 'singleton'))
);

-- content_fields: 型ごとのフィールド。config は kind ごとの設定（葉の設定だけ）
CREATE TABLE content_fields (
    id BIGSERIAL PRIMARY KEY,
    type_id BIGINT NOT NULL,
    api_id TEXT NOT NULL,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    is_many BOOLEAN NOT NULL DEFAULT FALSE,
    is_required BOOLEAN NOT NULL DEFAULT FALSE,
    is_unique BOOLEAN NOT NULL DEFAULT FALSE,
    is_localized BOOLEAN NOT NULL DEFAULT FALSE,
    config JSONB NOT NULL DEFAULT '{}',
    position INTEGER NOT NULL,
    CONSTRAINT content_fields_type_id_fkey FOREIGN KEY (type_id) REFERENCES content_types(id) ON DELETE CASCADE,
    CONSTRAINT content_fields_api_id_key UNIQUE (type_id, api_id)
);
