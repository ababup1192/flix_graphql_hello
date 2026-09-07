-- 認証・組織・権限。本人確認は外（JWT の発行元）に出し、ここは「誰が、どの組織・プロジェクトで、何の役割か」だけを持つ。
-- 本人の鍵は (issuer, subject)。email は表示と招待の突き合わせにだけ使う（発行元をまたぐと同じ email が 2 行になりうるので UNIQUE にしない）
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    issuer TEXT NOT NULL,
    subject TEXT NOT NULL,
    email TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT users_issuer_subject_key UNIQUE (issuer, subject)
);
CREATE INDEX users_email_idx ON users (email);

-- 組織: 請求と所有の単位。既定の 1 つ（id 1）を作り、既定のプロジェクトを付ける
CREATE TABLE organizations (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO organizations (id, name) VALUES (1, 'default');
SELECT setval('organizations_id_seq', 1);

ALTER TABLE projects ADD COLUMN org_id BIGINT NOT NULL DEFAULT 1;
ALTER TABLE projects ALTER COLUMN org_id DROP DEFAULT;
ALTER TABLE projects ADD CONSTRAINT projects_org_id_fkey FOREIGN KEY (org_id) REFERENCES organizations(id);
-- public: 公開中の中身はキー無しで読める。private: read のキーが要る
ALTER TABLE projects ADD COLUMN visibility TEXT NOT NULL DEFAULT 'public';
ALTER TABLE projects ADD CONSTRAINT projects_visibility_check CHECK (visibility IN ('public', 'private'));

-- 組織の役割。owner は組織の全プロジェクトの owner でもある（Authz の規則）
CREATE TABLE org_members (
    user_id BIGINT NOT NULL,
    org_id BIGINT NOT NULL,
    role TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT org_members_pkey PRIMARY KEY (user_id, org_id),
    CONSTRAINT org_members_role_check CHECK (role IN ('owner', 'member'))
);
ALTER TABLE org_members ADD CONSTRAINT org_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id);
ALTER TABLE org_members ADD CONSTRAINT org_members_org_id_fkey FOREIGN KEY (org_id) REFERENCES organizations(id);

-- プロジェクトの役割
CREATE TABLE memberships (
    user_id BIGINT NOT NULL,
    project_id BIGINT NOT NULL,
    role TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT memberships_pkey PRIMARY KEY (user_id, project_id),
    CONSTRAINT memberships_role_check CHECK (role IN ('owner', 'editor', 'writer', 'viewer'))
);
ALTER TABLE memberships ADD CONSTRAINT memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id);
ALTER TABLE memberships ADD CONSTRAINT memberships_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX memberships_project_idx ON memberships (project_id);

-- 招待。email で人を指し、初回ログインで memberships に写して消す
CREATE TABLE invitations (
    id BIGSERIAL PRIMARY KEY,
    project_id BIGINT NOT NULL,
    email TEXT NOT NULL,
    role TEXT NOT NULL,
    invited_by BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT invitations_project_email_key UNIQUE (project_id, email),
    CONSTRAINT invitations_role_check CHECK (role IN ('owner', 'editor', 'writer', 'viewer'))
);
ALTER TABLE invitations ADD CONSTRAINT invitations_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
ALTER TABLE invitations ADD CONSTRAINT invitations_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES users(id);
CREATE INDEX invitations_email_idx ON invitations (email);

-- 公開 API の鍵。人ではなくアプリ用。生の鍵は作った時に 1 回だけ返し、ここには sha256(pepper + key) だけ置く
CREATE TABLE api_keys (
    id BIGSERIAL PRIMARY KEY,
    project_id BIGINT NOT NULL,
    name TEXT NOT NULL,
    key_hash TEXT NOT NULL,
    -- pepper を回せるように版を持つ
    pepper_id TEXT NOT NULL DEFAULT 'v1',
    -- read: 公開中の中身。readDraft: 下書きも
    scope TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    CONSTRAINT api_keys_key_hash_key UNIQUE (key_hash),
    CONSTRAINT api_keys_scope_check CHECK (scope IN ('read', 'readDraft'))
);
ALTER TABLE api_keys ADD CONSTRAINT api_keys_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id);
CREATE INDEX api_keys_project_idx ON api_keys (project_id, revoked_at);
