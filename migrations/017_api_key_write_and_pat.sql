-- API キーに write（役割付き）・期限・最終使用時刻を足す。write の鍵は役割（writer / editor / owner）の範囲で管理 API を叩ける
ALTER TABLE api_keys ADD COLUMN role TEXT;
ALTER TABLE api_keys ADD COLUMN expires_at TIMESTAMPTZ;
ALTER TABLE api_keys ADD COLUMN last_used_at TIMESTAMPTZ;
ALTER TABLE api_keys DROP CONSTRAINT api_keys_scope_check;
ALTER TABLE api_keys ADD CONSTRAINT api_keys_scope_check CHECK (scope IN ('read', 'readDraft', 'write'));
ALTER TABLE api_keys ADD CONSTRAINT api_keys_role_check CHECK (role IS NULL OR role IN ('writer', 'editor', 'owner'));
ALTER TABLE api_keys ADD CONSTRAINT api_keys_write_has_role_check CHECK ((scope = 'write') = (role IS NOT NULL));

-- Personal Access Token: 人の代わりに使うトークン（CLI / スクリプト用）。本人の役割で動き、read なら読むだけ。
-- 生のトークンは作った時に 1 回だけ返し、ここには sha256(pepper + token) だけ置く。期限は必須（最長 365 日）
CREATE TABLE personal_access_tokens (
    id BIGSERIAL PRIMARY KEY,
    public_id TEXT NOT NULL,
    user_id BIGINT NOT NULL,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    pepper_id TEXT NOT NULL DEFAULT 'v1',
    scope TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    CONSTRAINT personal_access_tokens_public_id_key UNIQUE (public_id),
    CONSTRAINT personal_access_tokens_token_hash_key UNIQUE (token_hash),
    CONSTRAINT personal_access_tokens_scope_check CHECK (scope IN ('read', 'write'))
);
ALTER TABLE personal_access_tokens ADD CONSTRAINT personal_access_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id);
CREATE INDEX personal_access_tokens_user_idx ON personal_access_tokens (user_id, revoked_at);

-- RLS: 一覧と失効は本人の印（app.user_id）。hash での解決は本人が分かる前に走るので、トークンの hash 自体を印（app.token_hash）にして
-- その 1 行だけ見せる（印は秘密から導いた値なので、印を知る者は既にトークンを持っている）。書き込みは本人の印だけ
ALTER TABLE personal_access_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE personal_access_tokens FORCE ROW LEVEL SECURITY;
CREATE POLICY personal_access_tokens_owner ON personal_access_tokens
    USING (user_id = nullif(current_setting('app.user_id', true), '')::bigint
           OR token_hash = nullif(current_setting('app.token_hash', true), ''))
    WITH CHECK (user_id = nullif(current_setting('app.user_id', true), '')::bigint);
