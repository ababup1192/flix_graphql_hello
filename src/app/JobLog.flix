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
        case CdnPurge
        case LinkCard
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
        case JobKind.CdnPurge => "cdn_purge"
        case JobKind.LinkCard => "link_card"
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
    /// 再試行する仕事の属性。何回目の試行か（job.attempts）と、次に試すまでの秒数（job.retry_delay_seconds）。
    /// 諦めた（もう試さない）ときは秒数を付けない。
    ///
    /// WhyNot: 次に試す「時刻」を出さないのは、時刻を決めるのが SQL 側（now() + make_interval）で、
    /// この行を出す時点ではまだ書いていないため。JVM 側で組むと DB との時計差ぶん嘘になる。行の時刻に秒数を足せば読める。
    ///
    /// WhyNot: write の entry に足さないのは、entry が閉じたレコードで、再試行を持たない仕事（予約公開）まで
    /// None を書く事になるため。仕事ごとに違う属性は fields で渡す、が元からの形。
    ///
    pub def retryFields(retry: { attempts = Int32, delaySeconds = Option[Int64] }, fields: Fields): Fields =
        fields
            |> Fields.int("job.attempts", Int32.toInt64(retry#attempts))
            |> (found -> retry#delaySeconds |> Option.map(seconds -> Fields.int("job.retry_delay_seconds", seconds, found)) |> Option.getWithDefault(found))

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
