///
/// 押す前の dry-run（fieldImpact）と、実際に押した時の判断がずれていない事を実 PostgreSQL で見る。
///
/// SchemaPreview は「押した後のスキーマ」を組み立てて差を出す。本物の mutation が DB に対して
/// する事と食い違うと、押す前に「安全です」と言った操作が止まる（またはその逆になる）。
/// 型では見られないので、同じ操作を両方に通して突き合わせる。
///
mod TestSchemaPreviewPg {

    use Util.Json.Json

    ///
    /// blogs(title, body, memo) と、title と body に値を持つ公開済みの entry 1 件。
    /// memo は誰も値を入れていない。返すのは (型 id, body の id, memo の id)。
    ///
    def seedBlog(): (TypeId, FieldId, FieldId) \ Db + CmsErr + Tenant + IdGen + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        let body = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.Text, FieldConfig.empty()));
        let memo = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("memo", FieldKind.Text, FieldConfig.empty()));
        let entry = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b1")),
            CmsTestKit.entryData(List#{("title", Json.JString("題")), ("body", Json.JString("本文"))}));
        discard ContentEntries.publish(Session.grant(), entry#id, "tester", false);
        (blogs#id, body#id, memo#id)

    /// 押す前の dry-run。safe と、影響の種類。
    def preview(edit: SchemaEdit): (Bool, List[String]) \ DbRead + CmsErr + Tenant + Session =
        let changes = SchemaPreview.changesFor(edit, ContentTypes.list(Session.grant()));
        let (fields, types) = SchemaCounts.forChanges(changes);
        let effects = FieldImpact.of(changes, fields, types);
        (List.isEmpty(effects), effects |> List.map(effect -> "${effect#kind}") |> List.sort)

    /// 実際に押した時、指紋なしで止まるか。
    def pressed(thunk: Unit -> a \ ef): Bool \ (ef - CmsErr) + DbRead + Tenant + Session =
        CmsTestKit.runWithResult(() -> SchemaGuard.withImpact(Session.grant(), None, thunk)) |> Result.isErr

    ///
    /// 値のあるフィールドを消す時、dry-run は安全でないと言い、押すと止まる。
    ///
    @Test
    def testPgPreviewAgreesOnDestructiveRemove(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let (_, body, _) = seedBlog();
            let (safe, kinds) = preview(SchemaEdit.RemoveField(body));
            let stopped = pressed(() -> ContentTypes.removeField(Session.grant(), body));
            (safe, kinds, stopped)
        }));
        Assert.assertEq(expected = Ok(Ok((false, List#{"ValuesHidden"}, true))), result)

    ///
    /// 値の無いフィールドを消す時、dry-run は安全と言い、押すと通る。
    ///
    @Test
    def testPgPreviewAgreesOnHarmlessRemove(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let (_, _, memo) = seedBlog();
            let (safe, kinds) = preview(SchemaEdit.RemoveField(memo));
            let stopped = pressed(() -> ContentTypes.removeField(Session.grant(), memo));
            (safe, kinds, stopped)
        }));
        Assert.assertEq(expected = Ok(Ok((true, Nil, false))), result)

    ///
    /// required を立てる時、公開中に値が無い entry があれば止まる。
    ///
    @Test
    def testPgPreviewAgreesOnRequired(): Unit \ {IO, Assert} =
        let changes = { name = None, required = Some(true), unique = None, localized = None, config = None };
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let (_, _, memo) = seedBlog();
            let (safe, kinds) = preview(SchemaEdit.UpdateField(memo, changes));
            let stopped = pressed(() -> ContentTypes.updateField(Session.grant(), memo, changes));
            (safe, kinds, stopped)
        }));
        Assert.assertEq(expected = Ok(Ok((false, List#{"PublishBlocked"}, true))), result)

    ///
    /// entry のある型を消す時、dry-run が言う事と、消せない事が揃う。
    ///
    /// deleteContentType は entry が残っていれば ContentTypes.delete が別の理由でも止めるが、
    /// dry-run はその前に「型と一緒に entry が消えます」を出す。
    ///
    @Test
    def testPgPreviewAgreesOnTypeDelete(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let (blogs, _, _) = seedBlog();
            let (safe, kinds) = preview(SchemaEdit.DeleteContentType(blogs));
            let stopped = pressed(() -> ContentTypes.delete(Session.grant(), blogs));
            (safe, kinds, stopped)
        }));
        Assert.assertEq(expected = Ok(Ok((false, List#{"EntriesRemoved"}, true))), result)

    ///
    /// フィールドを足すのは安全。ただし消した apiId で足し直すと、残った値が配信に戻る。
    ///
    @Test
    def testPgPreviewSeesResurrectedValues(): Unit \ {IO, Assert} =
        let seen = { kinds = List#{SchemaEffectKind.ValuesHidden}, published = 1i64 };
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1"}, () -> {
            let (blogs, body, _) = seedBlog();
            let fresh = CmsTestKit.fieldDraft("fresh", FieldKind.Text, FieldConfig.empty());
            let harmless = preview(SchemaEdit.AddField(blogs, fresh)) |> fst;
            // body を消してから、同じ apiId で足し直す
            SchemaGuard.withImpact(Session.grant(), Some(seen), () -> ContentTypes.removeField(Session.grant(), body));
            let again = CmsTestKit.fieldDraft("body", FieldKind.Text, FieldConfig.empty());
            let (safe, kinds) = preview(SchemaEdit.AddField(blogs, again));
            let stopped = pressed(() -> ContentTypes.addField(Session.grant(), blogs, again));
            (harmless, safe, kinds, stopped)
        }));
        Assert.assertEq(expected = Ok(Ok((true, false, List#{"ValuesResurrected"}, true))), result)

}
