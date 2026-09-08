///
/// バックグラウンドの仕事 1 件の結果を 1 行出す（job.kind / job.id / job.outcome / detail。Loki で数えられる形）。Scheduler と WebhookDispatcher が使う。
///
mod JobLog {

    use Log.Fields
    use Log.Severity

    /// 仕事の種類。
    pub enum JobKind with Eq, ToString {
        case Schedule
        case Webhook
    }

    /// 結果。job.outcome の値は Loki の集計が見るので固定。
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

    /// 結果の重さ。最後の失敗は Error（人が今日中に見る）、再試行は Warn、done / delivered は Info。
    def severityOf(outcome: JobOutcome): Severity = match outcome {
        case JobOutcome.Done       => Severity.Info
        case JobOutcome.Delivered  => Severity.Info
        case JobOutcome.RetryLater => Severity.Warn
        case JobOutcome.Failed     => Severity.Error
    }

    ///
    /// 1 行出す。fields は業務エラーの属性（LogFields.failure）など、足したい物。
    ///
    pub def write(entry: { kind = JobKind, id = String, outcome = JobOutcome, detail = String }, fields: Fields): Unit \ Log =
        Log.emit({ severity = severityOf(entry#outcome), message = "job ${outcomeText(entry#outcome)}", fields =
            fields
                |> Fields.str("job.kind", kindText(entry#kind))
                |> Fields.str("job.id", entry#id)
                |> Fields.str("job.outcome", outcomeText(entry#outcome))
                |> Fields.str("detail", entry#detail) })

}
