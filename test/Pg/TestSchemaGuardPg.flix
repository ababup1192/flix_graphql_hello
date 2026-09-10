///
/// スキーマを変えた後も、参照の索引（entry_links）が中身（JSONB）と合っている事を実 PostgreSQL で見る。
///
/// impact と publishCheck は entry_links しか見ない（missingTargets / referrerLinks）。
/// 索引が中身とずれると、この 2 つが「壊れる物は無い」「公開できます」と答えたまま実際には壊れる。
///
mod TestSchemaGuardPg {

    use Util.Json.Json

    ///
    /// targets(t1) と holders(h1)。h1 の ref が t1 を指し、両方公開済み。
    /// 返すのは (holders の型 id, ref のフィールド id, targets の型 id, t1, h1)。
    ///
    def seedReference(): (TypeId, FieldId, TypeId, EntryId, EntryId) \ Db + CmsErr + Tenant + IdGen + Session =
        let targets = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("targets", "指し先"));
        discard ContentTypes.addField(Session.grant(), targets#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        let holders = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("holders", "参照元"));
        let ref = ContentTypes.addField(Session.grant(), holders#id, { target = Some(targets#id) | CmsTestKit.fieldDraft("ref", FieldKind.Reference, FieldConfig.empty()) });
        let t1 = ContentEntries.create(Session.grant(), targets#id, Some(CmsTestKit.entryId("t1")), CmsTestKit.entryData(List#{("title", Json.JString("one"))}));
        let h1 = ContentEntries.create(Session.grant(), holders#id, Some(CmsTestKit.entryId("h1")), CmsTestKit.entryData(List#{("ref", Json.JString("t1"))}));
        discard ContentEntries.publish(Session.grant(), t1#id, "tester", false);
        discard ContentEntries.publish(Session.grant(), h1#id, "tester", false);
        (holders#id, ref#id, targets#id, t1#id, h1#id)

    /// この entry を参照している物の数（公開の中身と下書きの中身の両方）。
    def breakCount(id: EntryId): Int32 \ DbRead + CmsErr + Tenant + Session =
        ContentEntries.impact(Session.grant(), id, ImpactAction.Delete)#breaks |> List.length

    ///
    /// 参照のフィールドを消して同じ apiId で足し直しても、impact は参照元を見つけられる。
    ///
    /// 中身（JSONB）は消していないので配信は参照を返し続ける。索引だけが消えると、
    /// 実際には壊れるのに「壊れる物は無い」と答える entry ができる。
    ///
    @Test
    def testPgImpactSurvivesFieldRecreate(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"t1", "h1"}, () -> {
            let (holders, ref, targets, t1, _) = seedReference();
            let before = breakCount(t1);
            ContentTypes.removeField(Session.grant(), ref);
            let removed = breakCount(t1);
            discard ContentTypes.addField(Session.grant(), holders, { target = Some(targets) | CmsTestKit.fieldDraft("ref", FieldKind.Reference, FieldConfig.empty()) });
            let readded = breakCount(t1);
            (before, removed, readded)
        }));
        // 消している間は参照が無いので 0 で正しい。足し直したら戻る。
        Assert.assertEq(expected = Ok(Ok((2, 0, 2))), result)

    ///
    /// 参照のフィールドを消して足し直した後も、指し先の entry は消せない。
    ///
    /// 中身（JSONB）は消していないので配信は参照を返し続ける。索引だけが消えると
    /// 削除の防止が効かなくなり、配信に出ている参照が壊れる。
    ///
    @Test
    def testPgDeleteStaysBlockedAfterFieldRecreate(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"t1", "h1"}, () -> {
            let (holders, ref, targets, t1, _) = seedReference();
            ContentTypes.removeField(Session.grant(), ref);
            discard ContentTypes.addField(Session.grant(), holders, { target = Some(targets) | CmsTestKit.fieldDraft("ref", FieldKind.Reference, FieldConfig.empty()) });
            CmsTestKit.failureMessage(() -> ContentEntries.delete(Session.grant(), Some(Session.grant()), t1))
        }));
        Assert.assertEq(expected = Ok(Ok(Err("references: 公開中の entry 'h1' が参照しています。先にそちらを取り下げるか、参照を外してください"))), result)

}
