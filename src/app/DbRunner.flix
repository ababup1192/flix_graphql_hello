///
/// GraphQL の Runner が共通で使う DB の包み。再試行の回数と、DbFailure の文言をここで 1 つに決める。
///
/// WhyNot: Retry を withLazyTx の外に置くのは、connectionLost した接続で再試行しても無駄なため（sqlfx の流儀）。
/// 借りるのは thunk の中なので、再試行は新しい接続になる。業務エラー（CmsErr）のハンドラも thunk の中で withLazyTx の外に置く。
/// 内側に置くと Err を普通の戻り値として返して Tx が COMMIT されてしまう。
///
mod DbRunner {

    ///
    /// 一時的な失敗は 3 回まで再試行し、DbFailure を Result にする。
    ///
    pub def retrying(thunk: Unit -> a \ ef): Result[DbError.DbFailure, a] \ ef - {TransientDbErr, DbErr} =
        DbError.runWithFailure(() -> Retry.withRetry(3, thunk))

    ///
    /// DbFailure を GraphQL のエラー文言に。
    ///
    pub def failureMessage(failure: DbError.DbFailure): FieldError = "database error: ${failure}"

}
