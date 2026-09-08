///
/// GraphQL の Runner が共通で使う DB の包み。再試行の回数、業務エラーと Tx の関係、Session の handler の位置、DbFailure の文言をここで 1 つに決める。
/// Tx を張る入口は `transact`（認証済みユーザー付き。業務エラー込み）と `withTx` の 2 つ。
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

    ///
    /// JVM の例外の網は sqlfx の `Db.guard`（fatal は再送出、それ以外は DbErr.other）。ここでは置く位置だけを決める。
    ///
    /// WhyNot: sqlfx の withLazyTx が最内側で catch する事に任せないのは、その catch の内側に `run … with handler`
    /// （CmsErr.runWithResult / Session.runWith）が入ると、その中で飛んだ例外が catch を素通りするため（2026-09-08 に 0.3.1 と
    /// 0.4.0 の両方で実測。effect の操作を外の handler へ投げるだけなら catch は効く）。一番内側の handler の直下に置く必要があるので、
    /// transact は CmsErr → Session → SQL の数え → Db.guard(f) の順に入れ、f を直に包む。Session の handler はここだけ。
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
    /// 認証済みユーザー（actor）の Tx で thunk を走らせる。BEGIN の直後に RLS の印（scope のプロジェクト、人なら本人）を置き、
    /// Session の handler をここで入れる。一時的な失敗は 3 回まで再試行し、業務エラーは ROLLBACK の上で Domain、DB の失敗は Infrastructure。
    ///
    pub def transact(pool: Pool, scope: Option[ProjectId], actor: Actor, thunk: Unit -> a \ ef): Result[ApplicationFailure, a] \ (ef - {Db, CmsErr, Session}) + IO =
        transactObserved(pool, scope, _ -> (), actor, thunk)

    ///
    /// `transact` に加えて、再試行した回数（1 以上の時だけ）と SQL の数を observe でリクエストの行に戻す。
    /// Runner は Context の observe を渡す（graphql-java のコールバックの中なので Observe effect は届かない）。
    ///
    pub def transactObserved(pool: Pool, scope: Option[ProjectId], observe: Log.Fields -> Unit \ IO, actor: Actor, thunk: Unit -> a \ ef): Result[ApplicationFailure, a] \ (ef - {Db, CmsErr, Session}) + IO =
        let counter = Ref.fresh(Static, 0);
        let statements = Ref.fresh(Static, 0);
        notePool(observe, pool);
        let outcome = retryWith(counter, () ->
            TenantTx.withLazyTxResult(pool, scope, actor, () ->
                CmsErr.runWithResult(() -> Session.runWith(actor, () -> counting(statements, () -> Db.guard(thunk))))));
        noteRetries(observe, Ref.get(counter));
        noteStatements(observe, Ref.get(statements));
        match outcome {
            case Err(failure)     => Err(ApplicationFailure.Infrastructure(failure))
            case Ok(Err(failure)) => Err(ApplicationFailure.Domain(failure))
            case Ok(Ok(value))    => Ok(value)
        }

    ///
    /// SQL の数を数え、外側の handler（withLazyTx の接続）へそのまま転送する。fetch / execute / executeReturning を 1 と数える。
    ///
    /// WhyNot: Db.guard の外に置くのは、一番内側の handler の直下に try を置く決まりのため（handler が try の内側に入ると例外が素通りする）。
    /// CmsErr.runWithResult の内側に置くのは、業務エラーで抜けた後も数えた値を Ref から読めるため。
    ///
    def counting(counter: Ref[Int32, Static], thunk: Unit -> a \ ef): a \ ef + {SqlRead, SqlWrite, IO} =
        run {
            thunk()
        } with handler SqlRead {
            def fetch(sql, params, resume) = { tally(counter); resume(SqlRead.fetch(sql, params)) }
        } with handler SqlWrite {
            def execute(sql, params, resume) = { tally(counter); resume(SqlWrite.execute(sql, params)) }
            def executeReturning(sql, params, resume) = { tally(counter); resume(SqlWrite.executeReturning(sql, params)) }
        }

    /// 1 つ数える。
    def tally(counter: Ref[Int32, Static]): Unit \ IO =
        Ref.put(Ref.get(counter) + 1, counter)

    ///
    /// 出した SQL の数と、この Tx を 1 つとしてリクエストの行に。受ける側（LogFields.mergeCounts）が同じリクエストの分を足し合わせる。
    /// SQL を 1 本も出さなかった Tx（純粋なフィールド）も 1 と数える（transact を呼んだ回数）。
    ///
    def noteStatements(observe: Log.Fields -> Unit \ IO, statements: Int32): Unit \ IO =
        observe(Log.Fields.empty()
            |> Log.Fields.int("db.statements", Int32.toInt64(statements))
            |> Log.Fields.int("db.transactions", 1i64))

    ///
    /// transact の結果を GraphQL のフィールドの結果に。DB の失敗と業務エラーは GraphqlErrors が写し、成功はリゾルバの戻りをそのまま。
    /// DB の失敗（リゾルバの例外もここに来る）は Error の行を出し、requestId を INTERNAL の extensions に付ける。
    ///
    pub def toFieldResult(requestId: Option[String], outcome: Result[ApplicationFailure, Result[FieldError, a]]): Result[FieldError, a] \ Log = match outcome {
        case Err(ApplicationFailure.Infrastructure(failure)) => {
            Log.Fields.empty() |> LogFields.applicationFailure(ApplicationFailure.Infrastructure(failure)) |> Log.error("field failed");
            Err(GraphqlErrors.fromApplicationFailure(requestId, ApplicationFailure.Infrastructure(failure)))
        }
        case Err(ApplicationFailure.Domain(failure)) => Err(GraphqlErrors.fromApplicationFailure(requestId, ApplicationFailure.Domain(failure)))
        case Ok(result)                              => result
    }

    ///
    /// CmsErr も Session も使わない Tx。scope があれば RLS の印付き。一時的な失敗は 3 回まで再試行し、JVM の例外は Db.guard で DbErr にする。
    /// 仕事の tick、プロジェクト slug の解決、認証（Credential → Actor）、content type の目印のような、ユースケースを通さず SQL を出す所用。
    /// src/ で withLazyTx を直に呼べるのはこのファイルと TenantTx だけ（`scripts/check-tx.sh` が見張る）。
    ///
    pub def withTx(pool: Pool, scope: Option[ProjectId], thunk: Unit -> a \ ef): Result[DbFailure, a] \ (ef - Db) + IO =
        withTxObserved(pool, scope, _ -> (), thunk)

    ///
    /// `withTx` に加えて、出した SQL の数と Tx の数（db.statements / db.transactions）を observe でリクエストの行に戻す。
    ///
    pub def withTxObserved(pool: Pool, scope: Option[ProjectId], observe: Log.Fields -> Unit \ IO, thunk: Unit -> a \ ef): Result[DbFailure, a] \ (ef - Db) + IO =
        let statements = Ref.fresh(Static, 0);
        let outcome = retrying(() -> TenantTx.withLazyTx(pool, scope, () -> counting(statements, () -> Db.guard(thunk))));
        noteStatements(observe, Ref.get(statements));
        outcome

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
