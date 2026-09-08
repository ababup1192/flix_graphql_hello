///
/// RLS の印（app.project_id / app.user_id / app.email）を置いた Tx。policy はこの印と一致する行しか見せないので、
/// Tx を開く物（DbRunner の transact / withTx）がここを通る。プロジェクトの印の無い Tx（Account API）からは中身の表が 0 行になる。
///
/// WhyNot: 印を Tenant / Session の handler で置かないのは、それらは Tx の外（Runner の外側）にあり、
/// SQL を流す handler がその時点では無いため。Tx を開く所が置けば置き忘れの余地が無い。
///
/// WhyNot: app.token_hash をここで置かないのは、それは PAT の hash で引く時（PersonalTokens.resolve。認証の Tx）だけに要る印で、
/// 業務の Tx で personal_access_tokens を読む一覧・失効・使用時刻は本人の印（app.user_id）で通るため。
///
mod TenantTx {

    ///
    /// scope の印（あれば）を BEGIN の直後に置いて thunk を 1 つの遅延 Tx で走らせる。SQL を出さない thunk は印も置かない。
    ///
    pub def withLazyTx(pool: Pool, scope: Option[ProjectId], thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        Pool.withLazyTxAfterBegin(pool, () -> stampScope(scope), thunk)

    ///
    /// `withLazyTx` の Result 版。scope の印に加えて、認証済みユーザーが人（Actor.User）なら本人の印も置く。
    /// thunk が Err を返したら ROLLBACK して、その Err をそのまま返す。業務エラーを Tx の中で受ける DbRunner.transact が使う。
    ///
    pub def withLazyTxResult(pool: Pool, scope: Option[ProjectId], actor: Actor, thunk: Unit -> Result[e, a] \ ef): Result[e, a] \ (ef - {SqlRead, SqlWrite}) + {IO, TransientDbErr, DbErr} =
        Pool.withLazyTxResultAfterBegin(pool, () -> stampTx(scope, actor), thunk)

    ///
    /// 今の Tx にだけ効く印。プロジェクト（あれば）と本人（人なら）。
    ///
    pub def stampTx(scope: Option[ProjectId], actor: Actor): Unit \ DbRead =
        stampScope(scope);
        stampActor(actor)

    /// プロジェクトの印。
    def stampScope(scope: Option[ProjectId]): Unit \ DbRead =
        Option.forEach(projectId -> discard TenantQueries.stampProject("${projectId}"), scope)

    /// 本人の印。memberships / invitations / personal_access_tokens の policy が「自分の行」を見せるのに使う。
    def stampActor(actor: Actor): Unit \ DbRead = match actor {
        case Actor.User(id, email, _, _) => discard TenantQueries.stampUser({ userId = "${id}", email = email })
        case _                           => ()
    }

    ///
    /// 接続の間ずっと効く印。Tx を使わない専用の接続（テスト）用。
    ///
    pub def stampConnection(projectId: ProjectId): Unit \ DbRead =
        discard TenantQueries.stampProjectSession("${projectId}")

}
