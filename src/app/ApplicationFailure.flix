///
/// Tx の境界（DbRunner.transact）で受ける失敗。層ごとに 1 つで、呼ぶ側は平らな match で分ける。
///
/// - Infrastructure: DB の失敗（一時的な物は再試行を使い切った後）。クライアントからは直せない（GraphQL では INTERNAL）
/// - Domain: 業務エラー（CmsErr）。ROLLBACK 済み。GraphQL では extensions.code に分類が出る
///
/// WhyNot: 認証の失敗（UNAUTHENTICATED）をここに足さないのは、認証はリクエストに 1 回で Tx の外（Main.runRoute）で決まり、
/// ドメインは認証済みユーザーしか受け取らないため。認証の失敗は Rejection で、Runner の手前で形にする。
///
pub enum ApplicationFailure with Eq, Order, ToString {
    case Infrastructure(DbError.DbFailure)
    case Domain(CmsErr.CmsFailure)
}

mod ApplicationFailure {

    ///
    /// 人が読む文言。業務エラーは GraphQL の errors[].message と同じ文、DB の失敗は DbRunner.failureMessage。
    ///
    pub def describe(failure: ApplicationFailure): String = match failure {
        case ApplicationFailure.Infrastructure(found) => DbRunner.failureMessage(found)
        case ApplicationFailure.Domain(found)         => CmsErr.toMessage(found)
    }

}
