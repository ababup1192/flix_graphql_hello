///
/// 監査の記録を実 PostgreSQL で通す。操作ごとに 1 行積まれるか、失敗した操作の記録が残らないか、後から書き換えられないか。
///
mod TestAuditPg {

    use Util.Json.Json

    /// 積まれた記録の action を古い順に。
    def actions(): List[String] \ DbRead + Tenant + CmsErr + Session =
        Audit.recent(Session.grant(), 50i64, None) |> List.map(found -> found#action) |> List.reverse

    /// 積まれた記録の対象を古い順に。
    def targets(): List[String] \ DbRead + Tenant + CmsErr + Session =
        Audit.recent(Session.grant(), 50i64, None) |> List.map(found -> found#targetId) |> List.reverse

    ///
    /// 型とフィールドを触ると、操作ごとに 1 行ずつ積まれる。
    ///
    ///   型を作る → フィールドを足す → フィールドを直す → 並べ替え → フィールドを消す → 型を消す
    ///
    @Test
    def testPgAuditRecordsTypeChanges(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            let title = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            discard ContentTypes.updateField(Session.grant(), title#id, { name = None, required = Some(true), unique = None, localized = None, config = None });
            discard ContentTypes.reorderFields(Session.grant(), blogs#id, List#{title#id});
            ContentTypes.removeField(Session.grant(), title#id);
            ContentTypes.delete(Session.grant(), blogs#id);
            (actions(), targets())
        });
        Assert.assertEq(expected = Ok(Ok((
            List#{"type.created", "field.added", "field.updated", "fields.reordered", "field.removed", "type.deleted"},
            List#{"blogs", "blogs.title", "blogs.title", "blogs", "blogs.title", "blogs"}))), result)

    ///
    /// 主体は版の author と同じ形（この Tx は System として走る）。
    ///
    @Test
    def testPgAuditKeepsActor(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            discard ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            Audit.recent(Session.grant(), 1i64, None) |> List.map(found -> found#actor)
        });
        Assert.assertEq(expected = Ok(Ok(List#{"system"})), result)

    ///
    /// メンバーと鍵の変更も 1 行ずつ積まれる。owner として招待 → 役割の変更 → 外す、鍵の発行 → 失効。
    ///
    /// WhyNot: System ではなく owner として走らせるのは、招待が招いた人（`Session.currentUser()`）を要求し、
    /// System には人の id が無いため。
    ///
    @Test
    def testPgAuditRecordsMemberAndKeyChanges(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> PgTestSupport.asOwner(() -> {
            discard Members.invite(Session.grant(), "editor@test.dev", Role.Editor);
            let issued = ApiKeys.create(Session.grant(), Session.grantInteractive(), PgTestSupport.pepper(), { name = "CI", scope = ApiKeyScope.Read, expiresAt = None }, 0i64);
            ApiKeys.revoke(Session.grant(), issued#publicId);
            // 鍵の 2 行は発行した鍵の公開 id を指す（公開 id は乱数なので、値ではなく一致で見る）
            (actions(), targets() == List#{"editor@test.dev", issued#publicId, issued#publicId})
        }));
        Assert.assertEq(expected = Ok(Ok((
            List#{"member.invited", "api_key.created", "api_key.revoked"}, true))), result)

    ///
    /// 型を直すと type.updated が積まれる（作る・消す以外の道も通る）。
    ///
    @Test
    def testPgAuditRecordsTypeUpdate(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.update(Session.grant(), blogs#id, { name = Some("ブログ"), singular = None, plural = None, previewUrl = None, linkPath = None, icon = None });
            actions()
        });
        Assert.assertEq(expected = Ok(Ok(List#{"type.created", "type.updated"})), result)

    ///
    /// 失敗した操作は記録も残らない。entry が残っている型を消そうとすると invalid になり、
    /// 同じ Tx なので type.deleted の行も一緒に ROLLBACK される。
    ///
    @Test
    def testPgAuditRollsBackWithTheChange(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let typeId = PgTestSupport.seed(() -> {
                let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
                discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
                discard ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("こんにちは"))}));
                blogs#id
            });
            let refused = PgTestSupport.mutate(pool, () -> ContentTypes.delete(Session.grant(), typeId)) |> Result.isOk;
            let recorded = PgTestSupport.mutateOrBug(pool, () -> actions());
            (refused, recorded)
        });
        Assert.assertEq(expected = (false, List#{"type.created", "field.added"}), outcome)

    ///
    /// 積んだ記録は書き換えられない（UPDATE と DELETE の policy が無い）。
    ///
    @Test
    def testPgAuditIsAppendOnly(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> discard ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事")));
            let updated = PgTestSupport.mutate(pool, () -> RawSql.runWithAllow(() -> Sql.execute("UPDATE audit_events SET actor = 'nobody'", Nil)));
            let deleted = PgTestSupport.mutate(pool, () -> RawSql.runWithAllow(() -> Sql.execute("DELETE FROM audit_events", Nil)));
            let remaining = PgTestSupport.mutateOrBug(pool, () -> actions());
            (updated |> Result.map(changed -> changed), deleted |> Result.map(changed -> changed), remaining)
        });
        Assert.assertEq(expected = (Ok(0), Ok(0), List#{"type.created"}), outcome)

    ///
    /// 管理 API から読める。型を作って消すと、新しい順に 2 件（owner だけ）。
    ///
    @Test
    def testPgAuditEventsOverGraphql(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            let typeId = ask("mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id } }") |> fst |> Value.path(List#{"createContentType", "id"}) |> Value.asStr |> Option.getWithDefault("?");
            discard ask("mutation { deleteContentType(id: \"${typeId}\") }");
            GraphqlTestKit.listAt(List#{"auditEvents"}, ask("{ auditEvents { actor action targetKind targetId detail } }"))
                |> List.filterMap(found -> match (Value.field("action", found) |> Value.asStr, Value.field("targetId", found) |> Value.asStr) {
                    case (Some(action), Some(targetId)) => Some((action, targetId))
                    case _                              => None
                })
        });
        Assert.assertEq(expected = List#{("type.deleted", "blogs"), ("type.created", "blogs")}, outcome)

}
