///
/// コンテンツ API のリゾルバが使う効果の和。読むだけ。書く関数を呼べばコンパイルで落ちる。
///
pub type alias ContentEff = DbRead + CmsErr + Tenant + Session + ObjectStore + Log

///
/// コンテンツ API の Runner。読むだけなので Tx は要らないが、フィールド単位で接続を借り直さないよう
/// withLazyTx で「最初の SQL で借りて最後に返す」にする。認証（private なプロジェクトの断りを含む）はリクエストに 1 回済んでいる。
///
mod ContentRunner {

    ///
    /// プールから Runner を作る。
    ///
    pub def make(pool: Pool, deps: Deps, projectId: ProjectId): Runner[ContentEff] =
        (context, f) -> runOne(pool, deps, projectId, context, f)

    def runOne(pool: Pool, deps: Deps, projectId: ProjectId, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ ContentEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        AppEnv.runWith(deps, context#log, projectId, () -> transactField(pool, projectId, context, f))

    ///
    /// リクエストの Tx（読むだけの文書）があればそれで、無ければフィールドごとの Tx で f を走らせ、失敗を GraphQL のエラーに写す。
    ///
    def transactField(pool: Pool, projectId: ProjectId, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ ContentEff + IO): Result[FieldError, JavaValue.Boxed] \ {IO, Log, Tenant, ObjectStore} =
        match context#tx {
            case Some(handle) => DbRunner.transactShared(handle, context#observe, context#actor, f) |> DbRunner.toSharedFieldResult(LogFields.requestIdOf(context#log))
            case None         => DbRunner.transactObserved(pool, Some(projectId), context#observe, context#actor, f) |> DbRunner.toFieldResult(LogFields.requestIdOf(context#log))
        }

}
