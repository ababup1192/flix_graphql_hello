///
/// Account API のリゾルバが使う効果の和。DB の読み書き、CMS の業務エラー、認証済みユーザー、時計。Tenant が無いのが管理 API との違いで、
/// プロジェクトのユースケース（型に Tenant が付く）はここから呼べない。
///
pub type alias AccountEff = Db + CmsErr + IdGen + Session + Time.Clock.Clock + Log

///
/// Account API の Runner。リゾルバ 1 つを「最初の SQL で借りる接続 1 本・Tx 1 つ」に包み、失敗を GraphQL のエラーに写す。
/// 認証（鍵とプレビュートークンの断りを含む）はリクエストに 1 回済んでいる。
///
mod AccountRunner {

    ///
    /// プールと依存から Runner を作る。プロジェクトを持たないのでエンジンは 1 つ。
    ///
    pub def make(pool: Pool, deps: Deps): Runner[AccountEff] =
        (context, f) -> runOne(pool, deps, context, f)

    def runOne(pool: Pool, deps: Deps, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AccountEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        AppEnv.runWithoutProject(deps, context#log, () -> transactField(pool, context, f))

    ///
    /// リクエストの Tx（読むだけの文書）があればそれで、無ければフィールドごとの Tx で f を走らせ、失敗を GraphQL のエラーに写す。
    ///
    def transactField(pool: Pool, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AccountEff + IO): Result[FieldError, JavaValue.Boxed] \ {IO, Log, IdGen, Time.Clock.Clock} =
        match context#tx {
            case Some(handle) => DbRunner.transactShared(handle, context#observe, context#actor, f) |> DbRunner.toSharedFieldResult(LogFields.requestIdOf(context#log))
            case None         => DbRunner.transactObserved(pool, None, context#observe, context#actor, f) |> DbRunner.toFieldResult(LogFields.requestIdOf(context#log))
        }

}
