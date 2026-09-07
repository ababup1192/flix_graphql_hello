-- auth の表にも RLS。プロジェクトの印（app.project_id）に加え、ログインした人の印（app.user_id / app.email。Accounts.resolveUser が置く）で
-- 「自分の行」だけはプロジェクトを跨いで見える（招待の受け入れ、自分のプロジェクト一覧）。api_keys はプロジェクトの印だけ。
ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE memberships FORCE ROW LEVEL SECURITY;
CREATE POLICY memberships_scope ON memberships
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint
           OR user_id = nullif(current_setting('app.user_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint
                OR user_id = nullif(current_setting('app.user_id', true), '')::bigint);

ALTER TABLE invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE invitations FORCE ROW LEVEL SECURITY;
CREATE POLICY invitations_scope ON invitations
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint
           OR email = nullif(current_setting('app.email', true), ''))
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);

ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_keys FORCE ROW LEVEL SECURITY;
CREATE POLICY api_keys_project ON api_keys
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);
