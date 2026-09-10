///
/// プロセス内のバックグラウンドワーカー。予約公開と Webhook の tick を定期的に回し、実行中に落ちた行の回復と古い記録の掃除もする。
/// 同じ tick は外部トリガー（POST /jobs/tick）からも呼べる。どちらから呼ばれても DB のロック（SKIP LOCKED）で二重にはならない。
/// 停止（SIGTERM）は shutdown hook で受け、新しい仕事を拾うのをやめて実行中の 1 tickが終わるまで待つ。
/// 自己回復のwatch（watchForever）は仕事のtickとは別のスレッドで、自分の周期で回る。
///
mod BackgroundJobs {

    import java.lang.System
    import java.lang.Thread
    import java.lang.Throwable
    import java.net.http.HttpClient

    /// tick の間隔（ミリ秒）。
    pub def intervalMs(): Int64 = 2000i64

    /// 自己回復のwatchの間隔（ミリ秒）。
    pub def healIntervalMs(): Int64 = 2000i64

    /// 実行中のまま残った行を戻すまでの分。
    def staleMinutes(): Int64 = 10i64

    /// 終わった記録を残す日数。
    def keepDays(): Int64 = 30i64


    ///
    /// ワーカーの状態。/health と停止処理が読む。
    ///
    /// - lastTick: 最後に 1 tickが終わった時刻（UNIX ミリ秒）
    /// - lastSchedule / lastWebhook / lastPurge: その部分が最後に失敗せずに通った時刻（UNIX ミリ秒）
    /// - lastWatch: watchのスレッドが最後に 1 tickを回した時刻（UNIX ミリ秒）
    /// - stopping: 停止が始まった。新しいtickを始めない
    /// - inTick: 1 tickの途中
    /// - drainMs: 停止時に実行中の 1 tickを待つ上限（ミリ秒。CMS_JOBS_DRAIN_SECONDS）
    /// - purge: CDN の purge の送り先（CMS_CDN_PURGE_URL / CMS_CDN_PURGE_TOKEN）。None なら purge は積まない・送らない
    /// - http: Webhook の POST と CDN の purge に使う HttpClient（プロセスで 1 つ。OutboundHttp）
    /// - scheduler: 予約公開の tick の設定（チャンクの件数と予算。CMS_SCHEDULER_CHUNK_SIZE / CMS_SCHEDULER_TICK_BUDGET_SECONDS）
    ///
    /// WhyNot: lastWatch を /health からの step で更新しないのは、この値が指すのは「watchのスレッドが生きているか」で、
    /// リクエストのスレッドが進めた事を混ぜると、死んだスレッドを生きていると読ませてしまうため。
    ///
    pub type alias State = { lastTick = Ref[Option[Int64], Static], lastWatch = Ref[Option[Int64], Static], stopping = Ref[Bool, Static], inTick = Ref[Bool, Static], drainMs = Int64, purge = Option[PurgeTarget], http = HttpClient, scheduler = Scheduler.Config,
                             lastSchedule = Ref[Option[Int64], Static], lastWebhook = Ref[Option[Int64], Static], lastPurge = Ref[Option[Int64], Static] }

    pub def createState(drainSeconds: Int64, purge: Option[PurgeTarget], http: HttpClient, scheduler: Scheduler.Config): State \ IO =
        { lastTick = Ref.fresh(Static, None), lastWatch = Ref.fresh(Static, None), stopping = Ref.fresh(Static, false), inTick = Ref.fresh(Static, false), drainMs = drainSeconds * 1000i64, purge = purge, http = http, scheduler = scheduler,
          lastSchedule = Ref.fresh(Static, None), lastWebhook = Ref.fresh(Static, None), lastPurge = Ref.fresh(Static, None) }

    ///
    /// 止まらずに回す。失敗はログに出して次のtickへ。停止が始まったら抜ける。tickごとに Log を sink で入れ直す（spawn の中なので Main の handler は届かない）。
    ///
    pub def runForever(pool: Pool, state: State, sink: Log.Sink): Unit \ IO =
        // 停止が始まっていれば 1 行出して抜ける（stopping フラグはラウンドの先頭でだけ見る）
        if (Ref.get(state#stopping)) Log.runWith(sink, () -> Log.info("jobs stopping", Log.Fields.empty()))
        else {
            // 1 ラウンド回して interval ぶん sleep し、次のラウンドへ
            round(pool, state, sink);
            Thread.sleep(intervalMs());
            runForever(pool, state, sink)
        }

    ///
    /// 自己回復のwatchだけを healIntervalMs ごとに回す。停止が始まったら抜ける。
    ///
    /// WhyNot: 仕事のtick（runForever）に相乗りしないのは、DB が止まっている間は 1 tickが tick の待ちぶんだけ伸び、
    /// 観測の粒度が設定より粗くなるため（実験 2 回目で 2 秒のはずが約 17 秒だった）。watchは別スレッドで自分の周期を持つ。
    ///
    pub def watchForever(pool: Pool, state: State, heal: Option[SelfHeal.Watch], sink: Log.Sink): Unit \ IO =
        if (Ref.get(state#stopping)) ()
        else {
            // ラウンドの先頭で lastWatch（heartbeat）を更新する。/health はこの古さで watch のスレッドが生きているかを見る
            let startedAt = System.currentTimeMillis();
            Ref.put(Some(startedAt), state#lastWatch);
            // プール経由で ping を 1 回打ち、その結果で自己回復の判断を 1 回進める（JVM の例外は catch で受ける）
            guardedWatch(sink, () -> healCheck(pool, state, heal, Result.isOk(Health.ping(pool))));
            // 1 ラウンドに掛かった時間を interval から引いて sleep し、次のラウンドへ
            Thread.sleep(nextWaitMs(healIntervalMs(), System.currentTimeMillis() - startedAt));
            watchForever(pool, state, heal, sink)
        }

    ///
    /// watchの 1 tickを JVM の例外から守る。Throwable が飛んだら Error の行にして次のtickへ進める。
    /// JVM 自体が壊れている物（OutOfMemoryError）は `watch fatal` を出して終了コード 3 で終わる（Shutdown.crash）。
    ///
    /// WhyNot: watchに網を掛けないままにしないのは、ping や Pool.stats が投げるとwatchのスレッドだけが黙って死に、
    /// /health が `watch stalled` を返すまで 30 秒は誰にも分からないため。
    ///
    pub def guardedWatch(sink: Log.Sink, thunk: Unit -> Unit \ ef): Unit \ (ef - Log) + IO =
        match attempt(() -> Log.runWith(sink, thunk)) {
            case Ok(())           => ()
            case Err(Ok(message)) => Log.runWith(sink, () -> Log.Fields.empty() |> Log.Fields.str("error.message", message) |> Log.error("watch failed"))
            case Err(Err(fatal))  => Shutdown.crash(sink, "watch fatal", fatal)
        }

    ///
    /// 次のtickまで待つミリ秒。1 tickに掛かった時間を間隔から引く。間隔を超えていたら 0（待たずに次へ）。
    ///
    pub def nextWaitMs(intervalMs: Int64, elapsedMs: Int64): Int64 =
        if (elapsedMs >= intervalMs) 0i64 else intervalMs - elapsedMs

    ///
    /// プールが壊れたまま戻らないかをwatch、決まったら自分で終わる。CMS_SELF_HEAL=off なら見張らない。
    ///
    /// watchのスレッドと /health の 2 つの経路から呼ぶ。Exit が決まったら、どちらから来ても同じ drain と exit 3 の道に入る（印で 1 回だけ）。
    ///
    /// WhyNot: watchのスレッドだけが判断する形にしないのは、そのスレッドが OOM で死ぬと自己回復が永久に無効になるため。
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

    ///
    /// tickが長引いたと見なす長さ（ミリ秒）。/health が止まったと見なす 30 秒の半分。
    ///
    /// WhyNot: 毎回の周を Info で出さないのは、間隔 2 秒だと 1 日 4 万行を超え、長引いた周が埋もれるため。
    /// 長引いた周だけ出せば「5 秒 → 25 秒と伸びていて、明日には 503 になる」が 503 の前に見える。
    ///
    def slowTickMs(): Int64 = 15000i64

    /// 1 tick。失敗は Error の行にする（1 tickに 1 行ずつ）。長引いた周は Warn の行を 1 つ。
    def round(pool: Pool, state: State, sink: Log.Sink): Unit \ IO =
        // tick を JVM の例外の catch の中で回し、失敗の説明を集める（かかった時間も測る）
        let startedAt = System.currentTimeMillis();
        let messages = guarded(sink, () -> tick(pool, state));
        let elapsedMs = System.currentTimeMillis() - startedAt;
        Log.runWith(sink, () -> {
            // 失敗 1 つにつき Error の行を 1 つ
            List.forEach(message -> Log.Fields.empty()
                |> Log.Fields.str("error.message", message)
                |> Log.Fields.int("job.tick.duration_ms", elapsedMs)
                |> Log.error("jobs tick failed"), messages);
            // 止まる前に気付けるよう、長引いた周だけ 1 行
            if (elapsedMs > slowTickMs())
                Log.Fields.empty() |> Log.Fields.int("job.tick.duration_ms", elapsedMs) |> Log.warn("jobs tick slow")
            else ()
        });
        // 例外で tick が途中で抜けた時も、inTick フラグを必ず下ろす
        Ref.put(false, state#inTick)

    ///
    /// 1 tickを JVM の例外から守る。Throwable が飛んだら失敗の説明にして返し、次のtickへ進める。
    /// JVM 自体が壊れている物（OutOfMemoryError）は `jobs fatal` を出して終了コード 3 で終わる（Shutdown.crash）。Log は sink で try の内側に入れる。
    ///
    /// WhyNot: tick の中の DbRunner に任せないのは、Tx の外（Scheduler / Dispatcher の Java interop や、リゾルバと同じ VerifyError）で
    /// 飛んだ Error は Exception の catch を素通りし、ワーカーのスレッドだけが黙って死んでプロセスは生き残るため。
    ///
    /// WhyNot: Log の handler を try の外（runForever）に置いたまま Log を effect で受けないのは、tick の中の run
    /// （OutboundHttp.runWith など）から Log の op が try を越えて外の handler へ出ると、その run の中で飛んだ例外を
    /// この catch が拾えなくなるため（2026-09-08 に実測。test/app/TestJvmCatchNesting）。handler が try の内側なら拾える。
    ///
    /// WhyNot: catch の中で Log を呼ばないのは、effect の操作を catch の腕に書くと JVM の VerifyError になるため（2026-09-08 に実測）。
    /// catch は値（Result）を返すだけにして、ログと再送出は外でする。
    ///
    pub def guarded(sink: Log.Sink, thunk: Unit -> List[String] \ ef): List[String] \ (ef - Log) + IO =
        match attempt(() -> Log.runWith(sink, thunk)) {
            case Ok(messages)     => messages
            case Err(Ok(message)) => List#{"tick の途中で例外: ${message}"}
            case Err(Err(fatal))  => { Shutdown.crash(sink, "jobs fatal", fatal); Nil }
        }

    ///
    /// 仕事の 1 部分（予約公開・Webhook）を JVM の例外から守る。飛んだら label 付きの失敗の説明にして、残りの部分へ進める。
    /// JVM 自体が壊れている物（OutOfMemoryError）はそのまま再送出する（外の guarded が終了コード 3 で終わる）。
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
    /// 仕事だけの停止。`shutting down` を 1 行出してから新しいtickを止め、実行中の 1 tickが終わるまで（上限あり）待つ。
    /// 行を先に出すのは、止めた事が行から分かるようにするため（`jobs stopping` はtickの頭でしか判定せず、待っている間は出ない）。
    /// SIGTERM の停止は HTTP も待つので `Shutdown.stop` を使う。ここは自己回復（exit 3）の道。
    ///
    pub def shutdown(state: State): Unit \ {IO, Log} =
        Log.info("shutting down", Log.Fields.empty());
        Ref.put(true, state#stopping);
        discard drain(state, System.currentTimeMillis() + state#drainMs)

    ///
    /// 実行中の 1 tickが終わるか、期限が来るまで待つ。終わっていれば true。
    ///
    /// WhyNot: 待たずに落ちても回復（claimed_at）で拾い直せるが、Webhook はその間に届いていて二重になりうる。
    /// 数秒待つだけで通常のデプロイではそれが無くなる。
    ///
    pub def drain(state: State, deadline: Int64): Bool \ {IO, Log} =
        if (not Ref.get(state#inTick)) { Log.info("jobs drained", Log.Fields.empty()); true }
        else if (System.currentTimeMillis() > deadline) { Log.warn("jobs drain timed out (claimed_at で拾い直す)", Log.Fields.empty()); false }
        else { Thread.sleep(100i64); drain(state, deadline) }

    ///
    /// 回復 → 予約公開 → Webhook → CDN の purge の順に 1 tickする。失敗した所の説明を返す（空なら全部通った）。停止中なら何もしない。
    /// purge は送り先がある時だけ: 版が進んだプロジェクトの分を積んでから送る（予約公開が進めた版も同じ tick で拾う）。
    ///
    pub def tick(pool: Pool, state: State): List[String] \ {IO, Log} =
        if (Ref.get(state#stopping)) Nil
        else {
            // inTick フラグを立てる（停止の drain が待つ対象）
            Ref.put(true, state#inTick);
            // 回復と掃除: 実行中のまま残った行を戻し、古い記録を消す（プロジェクトを跨ぐので RLS の印は無し）
            let recovered = DbRunner.withTx(pool, None, () -> {
                    discard SchedulesQueries.recoverStuckSchedules(staleMinutes());
                    discard WebhooksQueries.recoverStuckDeliveries(staleMinutes());
                    discard CdnPurgesQueries.recoverStuckPurges(staleMinutes());
                    discard SchedulesQueries.purgeOldSchedules(keepDays());
                    discard WebhooksQueries.purgeOldDeliveries(keepDays());
                    discard CdnPurgesQueries.purgeOldPurges(keepDays())
                }) |> Result.mapErr(failure -> "回復と掃除ができません: ${failure}");
            // 予約公開と Webhook の配信。部分ごとに JVM の例外を catch し、片方が落ちても残りは進める
            let scheduled = guardedPart("予約公開", () -> Scheduler.tickWith(state#scheduler, pool));
            let delivered = OutboundHttp.runWith(state#http, () -> guardedPart("Webhook", () -> WebhookDispatcher.tick(pool)));
            let purged = purgeTick(pool, state);
            // 部分ごとの最終成功時刻と lastTick（heartbeat）を更新し、inTick フラグを下ろす
            let at = System.currentTimeMillis();
            markPart(state#lastSchedule, at, scheduled);
            markPart(state#lastWebhook, at, delivered);
            markPart(state#lastPurge, at, purged);
            Ref.put(Some(at), state#lastTick);
            Ref.put(false, state#inTick);
            // 失敗した部分の説明だけを集める
            List#{ recovered |> Result.map(_ -> ()), scheduled |> Result.map(_ -> ()), delivered |> Result.map(_ -> ()), purged |> Result.map(_ -> ()) }
                |> List.filterMap(outcome -> match outcome { case Ok(()) => None case Err(message) => Some(message) })
        }

    ///
    /// 部分が通った（Ok）ときだけ、その部分の最終成功時刻を at にする。失敗なら据え置き（時刻が古いままになる）。
    ///
    /// WhyNot: 失敗した時に時刻を残さないのは、この値で見たいのが「その部分が例外で死んでいないか」だけのため。
    /// 受け手が 500 を返し続けても Webhook の tick は Ok を返す（再試行に積むのが正しい振る舞い）ので、
    /// 捌けているかは Summary の overdue で見る。
    ///
    pub def markPart(cell: Ref[Option[Int64], Static], at: Int64, outcome: Result[String, Int32]): Unit \ IO =
        match outcome {
            case Ok(_)  => Ref.put(Some(at), cell)
            case Err(_) => ()
        }

    ///
    /// CDN の purge の部分。送り先が無ければ何もしない。積む → 送る。
    ///
    def purgeTick(pool: Pool, state: State): Result[String, Int32] \ {IO, Log} = match state#purge {
        case None         => Ok(0)
        case Some(target) =>
            guardedPart("CDN purge", () -> CdnPurge.enqueue(pool))
                |> Result.flatMap(_ -> OutboundHttp.runWith(state#http, () -> guardedPart("CDN purge", () -> CdnPurge.tick(pool, target))))
    }

    ///
    /// /health 用のまとめ。最終実行時刻と、待ち・失敗・期限を過ぎた件数。
    ///
    /// WhyNot: overdue を pending と別に持つのは、pending が未来の予約と再試行待ちを含み、
    /// 溜まっている事が異常を意味しないため。捌けていないかは overdue でしか分からない。
    ///
    pub type alias Summary = { lastTickAt = Option[String], pendingSchedules = Int64, failedSchedules = Int64, pendingDeliveries = Int64, failedDeliveries = Int64,
                               overdueSchedules = Int64, overdueDeliveries = Int64 }

    ///
    /// ワーカーのまとめ。dbReachable（/health の ping の結果）が false なら件数の SQL を出さず -1 にする。
    ///
    /// WhyNot: DB に届かない時も件数を引きに行かないのは、withTx の再試行（借り待ち 2 秒 × 3）で /health が ping の分に加えて
    /// 6 秒以上返らなくなるため（2026-09-08 の実機 E2E で 8.4 秒。README は 2 秒 + 新しい接続 1 本と書いている）。ping が落ちた直後に
    /// 件数だけ引けても意味が無い。
    ///
    pub def summary(pool: Pool, state: State, dbReachable: Bool): Summary \ IO =
        let counts =
            if (dbReachable) DbRunner.withTx(pool, None, () -> (SchedulesQueries.countSchedules(), WebhooksQueries.countDeliveries())) |> Result.toOption
            else None;
        summaryOf(Ref.get(state#lastTick), counts)

    ///
    /// 件数の行（予約と配信）を Summary に。無ければ（数えられなかった・数えなかった）件数は -1。
    ///
    pub def summaryOf(lastTick: Option[Int64], counts: Option[(Option[SchedulesQueries.CountSchedulesRow], Option[WebhooksQueries.CountDeliveriesRow])]): Summary =
        let lastTickAt = lastTick |> Option.map(millis -> Timestamp.toIso8601(Timestamp.fromEpochMillis(millis)));
        match counts {
            case Some((Some(schedules), Some(deliveries))) =>
                { lastTickAt = lastTickAt, pendingSchedules = schedules#pending |> Option.getWithDefault(0i64), failedSchedules = schedules#failed |> Option.getWithDefault(0i64),
                  pendingDeliveries = deliveries#pending |> Option.getWithDefault(0i64), failedDeliveries = deliveries#failed |> Option.getWithDefault(0i64),
                  overdueSchedules = schedules#overdue |> Option.getWithDefault(0i64), overdueDeliveries = deliveries#overdue |> Option.getWithDefault(0i64) }
            case _ => { lastTickAt = lastTickAt, pendingSchedules = -1i64, failedSchedules = -1i64, pendingDeliveries = -1i64, failedDeliveries = -1i64,
                        overdueSchedules = -1i64, overdueDeliveries = -1i64 }
        }

}
