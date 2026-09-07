///
/// 管理 API の Webhook まわりの型（Webhook / IssuedWebhook / WebhookDelivery）のリゾルバ。source はドメインの値。
/// 素通しのフィールドは生成された既定リゾルバに任せ、写しが要る物だけレコードの更新で上書きする。
///
mod WebhookResolvers {

    /// type Webhook のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.WebhookResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            events    = (_context, source) -> Ok(source#events |> List.map(AdminMapping.webhookEventToGql)),
            createdAt = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt))
            | GeneratedAdmin.webhookDefaults()
        }

}

mod IssuedWebhookResolvers {

    /// type IssuedWebhook のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.IssuedWebhookResolvers[AdminEff] =
        {
            +webhook = (_context, source) -> Ok(source#webhook)
            | GeneratedAdmin.issuedWebhookDefaults()
        }

}

mod WebhookDeliveryResolvers {

    /// type WebhookDelivery のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.WebhookDeliveryResolvers[AdminEff] =
        {
            id            = (_context, source) -> Ok(AdminMapping.idOfUlid(source#id)),
            event         = (_context, source) -> Ok(AdminMapping.webhookEventToGql(source#event)),
            status        = (_context, source) -> Ok(AdminMapping.deliveryStatusToGql(source#status)),
            nextAttemptAt = (_context, source) -> Ok(Timestamp.toIso8601(source#nextAttemptAt)),
            createdAt     = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            deliveredAt   = (_context, source) -> Ok(source#deliveredAt |> Option.map(Timestamp.toIso8601))
            | GeneratedAdmin.webhookDeliveryDefaults()
        }

}
