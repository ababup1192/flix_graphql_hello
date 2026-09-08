///
/// 管理 API のリゾルバが使う効果の和。DB の読み書き、CMS の業務エラー、id の採番、今のプロジェクト、認証済みユーザー、asset の保存先、先読みの写し。
///
pub type alias AdminEff = Db + CmsErr + IdGen + Tenant + Session + ObjectStore + Time.Clock.Clock + Log + Preloaded

///
/// 管理 API の Runner。リゾルバ 1 つの実行を「最初の SQL で借りる接続 1 本・Tx 1 つ」に包み、失敗を GraphQL のエラーに写す。
/// 認証はリクエストに 1 回済んでいて（Context の actor）、ここでは行わない。
/// 純粋なフィールド（ContentType.name など）は SQL を出さないのでプールに触らない。
///
mod AdminRunner {

    ///
    /// プールと依存とプロジェクトから Runner を作る。エンジンはプロジェクトごとに 1 つ（AdminEngine）。
    ///
    pub def make(pool: Pool, deps: Deps, projectId: ProjectId): Runner[AdminEff] =
        (context, f) -> runOne(pool, deps, projectId, context, f)

    ///
    /// 1 フィールドぶん。環境の handler（AppEnv）と先読みの写し（context の preload。フィールドを跨いで同じ Ref）を入れ、
    /// 認証済みユーザーの Tx（DbRunner.transact）で f を走らせる。
    /// Log は deps の出力先で入れ直し、リクエストの span（context の log。認証の属性込み）を行に付ける。
    ///
    def runOne(pool: Pool, deps: Deps, projectId: ProjectId, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AdminEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        AppEnv.runWith(deps, context#log, projectId, () ->
            Preloaded.runWith(context#preload, () -> transactField(pool, projectId, context, f)))

    ///
    /// リクエストの Tx（読むだけの文書）があればそれで、無ければフィールドごとの Tx で f を走らせ、失敗を GraphQL のエラーに写す。
    ///
    def transactField(pool: Pool, projectId: ProjectId, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AdminEff + IO): Result[FieldError, JavaValue.Boxed] \ {IO, Log, IdGen, Tenant, ObjectStore, Time.Clock.Clock, Preloaded} =
        match context#tx {
            case Some(handle) => DbRunner.transactShared(handle, context#observe, context#actor, f) |> DbRunner.toSharedFieldResult(LogFields.requestIdOf(context#log))
            case None         => DbRunner.transactObserved(pool, Some(projectId), context#observe, context#actor, f) |> DbRunner.toFieldResult(LogFields.requestIdOf(context#log))
        }

}
