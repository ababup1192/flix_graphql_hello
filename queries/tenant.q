// tenant.q: RLS の印。policy が current_setting('app.project_id') を読むので、Tx（か接続）の先頭でこれを流す

// Tx の間だけ効く印（プールの接続に残らない）。Runner が BEGIN の直後に流す
query stampProject(projectId: String) -> one {
    SELECT set_config('app.project_id', :projectId, true)::text AS applied
}

// 接続の間ずっと効く印。Tx を使わない専用の接続（テスト）用
query stampProjectSession(projectId: String) -> one {
    SELECT set_config('app.project_id', :projectId, false)::text AS applied
}

// ログインした人の印。memberships / invitations の policy が「自分の行」を跨いで見せるのに使う（招待の受け入れ、自分のプロジェクト一覧）
query stampUser(userId: String, email: String) -> one {
    SELECT set_config('app.user_id', :userId, true)::text AS applied, set_config('app.email', :email, true)::text AS email_applied
}
