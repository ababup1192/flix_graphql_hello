///
/// Publishing.effectsOf: 出来事 → 積む副作用の表。純粋。
///
mod TestPublishing {

    /// 出来事ごとの副作用の列と順。
    ///
    ///   entry.published    版 +1 → Webhook entry.published
    ///   entry.unpublished  版 +1 → Webhook entry.unpublished
    ///   entry.deleted      版 +1 → Webhook entry.deleted
    ///   schema.changed     版 +1 → Webhook schema.changed
    ///   下書きの保存        何も積まない
    @Test
    def testPublishingEffectsOf(): Unit \ Assert =
        let entry = CmsTestKit.entryId("e1");
        let blogs = CmsTestKit.apiId("blogs");
        let table = List#{
            (PublishingEvent.EntryPublished(entry, blogs),   List#{ PublishingEffect.BumpContentVersion, PublishingEffect.EmitWebhook(WebhookEvent.EntryPublished) }),
            (PublishingEvent.EntryUnpublished(entry, blogs), List#{ PublishingEffect.BumpContentVersion, PublishingEffect.EmitWebhook(WebhookEvent.EntryUnpublished) }),
            (PublishingEvent.EntryDeleted(entry, blogs),     List#{ PublishingEffect.BumpContentVersion, PublishingEffect.EmitWebhook(WebhookEvent.EntryDeleted) }),
            (PublishingEvent.SchemaChanged(blogs),           List#{ PublishingEffect.BumpContentVersion, PublishingEffect.EmitWebhook(WebhookEvent.SchemaChanged) }),
            (PublishingEvent.DraftSaved(entry, blogs),       Nil)
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(Publishing.effectsOf))

}
