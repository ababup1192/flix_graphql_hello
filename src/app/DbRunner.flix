///
/// GraphQL の Runner が共通で使う DB の包み。再試行の回数、業務エラーと Tx の関係、DbFailure の文言をここで 1 つに決める。
///
/// WhyNot: Retry を withLazyTx の外に置くのは、connectionLost した接続で再試行しても無駄なため（sqlfx の流儀）。
/// 借りるのは thunk の中なので、再試行は新しい接続になる。
///
/// WhyNot: 業務エラー（CmsErr）を withLazyTx の**中**で受けるのは、Flix の effect は再開しない時に間の frame を捨てるだけで
/// finally が無く、外で受けると withLazyTx の COMMIT / ROLLBACK と接続の返却が飛んで「idle in transaction」の接続が漏れるため
/// （test/Pg/TestTxLeakPg が見張る）。中で受けると Err が普通の戻り値になって COMMIT されるので、Err の時は DbErr に
/// 変換して ROLLBACK させ、外で元の失敗に戻す。
///
mod DbRunner {

    use DbError.DbFailure
    use CmsErr.CmsFailure

    /// 業務エラーで ROLLBACK させる時の印。外で元の CmsFailure に戻す。
    def rollbackMarker(): String = "cms-failure"

    ///
    /// 印付き（projectId があれば RLS の印）の遅延 Tx で thunk を走らせる。一時的な失敗は 3 回まで再試行し、
    /// 業務エラーは ROLLBACK の上で Ok(Err(failure)) として返す。
    ///
    pub def transact(pool: Pool, projectId: Option[ProjectId], thunk: Unit -> a \ ef): Result[DbFailure, Result[CmsFailure, a]] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr}) + IO =
        let stash = Ref.fresh(Static, None);
        let outcome = DbError.runWithFailure(() -> Retry.withRetry(3, () -> {
            let inTx = () -> match CmsErr.runWithResult(thunk) {
                case Ok(value)    => value
                case Err(failure) => { Ref.put(Some(failure), stash); DbErr.other(rollbackMarker()) }
            };
            match projectId {
                case Some(found) => TenantTx.withLazyTx(pool, found, inTx)
                case None        => Pool.withLazyTx(pool, inTx)
            }
        }));
        match (outcome, Ref.get(stash)) {
            case (Err(_), Some(failure)) => Ok(Err(failure))
            case (Err(failure), None)    => Err(failure)
            case (Ok(value), _)          => Ok(Ok(value))
        }

    ///
    /// 一時的な失敗は 3 回まで再試行し、DbFailure を Result にする。業務エラーを Tx の中で使わない所（プロジェクトの解決など）用。
    ///
    pub def retrying(thunk: Unit -> a \ ef): Result[DbFailure, a] \ ef - {TransientDbErr, DbErr} =
        DbError.runWithFailure(() -> Retry.withRetry(3, thunk))

    ///
    /// DbFailure を GraphQL のエラー文言に。
    ///
    pub def failureMessage(failure: DbFailure): FieldError = "database error: ${failure}"

}
