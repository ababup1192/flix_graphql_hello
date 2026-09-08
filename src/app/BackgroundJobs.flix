///
/// プロセス内のバックグラウンドワーカー。予約公開と Webhook の tick を定期的に回し、実行中に落ちた行の回復と古い記録の掃除もする。
/// 同じ tick は外部トリガー（POST /jobs/tick）からも呼べる。どちらから呼ばれても DB のロック（SKIP LOCKED）で二重にはならない。
/// 停止（SIGTERM）は shutdown hook で受け、新しい仕事を拾うのをやめて実行中の 1 周が終わるまで待つ。
/// 自己回復の見張り（watchForever）は仕事の周とは別のスレッドで、自分の周期で回る。
///
mod BackgroundJobs {

    import java.lang.System
    import java.lang.Thread
    import java.lang.Throwable

    /// tick の間隔（ミリ秒）。
    pub def intervalMs(): Int64 = 2000i64

    /// 自己回復の見張りの間隔（ミリ秒）。
    pub def healIntervalMs(): Int64 = 2000i64

    /// 実行中のまま残った行を戻すまでの分。
    def staleMinutes(): Int64 = 10i64

    /// 終わった記録を残す日数。
    def keepDays(): Int64 = 30i64


    ///
    /// ワーカーの状態。/health と停止処理が読む。
    ///
    /// - lastTick: 最後に 1 周が終わった時刻（UNIX ミリ秒）
    /// - lastWatch: 見張りのスレッドが最後に 1 周を回した時刻（UNIX ミリ秒）
    /// - stopping: 停止が始まった。新しい周を始めない
    /// - inTick: 1 周の途中
    /// - drainMs: 停止時に実行中の 1 周を待つ上限（ミリ秒。CMS_JOBS_DRAIN_SECONDS）
    ///
    /// WhyNot: lastWatch を /health からの step で更新しないのは、この値が指すのは「見張りのスレッドが生きているか」で、
    /// リクエストのスレッドが進めた事を混ぜると、死んだスレッドを生きていると読ませてしまうため。
    ///
    pub type alias State = { lastTick = Ref[Option[Int64], Static], lastWatch = Ref[Option[Int64], Static], stopping = Ref[Bool, Static], inTick = Ref[Bool, Static], drainMs = Int64 }

    pub def createState(drainSeconds: Int64): State \ IO =
        { lastTick = Ref.fresh(Static, None), lastWatch = Ref.fresh(Static, None), stopping = Ref.fresh(Static, false), inTick = Ref.fresh(Static, false), drainMs = drainSeconds * 1000i64 }

    ///
    /// 止まらずに回す。失敗はログに出して次の周へ。停止が始まったら抜ける。周ごとに Log を sink で入れ直す（spawn の中なので Main の handler は届かない）。
    ///
    pub def runForever(pool: Pool, state: State, sink: Log.Sink): Unit \ IO =
        if (Ref.get(state#stopping)) Log.runWith(sink, () -> Log.info("jobs stopping", Log.Fields.empty()))
        else {
            round(pool, state, sink);
            Thread.sleep(intervalMs());
            runForever(pool, state, sink)
        }

    ///
    /// 自己回復の見張りだけを healIntervalMs ごとに回す。停止が始まったら抜ける。
    ///
    /// WhyNot: 仕事の周（runForever）に相乗りしないのは、DB が止まっている間は 1 周が tick の待ちぶんだけ伸び、
    /// 観測の粒度が設定より粗くなるため（実験 2 回目で 2 秒のはずが約 17 秒だった）。見張りは別スレッドで自分の周期を持つ。
    ///
    pub def watchForever(pool: Pool, state: State, heal: Option[SelfHeal.Watch], sink: Log.Sink): Unit \ IO =
        if (Ref.get(state#stopping)) ()
        else {
            let startedAt = System.currentTimeMillis();
            Ref.put(Some(startedAt), state#lastWatch);
            guardedWatch(sink, () -> healCheck(pool, state, heal, Result.isOk(Health.ping(pool))));
            Thread.sleep(nextWaitMs(healIntervalMs(), System.currentTimeMillis() - startedAt));
            watchForever(pool, state, heal, sink)
        }

    ///
    /// 見張りの 1 周を JVM の例外から守る。Throwable が飛んだら Error の行にして次の周へ進める。
    /// JVM 自体が壊れている物（OutOfMemoryError）はログした上で再送出する。
    ///
    /// WhyNot: 見張りに網を掛けないままにしないのは、ping や Pool.stats が投げると見張りのスレッドだけが黙って死に、
    /// /health が `watch stalled` を返すまで 30 秒は誰にも分からないため。
    ///
    pub def guardedWatch(sink: Log.Sink, thunk: Unit -> Unit \ ef): Unit \ (ef - Log) + IO =
        match attempt(() -> Log.runWith(sink, thunk)) {
            case Ok(())           => ()
            case Err(Ok(message)) => Log.runWith(sink, () -> Log.Fields.empty() |> Log.Fields.str("error.message", message) |> Log.error("watch failed"))
            case Err(Err(fatal))  => { Log.runWith(sink, () -> Log.Fields.empty() |> Log.exception(fatal) |> Log.fatal("watch fatal")); throw fatal }
        }

    ///
    /// 次の周まで待つミリ秒。1 周に掛かった時間を間隔から引く。間隔を超えていたら 0（待たずに次へ）。
    ///
    pub def nextWaitMs(intervalMs: Int64, elapsedMs: Int64): Int64 =
        if (elapsedMs >= intervalMs) 0i64 else intervalMs - elapsedMs

    ///
    /// プールが壊れたまま戻らないかを見張り、決まったら自分で終わる。CMS_SELF_HEAL=off なら見張らない。
    ///
    /// 見張りのスレッドと /health の 2 つの経路から呼ぶ。Exit が決まったら、どちらから来ても同じ drain と exit 3 の道に入る（印で 1 回だけ）。
    ///
    /// WhyNot: 見張りのスレッドだけが判断する形にしないのは、そのスレッドが OOM で死ぬと自己回復が永久に無効になるため。
    /// リクエストのスレッドは OOM の後も生きている側で、Docker の HEALTHCHECK が /health を叩く限り判断が進む。
    ///
    /// WhyNot: 外部トリガー（POST /jobs/tick）の tick に入れないのは、仕事を回すだけの口が理由でプロセスが終わると、
    /// 呼んだ側には接続断としか見えないため。/health は死活を答える口なので、そこで終わりが決まるのは筋が通る。
    ///
    /// WhyNot: ここで ping を打たないのは、/health が checkDb でも同じ ping を打つため。呼ぶ側が 1 回打った結果を渡す。
    ///
    pub def healCheck(pool: Pool, state: State, heal: Option[SelfHeal.Watch], pingOk: Bool): Unit \ {IO, Log} = match heal {
        case None        => ()
        case Some(watch) => match SelfHeal.step(watch, SelfHeal.observe(watch, pool, pingOk)) {
            case SelfHeal.Decision.Keep         => ()
            case SelfHeal.Decision.Exit(reason) => if (SelfHeal.claimExit(watch)) exitForHeal(pool, state, reason) else ()
        }
    }

    ///
    /// 停止と同じ drain をしてから終了コード 3 で終わる。コンテナ（restart)が同じ物を組み直す。
    ///
    /// WhyNot: 終了コードを 0 にしないのは、正常な停止（SIGTERM）と区別が付かなくなるため。
    /// 3 は `-XX:+ExitOnOutOfMemoryError` の JVM が使う番号と同じで、どちらも「壊れたので落ちた」を意味する。
    ///
    def exitForHeal(pool: Pool, state: State, reason: String): Unit \ {IO, Log} =
        let stats = Pool.stats(pool);
        Log.Fields.empty()
            |> Log.Fields.str("reason", reason)
            |> Log.Fields.int("db.pool.active", Int32.toInt64(stats#active))
            |> Log.Fields.int("db.pool.idle", Int32.toInt64(stats#idle))
            |> Log.Fields.int("db.pool.waiting", Int32.toInt64(stats#waiting))
            |> Log.Fields.int("db.pool.total", Int32.toInt64(stats#total))
            |> Log.Fields.int("db.pool.max", Int32.toInt64(stats#max))
            |> Log.error("self-heal: exiting");
        shutdown(state);
        System.exit(3)

    /// 1 周。失敗は Error の行にする（1 周に 1 行ずつ）。
    def round(pool: Pool, state: State, sink: Log.Sink): Unit \ IO =
        let messages = guarded(sink, () -> tick(pool, state));
        Log.runWith(sink, () -> List.forEach(message -> Log.Fields.empty() |> Log.Fields.str("error.message", message) |> Log.error("jobs tick failed"), messages));
        Ref.put(false, state#inTick)

    ///
    /// 1 周を JVM の例外から守る。Throwable が飛んだら失敗の説明にして返し、次の周へ進める。
    /// JVM 自体が壊れている物（OutOfMemoryError）はログした上で再送出する。Log は sink で try の内側に入れる。
    ///
    /// WhyNot: tick の中の DbRunner に任せないのは、Tx の外（Scheduler / Dispatcher の Java interop や、リゾルバと同じ VerifyError）で
    /// 飛んだ Error は Exception の catch を素通りし、ワーカーのスレッドだけが黙って死んでプロセスは生き残るため。
    ///
    /// WhyNot: Log の handler を try の外（runForever）に置いたまま Log を effect で受けないのは、tick の中の run
    /// （Net.Http.runWithIO など）から Log の op が try を越えて外の handler へ出ると、その run の中で飛んだ例外を
    /// この catch が拾えなくなるため（2026-09-08 に実測。test/app/TestJvmCatchNesting）。handler が try の内側なら拾える。
    ///
    /// WhyNot: catch の中で Log を呼ばないのは、effect の操作を catch の腕に書くと JVM の VerifyError になるため（2026-09-08 に実測）。
    /// catch は値（Result）を返すだけにして、ログと再送出は外でする。
    ///
    pub def guarded(sink: Log.Sink, thunk: Unit -> List[String] \ ef): List[String] \ (ef - Log) + IO =
        match attempt(() -> Log.runWith(sink, thunk)) {
            case Ok(messages)     => messages
            case Err(Ok(message)) => List#{"1 周の途中で例外: ${message}"}
            case Err(Err(fatal))  => { Log.runWith(sink, () -> Log.Fields.empty() |> Log.exception(fatal) |> Log.fatal("jobs fatal")); throw fatal }
        }

    ///
    /// 仕事の 1 部分（予約公開・Webhook）を JVM の例外から守る。飛んだら label 付きの失敗の説明にして、残りの部分へ進める。
    /// JVM 自体が壊れている物（OutOfMemoryError）はそのまま再送出する（外の guarded がログする）。
    ///
    /// WhyNot: 外の guarded だけに任せないのは、外部トリガー（POST /jobs/tick）はリクエストの Log の handler の下で tick を呼び、
    /// そこでは handler を try の内側に入れられない（リクエストの span を失う）ため。部分ごとの網は handler の入れ子に
    /// 依らず効く（Log の op が越えるのは try の直下で、間に run が無い）。
    ///
    pub def guardedPart(label: String, thunk: Unit -> Result[String, Int32] \ ef): Result[String, Int32] \ ef + IO =
        match attempt(thunk) {
            case Ok(outcome)      => outcome
            case Err(Ok(message)) => Err("${label}の途中で例外: ${message}")
            case Err(Err(fatal))  => throw fatal
        }

    /// thunk を走らせ、Throwable を値にする。致命的な物（OutOfMemoryError）は Err(Err)、それ以外は Err(Ok(説明))。
    def attempt(thunk: Unit -> a \ ef): Result[Result[Throwable, String], a] \ ef + IO =
        try {
            Ok(thunk())
        } catch {
            case e: Throwable =>
                if (JvmErrors.isFatal(e)) Err(Err(e))
                else Err(Ok(JvmErrors.describe(e)))
        }

    ///
    /// 仕事だけの停止。`shutting down` を 1 行出してから新しい周を止め、実行中の 1 周が終わるまで（上限あり）待つ。
    /// 行を先に出すのは、止めた事が行から分かるようにするため（`jobs stopping` は周の頭でしか判定せず、待っている間は出ない）。
    /// SIGTERM の停止は HTTP も待つので `Shutdown.stop` を使う。ここは自己回復（exit 3）の道。
    ///
    pub def shutdown(state: State): Unit \ {IO, Log} =
        Log.info("shutting down", Log.Fields.empty());
        Ref.put(true, state#stopping);
        discard drain(state, System.currentTimeMillis() + state#drainMs)

    ///
    /// 実行中の 1 周が終わるか、期限が来るまで待つ。終わっていれば true。
    ///
    /// WhyNot: 待たずに落ちても回復（claimed_at）で拾い直せるが、Webhook はその間に届いていて二重になりうる。
    /// 数秒待つだけで通常のデプロイではそれが無くなる。
    ///
    pub def drain(state: State, deadline: Int64): Bool \ {IO, Log} =
        if (not Ref.get(state#inTick)) { Log.info("jobs drained", Log.Fields.empty()); true }
        else if (System.currentTimeMillis() > deadline) { Log.warn("jobs drain timed out (claimed_at で拾い直す)", Log.Fields.empty()); false }
        else { Thread.sleep(100i64); drain(state, deadline) }

    ///
    /// 回復 → 予約公開 → Webhook の順に 1 周する。失敗した所の説明を返す（空なら全部通った）。停止中なら何もしない。
    ///
    pub def tick(pool: Pool, state: State): List[String] \ {IO, Log} =
        if (Ref.get(state#stopping)) Nil
        else {
            Ref.put(true, state#inTick);
            let recovered = DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> {
                    discard SchedulesQueries.recoverStuckSchedules(staleMinutes());
                    discard WebhooksQueries.recoverStuckDeliveries(staleMinutes());
                    discard SchedulesQueries.purgeOldSchedules(keepDays());
                    discard WebhooksQueries.purgeOldDeliveries(keepDays())
                })) |> Result.mapErr(failure -> "回復と掃除ができません: ${failure}");
            let scheduled = guardedPart("予約公開", () -> Scheduler.tick(pool));
            let delivered = Net.Http.runWithIO(() -> guardedPart("Webhook", () -> WebhookDispatcher.tick(pool)));
            Ref.put(Some(System.currentTimeMillis()), state#lastTick);
            Ref.put(false, state#inTick);
            List#{ recovered |> Result.map(_ -> ()), scheduled |> Result.map(_ -> ()), delivered |> Result.map(_ -> ()) }
                |> List.filterMap(outcome -> match outcome { case Ok(()) => None case Err(message) => Some(message) })
        }

    ///
    /// /health 用のまとめ。最終実行時刻と、待ち・失敗の件数。
    ///
    pub type alias Summary = { lastTickAt = Option[String], pendingSchedules = Int64, failedSchedules = Int64, pendingDeliveries = Int64, failedDeliveries = Int64 }

    pub def summary(pool: Pool, state: State): Summary \ IO =
        let counts = DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> (SchedulesQueries.countSchedules(), WebhooksQueries.countDeliveries())));
        let lastTickAt = Ref.get(state#lastTick) |> Option.map(millis -> Timestamp.toIso8601(Timestamp.fromEpochMillis(millis)));
        match counts {
            case Ok((Some(schedules), Some(deliveries))) =>
                { lastTickAt = lastTickAt, pendingSchedules = schedules#pending |> Option.getWithDefault(0i64), failedSchedules = schedules#failed |> Option.getWithDefault(0i64),
                  pendingDeliveries = deliveries#pending |> Option.getWithDefault(0i64), failedDeliveries = deliveries#failed |> Option.getWithDefault(0i64) }
            case _ => { lastTickAt = lastTickAt, pendingSchedules = -1i64, failedSchedules = -1i64, pendingDeliveries = -1i64, failedDeliveries = -1i64 }
        }

}
