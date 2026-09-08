///
/// 公開側に見える変化（公開・取り下げ・削除・型の変更）の出来事。ユースケースは 1 つ作って `Publishing.notify` に渡す。
///
pub enum PublishingEvent with Eq, Order {
    /// entry を公開した（再公開も）
    case EntryPublished(EntryId, ApiId)
    /// 公開を取り下げた（公開中だった時だけ）
    case EntryUnpublished(EntryId, ApiId)
    /// entry をゴミ箱へ入れた
    case EntryDeleted(EntryId, ApiId)
    /// content type かフィールドが変わった
    case SchemaChanged(ApiId)
    /// 下書きを保存した。公開側は変わらない
    case DraftSaved(EntryId, ApiId)
}

///
/// 出来事に対して積む副作用。順は `Publishing.effectsOf` の表が決める。
///
pub enum PublishingEffect with Eq, Order, ToString {
    /// プロジェクトの版（content_version）を +1（コンテンツ API の ETag が変わる）
    case BumpContentVersion
    /// Webhook の配信を outbox に積む
    case EmitWebhook(WebhookEvent)
}

///
/// 公開側の変化の副作用を 1 か所で積む Facade。どの出来事がどの副作用を積むかは純粋な表 `effectsOf` が持ち、
/// `notify` はその表の順に同じ Tx で実行する。
///
/// WhyNot: 出来事を表（events）に書いて消費者が拾う形にしないのは、消費者が Webhook の outbox と版の 2 つしか無く、
/// 両方とも業務の Tx の中で終わるため。4 つ目の消費者（監査ログ・検索索引）が来たら events の 1 表 + consumer に作り直す。
///
/// WhyNot: 副作用の関数（Webhooks.emit* / Projects.bumpContentVersion）が権限の証明を取らないのは今まで通り。
/// 誰ができるかは公開などの入口が決めていて、ここは操作の結果を積むだけ。
///
mod Publishing {

    ///
    /// 出来事 → 積む副作用（この順に実行する）。下書きの保存は何も積まない。
    ///
    /// WhyNot: 下書きの保存で版を進めないのは、コンテンツ API の匿名の GET は公開中しか読めず、下書きが変わってもキャッシュの中身は変わらないため。
    /// 進めると下書きの保存のたびに CDN のキャッシュが全部外れる。
    ///
    pub def effectsOf(event: PublishingEvent): List[PublishingEffect] = match event {
        case PublishingEvent.EntryPublished(_, _)   => List#{ PublishingEffect.BumpContentVersion, PublishingEffect.EmitWebhook(WebhookEvent.EntryPublished) }
        case PublishingEvent.EntryUnpublished(_, _) => List#{ PublishingEffect.BumpContentVersion, PublishingEffect.EmitWebhook(WebhookEvent.EntryUnpublished) }
        case PublishingEvent.EntryDeleted(_, _)     => List#{ PublishingEffect.BumpContentVersion, PublishingEffect.EmitWebhook(WebhookEvent.EntryDeleted) }
        case PublishingEvent.SchemaChanged(_)       => List#{ PublishingEffect.BumpContentVersion, PublishingEffect.EmitWebhook(WebhookEvent.SchemaChanged) }
        case PublishingEvent.DraftSaved(_, _)       => Nil
    }

    ///
    /// 出来事の副作用を表の順に積む。ユースケースが業務の書き込みと同じ Tx で 1 回呼ぶ。
    ///
    pub def notify(event: PublishingEvent): Unit \ Db + IdGen + Tenant =
        effectsOf(event) |> List.forEach(apply(event))

    /// 副作用 1 つを実行する。
    def apply(event: PublishingEvent, sideEffect: PublishingEffect): Unit \ Db + IdGen + Tenant = match sideEffect {
        case PublishingEffect.BumpContentVersion       => Projects.bumpContentVersion()
        case PublishingEffect.EmitWebhook(webhookEvent) => emit(webhookEvent, event)
    }

    /// Webhook の配信を積む。entry の出来事は entry の payload、型の出来事は型の payload。
    def emit(webhookEvent: WebhookEvent, event: PublishingEvent): Unit \ Db + IdGen + Tenant = match event {
        case PublishingEvent.EntryPublished(id, apiId)   => Webhooks.emitEntry(webhookEvent, id, apiId)
        case PublishingEvent.EntryUnpublished(id, apiId) => Webhooks.emitEntry(webhookEvent, id, apiId)
        case PublishingEvent.EntryDeleted(id, apiId)     => Webhooks.emitEntry(webhookEvent, id, apiId)
        case PublishingEvent.DraftSaved(id, apiId)       => Webhooks.emitEntry(webhookEvent, id, apiId)
        case PublishingEvent.SchemaChanged(apiId)        => Webhooks.emitSchema(apiId)
    }

}
