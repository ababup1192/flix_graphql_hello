// tenant.q: RLS の印。policy が current_setting('app.project_id') を読むので、Tx（か接続）の先頭でこれを流す

// Tx の間だけ効く印（プールの接続に残らない）。Runner が BEGIN の直後に流す
query stampProject(projectId: String) -> one {
    SELECT set_config('app.project_id', :projectId, true)::text AS applied
}

// 接続の間ずっと効く印。Tx を使わない専用の接続（テスト）用
query stampProjectSession(projectId: String) -> one {
    SELECT set_config('app.project_id', :projectId, false)::text AS applied
}
