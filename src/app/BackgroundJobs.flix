///
/// プロセス内のバックグラウンドワーカー。予約公開と Webhook の tick を定期的に回し、実行中に落ちた行の回復と古い記録の掃除もする。
/// 同じ tick は外部トリガー（POST /jobs/tick）からも呼べる。どちらから呼ばれても DB のロック（SKIP LOCKED）で二重にはならない。
///
mod BackgroundJobs {

    import java.lang.System
    import java.lang.Thread

    /// tick の間隔（ミリ秒）。
    def intervalMs(): Int64 = 2000i64

    /// 実行中のまま残った行を戻すまでの分。
    def staleMinutes(): Int64 = 10i64

    /// 終わった記録を残す日数。
    def keepDays(): Int64 = 30i64

    ///
    /// 最後に tick が終わった時刻（UNIX ミリ秒）。/health に出す。
    ///
    pub type alias State = Ref[Option[Int64], Static]

    pub def createState(): State \ IO = Ref.fresh(Static, None)

    ///
    /// 止まらずに回す。失敗はログに出して次の周へ。
    ///
    pub def runForever(pool: Pool, state: State): Unit \ IO =
        tick(pool, state) |> List.forEach(message -> println("jobs: ${message}"));
        Thread.sleep(intervalMs());
        runForever(pool, state)

    ///
    /// 回復 → 予約公開 → Webhook の順に 1 周する。失敗した所の説明を返す（空なら全部通った）。
    ///
    pub def tick(pool: Pool, state: State): List[String] \ IO =
        let recovered = DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> {
                discard SchedulesQueries.recoverStuckSchedules(staleMinutes());
                discard WebhooksQueries.recoverStuckDeliveries(staleMinutes());
                discard SchedulesQueries.purgeOldSchedules(keepDays());
                discard WebhooksQueries.purgeOldDeliveries(keepDays())
            })) |> Result.mapErr(failure -> "回復と掃除ができません: ${failure}");
        let scheduled = Scheduler.tick(pool);
        let delivered = Net.Http.runWithIO(() -> WebhookDispatcher.tick(pool));
        Ref.put(Some(System.currentTimeMillis()), state);
        List#{ recovered |> Result.map(_ -> ()), scheduled |> Result.map(_ -> ()), delivered |> Result.map(_ -> ()) }
            |> List.filterMap(outcome -> match outcome { case Ok(()) => None case Err(message) => Some(message) })

    ///
    /// /health 用。最後の tick の時刻（ISO 8601）。まだ 1 度も回っていなければ None。
    ///
    pub def lastTickAt(state: State): Option[String] \ IO =
        Ref.get(state) |> Option.map(millis -> Timestamp.toIso8601(Timestamp.fromEpochMillis(millis)))

}
