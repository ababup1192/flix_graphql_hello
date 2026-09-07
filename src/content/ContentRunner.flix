///
/// コンテンツ API のリゾルバが使う効果の和。読むだけ。書く関数を呼べばコンパイルで落ちる。
///
pub type alias ContentEff = {SqlRead, TransientDbErr, DbErr, Tenant, ObjectStore}

///
/// コンテンツ API の Runner。読むだけなので Tx は要らないが、フィールド単位で接続を借り直さないよう
/// withLazyTx で「最初の SQL で借りて最後に返す」にする。DbFailure を GraphQL のエラーに写す。
///
mod ContentRunner {

    ///
    /// プールから Runner を作る。
    ///
    pub def make(pool: Pool, storage: Option[StorageConfig.StorageConfig], projectId: ProjectId): Runner[ContentEff] =
        f -> runOne(pool, storage, projectId, f)

    def runOne(pool: Pool, storage: Option[StorageConfig.StorageConfig], projectId: ProjectId, f: Unit -> Result[FieldError, JavaValue.Boxed] \ ContentEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        match DbRunner.retrying(() -> Tenant.runWith(projectId, () -> Net.Http.runWithIO(() -> Time.Clock.runWithIO(() -> ObjectStore.runWith(storage, () -> Pool.withLazyTx(pool, f)))))) {
            case Err(failure) => Err(DbRunner.failureMessage(failure))
            case Ok(result)   => result
        }

}
