///
/// Webhook。公開・取り下げ・削除・型の変更を、プロジェクトが登録した URL に POST で知らせる。
///

///
/// 知らせる出来事。
///
pub enum WebhookEvent with Eq, Order, ToString {
    /// entry を公開した（再公開も）
    case EntryPublished
    /// 公開を取り下げた
    case EntryUnpublished
    /// entry をゴミ箱へ入れた
    case EntryDeleted
    /// content type かフィールドが変わった（公開サイトの型生成のやり直し用）
    case SchemaChanged
}

mod WebhookEvent {
    pub def text(event: WebhookEvent): String = match event {
        case WebhookEvent.EntryPublished   => "entry.published"
        case WebhookEvent.EntryUnpublished => "entry.unpublished"
        case WebhookEvent.EntryDeleted     => "entry.deleted"
        case WebhookEvent.SchemaChanged    => "schema.changed"
    }

    pub def parse(text: String): Option[WebhookEvent] = match text {
        case "entry.published"   => Some(WebhookEvent.EntryPublished)
        case "entry.unpublished" => Some(WebhookEvent.EntryUnpublished)
        case "entry.deleted"     => Some(WebhookEvent.EntryDeleted)
        case "schema.changed"    => Some(WebhookEvent.SchemaChanged)
        case _                   => None
    }
}

///
/// 配信 1 回の状態。
///
pub enum DeliveryStatus with Eq, Order, ToString {
    /// 送る番を待っている（再試行待ちも）
    case Pending
    /// 送っている最中（dispatcher が拾った）
    case Sending
    /// 2xx が返った
    case Delivered
    /// 回数を使い切った。管理 API から再送できる
    case Failed
}

mod DeliveryStatus {
    pub def text(status: DeliveryStatus): String = match status {
        case DeliveryStatus.Pending   => "pending"
        case DeliveryStatus.Sending   => "sending"
        case DeliveryStatus.Delivered => "delivered"
        case DeliveryStatus.Failed    => "failed"
    }

    pub def parse(text: String): Option[DeliveryStatus] = match text {
        case "pending"   => Some(DeliveryStatus.Pending)
        case "sending"   => Some(DeliveryStatus.Sending)
        case "delivered" => Some(DeliveryStatus.Delivered)
        case "failed"    => Some(DeliveryStatus.Failed)
        case _           => None
    }
}

///
/// 登録した Webhook。secret は持たない（作った時に 1 度だけ返す）。
///
/// - id: 内部の主キー。publicId が GraphQL の ID
/// - events: 知らせる出来事
/// - active: false なら積まない
///
pub type alias Webhook = { id = Int64, publicId = String, name = String, url = String, events = List[WebhookEvent], active = Bool, createdAt = Timestamp.Timestamp }

///
/// 作る・直す時の入力。
///
pub type alias WebhookDraft = { name = String, url = String, events = List[WebhookEvent], active = Bool }

///
/// 作った直後。secret はこの時だけ見える。
///
pub type alias IssuedWebhook = { webhook = Webhook, secret = String }

///
/// 配信 1 回。id は ULID（時刻順）。
///
/// - attempts: 送った回数
/// - nextAttemptAt: 次に送る時刻（pending の時）
/// - lastStatus: 最後の HTTP のステータス。応答が無ければ 0
/// - lastError: 最後の失敗の理由。無ければ空
///
pub type alias WebhookDelivery = { id = String, event = WebhookEvent, status = DeliveryStatus, attempts = Int32, nextAttemptAt = Timestamp.Timestamp, lastStatus = Int32, lastError = String, createdAt = Timestamp.Timestamp, deliveredAt = Option[Timestamp.Timestamp] }
