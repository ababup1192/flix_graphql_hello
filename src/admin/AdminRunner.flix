///
/// 管理 API のリゾルバが使う効果の和。DB の読み書き、CMS の業務エラー、id の採番、今のプロジェクト、asset の保存先。
///
pub type alias AdminEff = {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr, IdGen, Tenant, ObjectStore}

///
/// 管理 API の Runner。リゾルバ 1 つの実行を「最初の SQL で借りる接続 1 本・Tx 1 つ」に包み、失敗を GraphQL のエラーに写す。
/// 純粋なフィールド（ContentType.name など）は SQL を出さないのでプールに触らない。
///
mod AdminRunner {

    ///
    /// プールとプロジェクトから Runner を作る。エンジンはプロジェクトごとに 1 つ（AdminEngine）。
    ///
    pub def make(pool: Pool, storage: Option[StorageConfig.StorageConfig], projectId: ProjectId): Runner[AdminEff] =
        f -> runOne(pool, storage, projectId, f)

    ///
    /// 1 フィールドぶん。DbFailure と CmsFailure をメッセージにする。
    ///
    def runOne(pool: Pool, storage: Option[StorageConfig.StorageConfig], projectId: ProjectId, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AdminEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        let outcome = DbRunner.retrying(() ->
            CmsErr.runWithResult(() ->
                IdGen.runWithRandom(() ->
                    Tenant.runWith(projectId, () ->
                        Net.Http.runWithIO(() -> Time.Clock.runWithIO(() -> ObjectStore.runWith(storage, () ->
                            Pool.withLazyTx(pool, f))))))));
        match outcome {
            case Err(failure)      => Err(DbRunner.failureMessage(failure))
            case Ok(Err(failure))  => Err(CmsErr.toMessage(failure))
            case Ok(Ok(result))    => result
        }

}
