///
/// 管理 API の Webhook まわりの型（Webhook / IssuedWebhook / WebhookDelivery）のリゾルバ。source はドメインの値。
///
mod WebhookResolvers {

    /// type Webhook のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.WebhookResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            name      = (_context, source) -> Ok(source#name),
            url       = (_context, source) -> Ok(source#url),
            events    = (_context, source) -> Ok(source#events |> List.map(AdminMapping.webhookEventToGql)),
            active    = (_context, source) -> Ok(source#active),
            createdAt = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt))
        }

}

mod IssuedWebhookResolvers {

    /// type IssuedWebhook のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.IssuedWebhookResolvers[AdminEff] =
        {
            webhook = (_context, source) -> Ok(source#webhook),
            secret  = (_context, source) -> Ok(source#secret)
        }

}

mod WebhookDeliveryResolvers {

    /// type WebhookDelivery のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.WebhookDeliveryResolvers[AdminEff] =
        {
            id            = (_context, source) -> Ok(AdminMapping.idOfUlid(source#id)),
            event         = (_context, source) -> Ok(AdminMapping.webhookEventToGql(source#event)),
            status        = (_context, source) -> Ok(AdminMapping.deliveryStatusToGql(source#status)),
            attempts      = (_context, source) -> Ok(source#attempts),
            nextAttemptAt = (_context, source) -> Ok(Timestamp.toIso8601(source#nextAttemptAt)),
            lastStatus    = (_context, source) -> Ok(source#lastStatus),
            lastError     = (_context, source) -> Ok(source#lastError),
            createdAt     = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            deliveredAt   = (_context, source) -> Ok(source#deliveredAt |> Option.map(Timestamp.toIso8601))
        }

}
