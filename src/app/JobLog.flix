///
/// バックグラウンドの仕事 1 件の結果を 1 行 JSON で出す（Loki で数えられる形）。Scheduler と WebhookDispatcher が使う。
///
mod JobLog {

    import java.lang.System

    /// 仕事の種類。
    pub enum JobKind with Eq, ToString {
        case Schedule
        case Webhook
    }

    /// 結果。ログの "status" の値は Loki の集計が見るので固定。
    pub enum JobOutcome with Eq, ToString {
        case Done
        case Failed
        case RetryLater
        case Delivered
    }

    def kindText(kind: JobKind): String = match kind {
        case JobKind.Schedule => "schedule"
        case JobKind.Webhook  => "webhook"
    }

    def outcomeText(outcome: JobOutcome): String = match outcome {
        case JobOutcome.Done       => "done"
        case JobOutcome.Failed     => "failed"
        case JobOutcome.RetryLater => "retry"
        case JobOutcome.Delivered  => "delivered"
    }

    ///
    /// 1 行出す。
    ///
    pub def write(entry: { kind = JobKind, id = String, outcome = JobOutcome, detail = String }): Unit \ IO =
        println(JsonValue.toJsonString(Value.Obj(Map#{
            "job" => Value.Str(kindText(entry#kind)), "id" => Value.Str(entry#id), "status" => Value.Str(outcomeText(entry#outcome)), "detail" => Value.Str(entry#detail),
            "time" => Value.Str(Timestamp.toIso8601(Timestamp.fromEpochMillis(System.currentTimeMillis()))) })))

}
