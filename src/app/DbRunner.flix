///
/// GraphQL の Runner が共通で使う DB の包み。再試行の回数、業務エラーと Tx の関係、DbFailure の文言をここで 1 つに決める。
///
/// WhyNot: Retry を withLazyTx の外に置くのは、connectionLost した接続で再試行しても無駄なため（sqlfx の流儀）。
/// 借りるのは thunk の中なので、再試行は新しい接続になる。
///
/// WhyNot: 業務エラー（CmsErr）を withLazyTx の**中**で受けるのは、Flix の effect は再開しない時に間の frame を捨てるだけで
/// finally が無く、外で受けると withLazyTx の COMMIT / ROLLBACK と接続の返却が飛んで「idle in transaction」の接続が漏れるため
/// （test/Pg/TestTxLeakPg が見張る）。中で受けた Err は `Pool.withLazyTxResult` が ROLLBACK した上でそのまま返す。
///
mod DbRunner {

    use DbError.DbFailure
    use CmsErr.CmsFailure

    ///
    /// JVM の例外の網は sqlfx の `Db.guard`（fatal は再送出、それ以外は DbErr.other）。ここでは置く位置だけを決める。
    ///
    /// WhyNot: sqlfx の withLazyTx が最内側で catch する事に任せないのは、その catch の内側に `run … with handler`
    /// （CmsErr.runWithResult / Session.runWith）が入ると、その中で飛んだ例外が catch を素通りするため（2026-09-08 に 0.3.1 と
    /// 0.4.0 の両方で実測。effect の操作を外の handler へ投げるだけなら catch は効く）。一番内側の handler の直下に置く必要があるので、
    /// transact は CmsErr の内側で、Runner は Session の内側で f を直に包む（`Session.runWith(actor, () -> Db.guard(f))`）。
    ///
    ///
    /// 再試行の待ち方。3 回、200 ms から 2 倍、2 秒で頭打ち、full jitter。
    ///
    /// WhyNot: sqlfx の `Retry.defaultPolicy()`（baseMs 100）を使わないのは、CMS 側で borrowTimeoutMs を 2 秒に下げたので
    /// 待ちの合計が全体の所要時間に効くようになり、200 ms 始まりの方が「DB が数秒止まった」を跨ぎやすいため。
    ///
    /// WhyNot: attempts を 3 より増やさないのは、DB が完全に落ちている時の 1 リクエストを 7〜8 秒以内に
    /// INTERNAL で返し切るため（borrow 2 秒 × 3 + 待ち 0〜0.6 秒）。
    ///
    pub def retryPolicy(): Retry.Policy =
        { attempts = 3, baseMs = 200, maxMs = 2000 }

    ///
    /// 一時的な失敗を待ってから呼び直す。待ちは `retryPolicy()` で、待った回数（= 再試行の回数）を counter に積む。
    ///
    /// WhyNot: 待たずに呼び直さない（withRetry）のは、DB の再起動を跨ぐのに 3 回の即時再試行では届かず、
    /// 落ちている間は全スレッドが borrowTimeout ぶん揃って張り付くため。jitter を掛けるのは、同時に失敗した
    /// リクエストが同じ時刻に呼び直して起き上がった DB をまた詰まらせるのを避けるため。
    ///
    /// WhyNot: Math.Random を wait / jitter のラムダの中で run しないのは、ラムダの中の run が Unused effect になるため。
    ///
    pub def retryWith(counter: Ref[Int32, Static], thunk: Unit -> a \ ef): Result[DbFailure, a] \ (ef - {TransientDbErr, DbErr}) + IO =
        DbError.runWithFailure(() -> Math.Random.runWithIO(() ->
            Retry.withRetryWith(retryPolicy(), ms -> countedSleep(counter, ms), () -> Math.Random.randomFloat64(), thunk)))

    /// 1 回数えてから待つ。最後の失敗の後は呼ばれないので、呼ばれた回数がそのまま再試行の回数。
    def countedSleep(counter: Ref[Int32, Static], ms: Int32): Unit \ IO =
        Ref.put(Ref.get(counter) + 1, counter);
        Retry.sleepMs(ms)

    /// 再試行した回数をリクエストの行に。0 回なら付けない。
    def noteRetries(observe: Log.Fields -> Unit \ IO, retries: Int32): Unit \ IO =
        if (retries <= 0) ()
        else observe(Log.Fields.empty() |> Log.Fields.int("db.retries", Int32.toInt64(retries)))

    ///
    /// 待ちが出ている時だけ、プールの数字をリクエストの行に。枯渇（待ち行列）を後から数えられるようにする。
    ///
    /// WhyNot: 待ちが 0 の時も出さないのは、全リクエストに 2 つキーが増えて、平常時のログが太るため。
    ///
    def notePool(observe: Log.Fields -> Unit \ IO, pool: Pool): Unit \ IO =
        let stats = Pool.stats(pool);
        if (stats#waiting <= 0) ()
        else observe(Log.Fields.empty()
            |> Log.Fields.int("db.pool.waiting", Int32.toInt64(stats#waiting))
            |> Log.Fields.int("db.pool.active", Int32.toInt64(stats#active)))

    ///
    /// 印付き（projectId があれば RLS の印）の遅延 Tx で thunk を走らせる。一時的な失敗は 3 回まで再試行し、
    /// 業務エラーは ROLLBACK の上で Ok(Err(failure)) として返す。
    ///
    pub def transact(pool: Pool, projectId: Option[ProjectId], thunk: Unit -> a \ ef): Result[DbFailure, Result[CmsFailure, a]] \ (ef - {Db, CmsErr}) + IO =
        transactObserved(pool, projectId, _ -> (), thunk)

    ///
    /// `transact` に加えて、再試行した回数（1 以上の時だけ）を observe でリクエストの行に戻す。
    /// Runner は Context の observe を渡す（graphql-java のコールバックの中なので Observe effect は届かない）。
    ///
    pub def transactObserved(pool: Pool, projectId: Option[ProjectId], observe: Log.Fields -> Unit \ IO, thunk: Unit -> a \ ef): Result[DbFailure, Result[CmsFailure, a]] \ (ef - {Db, CmsErr}) + IO =
        let counter = Ref.fresh(Static, 0);
        notePool(observe, pool);
        let outcome = retryWith(counter, () -> {
            let inTx = () -> CmsErr.runWithResult(() -> Db.guard(thunk));
            match projectId {
                case Some(found) => TenantTx.withLazyTxResult(pool, found, inTx)
                case None        => Pool.withLazyTxResult(pool, inTx)
            }
        });
        noteRetries(observe, Ref.get(counter));
        outcome

    ///
    /// transact の結果を GraphQL のフィールドの結果に。DB の失敗と業務エラーは GraphqlErrors が写し、成功はリゾルバの戻りをそのまま。
    /// DB の失敗（リゾルバの例外もここに来る）は Error の行を出し、requestId を INTERNAL の extensions に付ける。
    ///
    pub def toFieldResult(requestId: Option[String], outcome: Result[DbFailure, Result[CmsFailure, Result[FieldError, a]]]): Result[FieldError, a] \ Log = match outcome {
        case Err(failure)     => {
            Log.Fields.empty()
                |> Log.Fields.str("error.code", ErrorCode.text(ErrorCode.Internal))
                |> Log.Fields.opt("error.kind", LogFields.dbErrorKind(failure))
                |> Log.Fields.str("error.message", failureMessage(failure))
                |> Log.error("field failed");
            Err(GraphqlErrors.fromDbFailure(requestId, failure))
        }
        case Ok(Err(failure)) => Err(GraphqlErrors.toFieldError(failure))
        case Ok(Ok(result))   => result
    }

    ///
    /// CmsErr を使わない Tx。scope があれば RLS の印付き。一時的な失敗は 3 回まで再試行し、JVM の例外は Db.guard で DbErr にする。
    /// 仕事の tick、プロジェクト slug の解決、content type の目印のような、ユースケースを通さず SQL を出す所用。
    /// Tx を張る入口は `transact`（業務エラー込み）と `withTx` の 2 つ。src/ で withLazyTx を直に呼べるのは
    /// このファイルと TenantTx だけ（`scripts/check-tx.sh` が見張る）。
    ///
    pub def withTx(pool: Pool, scope: Option[ProjectId], thunk: Unit -> a \ ef): Result[DbFailure, a] \ (ef - Db) + IO =
        retrying(() -> match scope {
            case Some(found) => TenantTx.withLazyTx(pool, found, () -> Db.guard(thunk))
            case None        => Pool.withLazyTx(pool, () -> Db.guard(thunk))
        })

    ///
    /// 一時的な失敗は 3 回まで再試行し、DbFailure を Result にする。Tx を張らない物（`withTx` と、Tx の外の DB 操作）用。
    ///
    pub def retrying(thunk: Unit -> a \ ef): Result[DbFailure, a] \ (ef - {TransientDbErr, DbErr}) + IO =
        retryWith(Ref.fresh(Static, 0), thunk)

    ///
    /// DbFailure を人が読む文言に。
    ///
    pub def failureMessage(failure: DbFailure): String = "database error: ${DbError.describeFailure(failure)}"

}
