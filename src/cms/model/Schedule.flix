///
/// 予約公開。時刻を指定した公開・取り下げを積み、背景の Scheduler が時刻になったら実行する。
///

///
/// 予約する操作。
///
pub enum ScheduleAction with Eq, Order, ToString {
    case Publish
    case Unpublish
}

mod ScheduleAction {
    pub def text(action: ScheduleAction): String = match action {
        case ScheduleAction.Publish   => "publish"
        case ScheduleAction.Unpublish => "unpublish"
    }

    pub def parse(text: String): Option[ScheduleAction] = match text {
        case "publish"   => Some(ScheduleAction.Publish)
        case "unpublish" => Some(ScheduleAction.Unpublish)
        case _           => None
    }
}

///
/// 予約の状態。
///
pub enum ScheduleStatus with Eq, Order, ToString {
    /// 時刻を待っている
    case Pending
    /// 実行中（Scheduler が拾った）
    case Running
    /// 実行した
    case Done
    /// 実行したが業務エラー（required の欠け、参照先が未公開など）。理由が残る
    case Failed
    /// 取り消した
    case Cancelled
}

mod ScheduleStatus {
    pub def text(status: ScheduleStatus): String = match status {
        case ScheduleStatus.Pending   => "pending"
        case ScheduleStatus.Running   => "running"
        case ScheduleStatus.Done      => "done"
        case ScheduleStatus.Failed    => "failed"
        case ScheduleStatus.Cancelled => "cancelled"
    }

    pub def parse(text: String): Option[ScheduleStatus] = match text {
        case "pending"   => Some(ScheduleStatus.Pending)
        case "running"   => Some(ScheduleStatus.Running)
        case "done"      => Some(ScheduleStatus.Done)
        case "failed"    => Some(ScheduleStatus.Failed)
        case "cancelled" => Some(ScheduleStatus.Cancelled)
        case _           => None
    }
}

///
/// 予約 1 つ。id は ULID（時刻順）。
///
/// - runAt: 実行する時刻
/// - withDependencies: publish の時、未公開の参照先も一緒に公開するか
/// - requestedBy: 予約した人（表示名）
/// - lastError: failed の理由。無ければ空
///
pub type alias Schedule = { id = String, entryId = EntryId, action = ScheduleAction, runAt = Timestamp.Timestamp, withDependencies = Bool, status = ScheduleStatus, requestedBy = String, lastError = String, createdAt = Timestamp.Timestamp, doneAt = Option[Timestamp.Timestamp] }
