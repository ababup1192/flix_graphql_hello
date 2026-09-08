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

    import java.lang.System
    import java.lang.Throwable
    import java.sql.Connection

    use DbError.DbFailure

    ///
    /// JVM の例外の網は sqlfx の `Db.guard`（fatal は再送出、それ以外は DbErr.other）。ここでは置く位置だけを決める。
    ///
    /// WhyNot: sqlfx の withLazyTx が最内側で catch する事に任せないのは、その catch の内側に `run … with handler`
    /// （runCmsErr / Session.runWith）が入ると、その中で飛んだ例外が catch を素通りするため（2026-09-08 に 0.3.1 と
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
    /// Runner の Tx と、認証と版を読む Tx（withTxObserved）の両方が呼び、受ける側（LogFields.mergeCounts）は大きい方を残す。
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
        // 借りる前に、待ちが出ていればプールの数字をリクエストの行に
        notePool(observe, pool);
        // retry → RLS の印付き Tx → 業務エラー → Session → SQL の数え → JVM の例外の catch（Db.guard）→ 本体、の順に包む
        let outcome = retryWith(counter, () ->
            TenantTx.withLazyTxResult(pool, scope, actor, () ->
                runCmsErr(() -> Session.runWith(actor, () -> counting(statements, () -> Db.guard(thunk))))));
        // 再試行の回数と SQL の数をリクエストの行に
        noteRetries(observe, Ref.get(counter));
        noteStatements(observe, Ref.get(statements));
        toApplicationResult(outcome)

    ///
    /// 業務エラー（CmsErr）を Result に落とす。Tx の境界（transact / transactShared）だけが呼ぶ。
    ///
    /// WhyNot: pub にしない（CmsErr.runWithResult として外に出さない）のは、ユースケースの途中で呼ばれると業務エラーが Tx の中で
    /// 値に潰れ、ROLLBACK も errors[] への写しも起きないため。private なので呼べる場所が型検査で決まり、名前の一覧（allowlist）で見張る必要が無い。
    ///
    def runCmsErr(thunk: Unit -> a \ ef): Result[CmsErr.CmsFailure, a] \ ef - CmsErr =
        run {
            Ok(thunk())
        } with handler CmsErr {
            def notFound(entity, id, _resume) = Err(CmsErr.CmsFailure.NotFound(entity, id))
            def invalid(violations, _resume) = Err(CmsErr.CmsFailure.Invalid(violations))
            def conflict(entity, id, expectedVersion, currentVersion, _resume) = Err(CmsErr.CmsFailure.Conflict(entity, id, expectedVersion, currentVersion))
            def forbidden(permission, _resume) = Err(CmsErr.CmsFailure.Forbidden(permission))
            def requiresLogin(requirement, _resume) = Err(CmsErr.CmsFailure.RequiresLogin(requirement))
        }

    ///
    /// Tx の結果を ApplicationFailure に寄せる。DB の失敗は Infrastructure、業務エラーは Domain、成功はそのまま。
    ///
    def toApplicationResult(outcome: Result[DbFailure, Result[CmsErr.CmsFailure, a]]): Result[ApplicationFailure, a] = match outcome {
        case Err(failure)     => Err(ApplicationFailure.Infrastructure(failure))
        case Ok(Err(failure)) => Err(ApplicationFailure.Domain(failure))
        case Ok(Ok(value))    => Ok(value)
    }

    ///
    /// SQL の数を数え、外側の handler（withLazyTx の接続）へそのまま転送する。fetch / execute / executeReturning を 1 と数える。
    ///
    /// WhyNot: Db.guard の外に置くのは、一番内側の handler の直下に try を置く決まりのため（handler が try の内側に入ると例外が素通りする）。
    /// runCmsErr の内側に置くのは、業務エラーで抜けた後も数えた値を Ref から読めるため。
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
    /// `withTx` に加えて、借り待ち（db.pool.*。待ちがある時だけ）、再試行した回数（db.retries。1 以上の時だけ）、
    /// 出した SQL の数と Tx の数（db.statements / db.transactions）を observe でリクエストの行に戻す。
    /// Runner を通らない道（304 の道、DB が落ちている時の 503）でも、リクエストの行に同じキーが揃う。
    ///
    pub def withTxObserved(pool: Pool, scope: Option[ProjectId], observe: Log.Fields -> Unit \ IO, thunk: Unit -> a \ ef): Result[DbFailure, a] \ (ef - Db) + IO =
        let counter = Ref.fresh(Static, 0);
        let statements = Ref.fresh(Static, 0);
        // 借りる前に、待ちが出ていればプールの数字をリクエストの行に
        notePool(observe, pool);
        // retry → RLS の印付き Tx → SQL の数え → JVM の例外の catch（Db.guard）→ 本体、の順に包む（業務エラーと Session は無し）
        let outcome = retryWith(counter, () -> TenantTx.withLazyTx(pool, scope, () -> counting(statements, () -> Db.guard(thunk))));
        // 再試行の回数と SQL の数をリクエストの行に
        noteRetries(observe, Ref.get(counter));
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

    // ---- 読むだけの文書の 1 リクエスト 1 Tx（RequestTx） ----

    ///
    /// リクエストの Tx の持ち物を作る。接続はまだ借りない（最初の SQL で `openConnection` が借りる）。
    ///
    pub def openRequestTx(pool: Pool, scope: Option[ProjectId], actor: Actor): RequestTx.Handle \ IO =
        { openConnection = () -> openConnection(pool, scope, actor),
          state = Ref.fresh(Static, RequestTx.State.Idle),
          openedAt = Ref.fresh(Static, None) }

    ///
    /// 接続を借りて Tx を開く。borrow → BEGIN → SET TRANSACTION（READ ONLY, REPEATABLE READ。最初の文なので snapshot はここ）→ RLS の印。
    /// 一時的な失敗の再試行はここ（最初の SQL の前）だけ。借りた後に失敗したら ROLLBACK して返してから投げる。
    ///
    /// WhyNot: `Pool.withLazyTxResultAfterBegin` の onBegin を使わないのは、SET TRANSACTION を印より前（Tx の最初の文）に流す必要があり、
    /// onBegin は SqlRead の handler 越しなので文の順を握れないため。Tx.begin は setAutoCommit(false) だけで文は出ない。
    ///
    /// WhyNot: 印（set_config）を READ ONLY の後に置くのは、set_config は READ ONLY でも通り、印の前に snapshot を取っても RLS は
    /// 文ごとに評価されるので結果が変わらないため。
    ///
    def openConnection(pool: Pool, scope: Option[ProjectId], actor: Actor): Connection \ {IO, TransientDbErr, DbErr} =
        match retrying(() -> beginReadOnly(pool, scope, actor)) {
            case Ok(conn)     => conn
            case Err(failure) => raiseFailure(failure)
        }

    /// borrow から印まで 1 回分。借りた後の失敗は ROLLBACK と close をしてから上へ。
    def beginReadOnly(pool: Pool, scope: Option[ProjectId], actor: Actor): Connection \ {IO, TransientDbErr, DbErr} =
        let conn = Pool.borrow(pool);
        match DbError.runWithFailure(() -> {
            Tx.begin(conn);
            discard Jdbc.executeStatement(conn, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", Nil);
            Jdbc.runWithConnection(conn, () -> TenantTx.stampTx(scope, actor))
        }) {
            case Ok(())       => conn
            case Err(failure) => { Tx.rollback(conn); Jdbc.close(conn); raiseFailure(failure) }
        }

    /// 値にした失敗を元の effect に戻す。
    def raiseFailure(failure: DbFailure): a \ {TransientDbErr, DbErr} = match failure {
        case DbError.Failure.Transient(transient) => TransientDbErr.raiseTransient(transient)
        case DbError.Failure.Permanent(kind)      => DbError.raise(kind)
    }

    ///
    /// 今の接続。Idle なら借りて開き、Open に進める。Broken からは呼ばれない（canRun が止める）。
    ///
    /// WhyNot: Broken(Some) の接続を返さないのは、失敗した Tx（aborted）で SQL を出しても 25P02 で失敗するだけで、
    /// リクエストの行の失敗の種類が最初の物から書き換わるため。
    ///
    def currentConnection(handle: RequestTx.Handle): Connection \ {IO, TransientDbErr, DbErr} = match Ref.get(handle#state) {
        case RequestTx.State.Open(conn)            => conn
        case RequestTx.State.Broken(_, failure)    => raiseFailure(failure)
        case RequestTx.State.Idle                  => {
            let conn = (handle#openConnection)();
            Ref.put(RequestTx.State.Open(conn), handle#state);
            Ref.put(Some(System.currentTimeMillis()), handle#openedAt);
            conn
        }
    }

    ///
    /// 最初の SQL で借りる SqlRead / SqlWrite の handler。リクエストの Tx の接続で流す。
    ///
    /// WhyNot: `Jdbc.runWithConnection` を使わないのは、接続を先に受ける形で、SQL を出さないフィールドまで借りてしまうため。
    /// op の中で `currentConnection` を呼ぶ同じ形を手で書く。
    ///
    def onRequestTx(handle: RequestTx.Handle, thunk: Unit -> a \ ef): a \ (ef - {SqlRead, SqlWrite}) + IO =
        run thunk() with handler SqlRead {
            def fetch(sql, params, resume) = resume(DbError.runWithKind(() -> Jdbc.fetchRows(currentConnection(handle), sql, params)))
        } with handler SqlWrite {
            def execute(sql, params, resume)          = resume(DbError.runWithKind(() -> Jdbc.executeStatement(currentConnection(handle), sql, params)))
            def executeReturning(sql, params, resume) = resume(DbError.runWithKind(() -> Jdbc.fetchRows(currentConnection(handle), sql, params)))
        }

    ///
    /// 1 フィールドぶんをリクエストの Tx で走らせる。Broken なら走らせず Skipped。
    /// handler の順は transact と同じ（遅延 SQL → CmsErr → Session → SQL の数え → Db.guard → 本体）で、再試行はしない（借りる時だけ）。
    /// 結果で状態を進め（DB の失敗なら Broken）、SQL の数を observe でリクエストの行に戻す（Tx の数は閉じる時に 1 回）。
    ///
    /// WhyNot: 一時的な失敗をフィールド単位で再試行しないのは、同じ Tx の中で呼び直しても aborted のままで、
    /// 別の接続で呼び直すと前のフィールドと snapshot が変わるため。
    ///
    pub def transactShared(handle: RequestTx.Handle, observe: Log.Fields -> Unit \ IO, actor: Actor, thunk: Unit -> a \ ef): RequestTx.Attempt[a] \ (ef - {Db, CmsErr, Session}) + IO =
        match RequestTx.brokenBy(Ref.get(handle#state)) {
            case Some(failure) => RequestTx.Attempt.Skipped(failure)
            case None          => {
                let statements = Ref.fresh(Static, 0);
                let outcome = DbError.runWithFailure(() ->
                    onRequestTx(handle, () ->
                        runCmsErr(() -> Session.runWith(actor, () -> counting(statements, () -> Db.guard(thunk))))));
                Ref.put(RequestTx.afterField(Ref.get(handle#state), outcome), handle#state);
                observe(Log.Fields.empty() |> Log.Fields.int("db.statements", Int32.toInt64(Ref.get(statements))));
                RequestTx.Attempt.Ran(toApplicationResult(outcome))
            }
        }

    ///
    /// transactShared の結果を GraphQL のフィールドの結果に。走った物は `toFieldResult`（DB の失敗は Error の行）、
    /// Broken の後に飛ばした物は Error の行を出さず INTERNAL の値だけ（最初の失敗が行になっている）。
    ///
    pub def toSharedFieldResult(requestId: Option[String], attempt: RequestTx.Attempt[Result[FieldError, a]]): Result[FieldError, a] \ Log = match attempt {
        case RequestTx.Attempt.Ran(outcome)     => toFieldResult(requestId, outcome)
        case RequestTx.Attempt.Skipped(failure) => Err(GraphqlErrors.fromApplicationFailure(requestId, ApplicationFailure.Infrastructure(failure)))
    }

    ///
    /// リクエストの Tx を閉じる。Open は COMMIT、接続を持つ Broken は ROLLBACK、どちらも接続を返す（返った時刻は PoolActivity が記録する）。
    /// COMMIT の失敗は値で返す（読んだ値は有効なので応答は変えない。Tx.commit は失敗時に ROLLBACK 済み）。
    ///
    /// WhyNot: ROLLBACK と close を別の try にしないのは、Tx.rollback が失敗を握り潰して close まで届くため。
    ///
    pub def closeRequestTx(handle: RequestTx.Handle): RequestTx.Closed \ IO =
        let state = Ref.get(handle#state);
        let commitFailure = match state {
            case RequestTx.State.Open(conn)            => { let committed = DbError.runWithFailure(() -> Tx.commit(conn)); Jdbc.close(conn); failureOf(committed) }
            case RequestTx.State.Broken(Some(conn), _) => { Tx.rollback(conn); Jdbc.close(conn); None }
            case _                                     => None
        };
        let now = System.currentTimeMillis();
        { outcome = RequestTx.outcomeOf(state),
          transactions = RequestTx.transactionsOf(state),
          brokenBy = RequestTx.brokenBy(state),
          commitFailure = commitFailure,
          heldMs = Ref.get(handle#openedAt) |> Option.map(openedAt -> now - openedAt) }

    ///
    /// リクエストの Tx を開いて body を走らせ、body が JVM の例外で抜けても必ず閉じてから再送出する。
    /// 閉じた結果（db.transactions / db.tx.outcome / db.tx.held_ms、Broken の error.kind）を observe でリクエストの行に戻し、COMMIT の失敗は Error の行にする。
    ///
    /// WhyNot: 例外の腕で閉じないのは、catch の腕に effect の op を書けないため。例外を値にして閉じてから投げ直す。
    ///
    pub def withRequestTx(pool: Pool, scope: Option[ProjectId], actor: Actor, observe: Log.Fields -> Unit \ IO, body: RequestTx.Handle -> a \ IO): a \ {IO, Log} =
        withRequestTxHandle(openRequestTx(pool, scope, actor), observe, body)

    ///
    /// `withRequestTx` の Handle を受ける形（DB 無しのテストがフェイクの Handle で閉じる道を見る）。
    ///
    pub def withRequestTxHandle(handle: RequestTx.Handle, observe: Log.Fields -> Unit \ IO, body: RequestTx.Handle -> a \ IO): a \ {IO, Log} =
        let outcome = attemptBody(handle, body);
        let closed = closeRequestTx(handle);
        observe(closedFields(closed));
        match closed#commitFailure {
            case Some(failure) => Log.Fields.empty() |> LogFields.applicationFailure(ApplicationFailure.Infrastructure(failure)) |> Log.error("request transaction commit failed")
            case None          => ()
        };
        match outcome {
            case Ok(value)  => value
            case Err(error) => throw error
        }

    /// COMMIT の結果の失敗だけ。
    def failureOf(committed: Result[DbFailure, Unit]): Option[DbFailure] = match committed {
        case Ok(())       => None
        case Err(failure) => Some(failure)
    }

    /// body を走らせ、Throwable を値にする。
    def attemptBody(handle: RequestTx.Handle, body: RequestTx.Handle -> a \ IO): Result[Throwable, a] \ IO =
        try {
            Ok(body(handle))
        } catch {
            case error: Throwable => Err(error)
        }

    /// 閉じた結果のリクエストの行の属性。error.kind は Broken にした最初の失敗の種類（あれば）。
    def closedFields(closed: RequestTx.Closed): Log.Fields =
        Log.Fields.empty()
            |> Log.Fields.int("db.transactions", closed#transactions)
            |> Log.Fields.str("db.tx.outcome", RequestTx.outcomeText(closed#outcome))
            |> Log.Fields.opt("error.kind", closed#brokenBy |> Option.flatMap(LogFields.dbErrorKind))
            |> fields -> match closed#heldMs {
                case Some(ms) => fields |> Log.Fields.int("db.tx.held_ms", ms)
                case None     => fields
            }

}
