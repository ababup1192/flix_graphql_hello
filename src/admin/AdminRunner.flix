///
/// 管理 API のリゾルバが使う効果の和。DB の読み書きと CMS の業務エラー。
///
pub type alias AdminEff = {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr}

///
/// 管理 API の Runner。リゾルバ 1 つの実行を「接続 1 本・Tx 1 つ」に包み、失敗を GraphQL のエラーに写す。
///
/// WhyNot: Retry を Pool.withConnection の外に置くのは、connectionLost した接続で再試行しても無駄なため（sqlfx の流儀）。
///
/// WhyNot: 純粋なフィールド（ContentType.name など）も同じ道を通るのは、Runner が f の中身を知れないため。
/// 接続の借り出しと BEGIN / COMMIT が 1 フィールドごとに走るが、管理 API の量では問題にならない。
///
mod AdminRunner {

    ///
    /// プールから Runner を作る。
    ///
    pub def make(pool: Pool): Runner[AdminEff] =
        f -> runOne(pool, f)

    ///
    /// 1 フィールドぶん。DbFailure と CmsFailure をメッセージにする。
    ///
    def runOne(pool: Pool, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AdminEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        let outcome = DbError.runWithFailure(() ->
            Retry.withRetry(3, () ->
                Pool.withConnection(pool, conn ->
                    CmsErr.runWithResult(() ->
                        Tx.withTx(conn, f)))));
        match outcome {
            case Err(failure)      => Err("database error: ${failure}")
            case Ok(Err(failure))  => Err(CmsErr.toMessage(failure))
            case Ok(Ok(result))    => result
        }

}
