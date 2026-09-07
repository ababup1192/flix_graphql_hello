///
/// プロセス内のバックグラウンドワーカー。予約公開と Webhook の tick を定期的に回し、実行中に落ちた行の回復と古い記録の掃除もする。
/// 同じ tick は外部トリガー（POST /jobs/tick）からも呼べる。どちらから呼ばれても DB のロック（SKIP LOCKED）で二重にはならない。
/// 停止（SIGTERM）は shutdown hook で受け、新しい仕事を拾うのをやめて実行中の 1 周が終わるまで待つ。
///
mod BackgroundJobs {

    import java.lang.System
    import java.lang.Thread
    import sun.misc.Signal
    import sun.misc.SignalHandler

    /// tick の間隔（ミリ秒）。
    def intervalMs(): Int64 = 2000i64

    /// 実行中のまま残った行を戻すまでの分。
    def staleMinutes(): Int64 = 10i64

    /// 終わった記録を残す日数。
    def keepDays(): Int64 = 30i64


    ///
    /// ワーカーの状態。/health と停止処理が読む。
    ///
    /// - lastTick: 最後に 1 周が終わった時刻（UNIX ミリ秒）
    /// - stopping: 停止が始まった。新しい周を始めない
    /// - inTick: 1 周の途中
    /// - drainMs: 停止時に実行中の 1 周を待つ上限（ミリ秒。CMS_JOBS_DRAIN_SECONDS）
    ///
    pub type alias State = { lastTick = Ref[Option[Int64], Static], stopping = Ref[Bool, Static], inTick = Ref[Bool, Static], drainMs = Int64 }

    pub def createState(drainSeconds: Int64): State \ IO =
        { lastTick = Ref.fresh(Static, None), stopping = Ref.fresh(Static, false), inTick = Ref.fresh(Static, false), drainMs = drainSeconds * 1000i64 }

    ///
    /// 止まらずに回す。失敗はログに出して次の周へ。停止が始まったら抜ける。
    ///
    pub def runForever(pool: Pool, state: State): Unit \ IO =
        if (Ref.get(state#stopping)) println("jobs: 停止します")
        else {
            tick(pool, state) |> List.forEach(message -> println("jobs: ${message}"));
            Thread.sleep(intervalMs());
            runForever(pool, state)
        }

    ///
    /// SIGTERM / SIGINT を受けたら、新しい周を始めず、実行中の 1 周が終わるまで（上限あり）待ってから終わる。
    ///
    /// WhyNot: 待たずに落ちても回復（claimed_at）で拾い直せるが、Webhook はその間に届いていて二重になりうる。
    /// 数秒待つだけで通常のデプロイではそれが無くなる。
    /// WhyNot: Runtime.addShutdownHook（Runnable）を使わないのは、Runnable の `run` が Flix の予約語で書けないため。
    ///
    pub def installShutdownHook(state: State): Unit \ IO =
        let onSignal = new SignalHandler {
            def handle(_this: SignalHandler, _signal: Signal): Unit \ IO = {
                Ref.put(true, state#stopping);
                drain(state, System.currentTimeMillis() + state#drainMs);
                System.exit(0)
            }
        };
        discard Signal.handle(new Signal("TERM"), onSignal);
        discard Signal.handle(new Signal("INT"), onSignal)

    /// 実行中の 1 周が終わるか、期限が来るまで待つ。
    def drain(state: State, deadline: Int64): Unit \ IO =
        if (not Ref.get(state#inTick)) println("jobs: 実行中の仕事はありません。終わります")
        else if (System.currentTimeMillis() > deadline) println("jobs: 実行中の仕事を待ちきれませんでした（回復で拾い直します）")
        else { Thread.sleep(100i64); drain(state, deadline) }

    ///
    /// 回復 → 予約公開 → Webhook の順に 1 周する。失敗した所の説明を返す（空なら全部通った）。停止中なら何もしない。
    ///
    pub def tick(pool: Pool, state: State): List[String] \ IO =
        if (Ref.get(state#stopping)) Nil
        else {
            Ref.put(true, state#inTick);
            let recovered = DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> {
                    discard SchedulesQueries.recoverStuckSchedules(staleMinutes());
                    discard WebhooksQueries.recoverStuckDeliveries(staleMinutes());
                    discard SchedulesQueries.purgeOldSchedules(keepDays());
                    discard WebhooksQueries.purgeOldDeliveries(keepDays())
                })) |> Result.mapErr(failure -> "回復と掃除ができません: ${failure}");
            let scheduled = Scheduler.tick(pool);
            let delivered = Net.Http.runWithIO(() -> WebhookDispatcher.tick(pool));
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

    ///
    /// 1 件の仕事の結果を 1 行 JSON で出す（Loki で数えられる形）。
    ///
    pub def logJob(kind: String, id: String, status: String, detail: String): Unit \ IO =
        println(JsonValue.toJsonString(Value.Obj(Map#{
            "job" => Value.Str(kind), "id" => Value.Str(id), "status" => Value.Str(status), "detail" => Value.Str(detail),
            "time" => Value.Str(Timestamp.toIso8601(Timestamp.fromEpochMillis(System.currentTimeMillis()))) })))

}
