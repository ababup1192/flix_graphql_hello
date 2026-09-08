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

    import java.lang.Throwable

    use DbError.DbFailure
    use CmsErr.CmsFailure

    /// 業務エラーで ROLLBACK させる時の印。外で元の CmsFailure に戻す。
    def rollbackMarker(): String = "cms-failure"

    ///
    /// JVM の例外（リゾルバの VerifyError、Java interop の例外）を DbErr に変えて、withLazyTx に ROLLBACK と接続の返却をさせる。
    ///
    /// WhyNot: 例外をそのまま上へ通さないのは、withLazyTx に finally が無く、例外が通り抜けると Tx が開いたまま接続が漏れるため
    /// （test/Pg/TestTxLeakPg が見張る）。
    ///
    /// WhyNot: transact の中で 1 度包むだけで済ませないのは、この catch の内側で `run … with handler`（Session.runWith など）を
    /// 入れると、その中で飛んだ例外は catch を素通りするため（2026-09-08 に実測。effect の操作を外の handler へ投げるだけなら catch は効く）。
    /// Runner は主体を決めた後、f を直に包む（`Session.runWith(actor, () -> DbRunner.guarded(f))`）。
    ///
    pub def guarded(thunk: Unit -> a \ ef): a \ ef + IO + DbErr =
        try {
            thunk()
        } catch {
            case e: Throwable => DbErr.other("exception: ${e.toString()}")
        }

    ///
    /// 印付き（projectId があれば RLS の印）の遅延 Tx で thunk を走らせる。一時的な失敗は 3 回まで再試行し、
    /// 業務エラーは ROLLBACK の上で Ok(Err(failure)) として返す。
    ///
    pub def transact(pool: Pool, projectId: Option[ProjectId], thunk: Unit -> a \ ef): Result[DbFailure, Result[CmsFailure, a]] \ (ef - {Db, CmsErr}) + IO =
        let stash = Ref.fresh(Static, None);
        let outcome = DbError.runWithFailure(() -> Retry.withRetry(3, () -> {
            let inTx = () -> match CmsErr.runWithResult(() -> guarded(thunk)) {
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
    /// transact の結果を GraphQL のフィールドの結果に。DB の失敗と業務エラーは GraphqlErrors が写し、成功はリゾルバの戻りをそのまま。
    /// DB の失敗（リゾルバの例外もここに来る）は Error の行を出し、requestId を INTERNAL の extensions に付ける。
    ///
    pub def toFieldResult(requestId: Option[String], outcome: Result[DbFailure, Result[CmsFailure, Result[FieldError, a]]]): Result[FieldError, a] \ Log = match outcome {
        case Err(failure)     => {
            Log.Fields.empty() |> Log.Fields.str("error.code", ErrorCode.text(ErrorCode.Internal)) |> Log.Fields.str("error.message", failureMessage(failure)) |> Log.error("field failed");
            Err(GraphqlErrors.fromDbFailure(requestId, failure))
        }
        case Ok(Err(failure)) => Err(GraphqlErrors.toFieldError(failure))
        case Ok(Ok(result))   => result
    }

    ///
    /// 一時的な失敗は 3 回まで再試行し、DbFailure を Result にする。業務エラーを Tx の中で使わない所（プロジェクトの解決など）用。
    ///
    pub def retrying(thunk: Unit -> a \ ef): Result[DbFailure, a] \ ef - {TransientDbErr, DbErr} =
        DbError.runWithFailure(() -> Retry.withRetry(3, thunk))

    ///
    /// DbFailure を人が読む文言に。
    ///
    pub def failureMessage(failure: DbFailure): String = "database error: ${failure}"

}
