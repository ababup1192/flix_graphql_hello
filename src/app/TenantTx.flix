///
/// プロジェクトの印（app.project_id）を置いた Tx。RLS の policy はこの印と一致する行しか見せないので、
/// プロジェクトを知っている Runner はここを通る。印の無い Tx（Account API）からは中身の表が 0 行になる。
///
/// WhyNot: 印を Tenant の handler で置かないのは、Tenant.runWith は Tx の外（Runner の外側）にあり、
/// SQL を流す handler がその時点では無いため。Tx を開く所（Runner）が置けば置き忘れの余地が無い。
///
mod TenantTx {

    ///
    /// projectId の印を BEGIN の直後に置いて thunk を 1 つの遅延 Tx で走らせる。SQL を出さない thunk は印も置かない。
    ///
    pub def withLazyTx(pool: Pool, projectId: ProjectId, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        Pool.withLazyTxAfterBegin(pool, () -> stamp(projectId), thunk)

    ///
    /// 今の Tx にだけ効く印。
    ///
    pub def stamp(projectId: ProjectId): Unit \ DbRead =
        discard TenantQueries.stampProject("${projectId}")

    ///
    /// 接続の間ずっと効く印。Tx を使わない専用の接続（テスト）用。
    ///
    pub def stampSession(projectId: ProjectId): Unit \ DbRead =
        discard TenantQueries.stampProjectSession("${projectId}")

}
