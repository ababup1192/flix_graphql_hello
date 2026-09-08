///
/// ContentTypes を実 PostgreSQL で通しで動かす。migrations もここで毎回当たる。
///
mod TestContentTypesPg {

    use CmsErr.CmsFailure

    ///
    /// blogs 型の入力。
    ///
    def blogsDraft(): ContentTypeDraft =
        { previewUrl = Some("https://staging.example.com/blog/{id}") | CmsTestKit.typeDraft("blogs", "記事") }

    /// 型を作ってフィールドを 3 つ足すと、position 順に並び、config が JSONB を往復して戻る。
    ///
    ///   blogs: title(text, maxLength 120) → body(textArea) → slug(slug from title)
    @Test
    def testPgCreateTypeAndFields(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), blogsDraft());
            discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, { maxLength = Some(120) | FieldConfig.empty() }));
            discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.TextArea, FieldConfig.empty()));
            discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("slug", FieldKind.Slug, { sourceField = Some(CmsTestKit.apiId("title")) | FieldConfig.empty() }));
            let loaded = ContentTypes.fetch(Session.grant(), blogs#id);
            (TypeName.text(loaded#singular), ApiId.text(loaded#plural), loaded#kind, loaded#previewUrl,
             loaded#fields |> List.map(field -> (ApiId.text(field#apiId), field#position, field#config#maxLength, field#config#sourceField |> Option.map(ApiId.text))))
        });
        Assert.assertEq(expected = Ok(Ok(("Blog", "blogs", TypeKind.Collection, Some("https://staging.example.com/blog/{id}"),
            List#{("title", 0, Some(120), None), ("body", 1, None, None), ("slug", 2, None, Some("title"))}))), result)

    /// 並べ替えは position を書き換え、型を消すとフィールドも消える（ON DELETE CASCADE）。
    @Test
    def testPgReorderAndDelete(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), blogsDraft());
            let title = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let body = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.TextArea, FieldConfig.empty()));
            let reordered = ContentTypes.reorderFields(Session.grant(), blogs#id, List#{body#id, title#id}) |> (found -> found#fields |> List.map(field -> ApiId.text(field#apiId)));
            ContentTypes.delete(Session.grant(), blogs#id);
            (reordered, ContentTypes.find(Session.grant(), blogs#id) |> Option.isEmpty, ContentFieldsQueries.listAllFields(1i64) |> List.length)
        });
        Assert.assertEq(expected = Ok(Ok((List#{"body", "title"}, true, 0))), result)

    /// update は触った項目だけ変え、singular の衝突は invalid になる。
    @Test
    def testPgUpdateAndCollision(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), blogsDraft());
            discard ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("tags", "タグ"));
            let renamed = ContentTypes.update(Session.grant(), blogs#id, { name = Some("ブログ記事"), singular = None, plural = None, previewUrl = None });
            let collision = CmsErr.runWithResult(() -> ContentTypes.update(Session.grant(), blogs#id, { name = None, singular = Some(CmsTestKit.typeName("Tag")), plural = None, previewUrl = None }));
            (renamed#name, TypeName.text(renamed#singular), collision |> Result.map(found -> TypeName.text(found#singular)))
        });
        Assert.assertEq(expected = Ok(Ok(("ブログ記事", "Blog", Err(CmsFailure.Invalid(List#{Violation.Violation("singular", "'Tag' は既に他の型が使っています")}))))), result)

    /// 同じ apiId の型は DB の一意制約でも止まる（検証をすり抜けた同時作成の最後の砦）。
    @Test
    def testPgApiIdUniqueInDb(): Unit \ {IO, Assert} =
        let kind = PgTestSupport.withDb(() -> {
            discard ContentTypes.create(Session.grant(), blogsDraft());
            DbError.runWithKind(() -> ContentTypesQueries.insertContentType({ projectId = 1i64, apiId = "blogs", kind = "collection", name = "x", singular = "X", plural = "xs", previewUrl = "" }))
                |> Result.map(Option.map(row -> row#id))
        });
        Assert.assertEq(expected = Ok(Ok(Err(DbError.DbErrorKind.UniqueViolation("content_types_project_api_id_key")))), kind)

    /// 管理 API のエンジンを通しても同じ。SDL・リゾルバ・Runner・GraphQL とドメインの写しをここで 1 回だけ確かめる。
    @Test
    def testPgAdminEngineRoundTrip(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            let created = PgTestSupport.askOwner(api)(
                "mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id apiId singular plural kind fields { apiId } } }");
            let createdId = created |> fst |> Value.path(List#{"createContentType", "id"}) |> Value.asStr |> Option.getWithDefault("?");
            let added = PgTestSupport.askOwner(api)(
                "mutation { addField(typeId: \"${createdId}\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true, config: { maxLength: 120 } }) { apiId kind required position config { maxLength sourceField } } }");
            let listed = PgTestSupport.askOwner(api)( "{ contentTypes { apiId fields { apiId } } contentType(apiId: \"blogs\") { singular } }");
            let invalid = PgTestSupport.askOwner(api)( "mutation { createContentType(input: { apiId: \"Bad Id\", name: \"x\" }) { id } }") |> snd;
            let badId = PgTestSupport.askOwner(api)( "mutation { removeField(id: \"abc\") }") |> snd;
            (createdId, created, added, listed, invalid, badId)
        });
        let (createdId, created, added, listed, invalid, badId) = outcome;
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "createContentType" => Value.Obj(Map#{ "id" => Value.Str(createdId), "apiId" => Value.Str("blogs"), "singular" => Value.Str("Blog"), "plural" => Value.Str("blogs"), "kind" => Value.Str("COLLECTION"), "fields" => Value.List(Nil) }) }), None),
                (Value.Obj(Map#{ "addField" => Value.Obj(Map#{ "apiId" => Value.Str("title"), "kind" => Value.Str("TEXT"), "required" => Value.Bool(true), "position" => Value.Int(0), "config" => Value.Obj(Map#{ "maxLength" => Value.Int(120), "sourceField" => Value.Null }) }) }), None),
                (Value.Obj(Map#{ "contentTypes" => Value.List(Value.Obj(Map#{ "apiId" => Value.Str("blogs"), "fields" => Value.List(Value.Obj(Map#{ "apiId" => Value.Str("title") }) :: Nil) }) :: Nil), "contentType" => Value.Obj(Map#{ "singular" => Value.Str("Blog") }) }), None),
                Some("apiId: lowerCamel の識別子（[a-z][A-Za-z0-9]*）にしてください"),
                Some("id: 'abc' は数字の ID ではありません")),
            (created, added, listed, invalid, badId))

    // ---- 名前と kind の守り ----

    /// SINGLETON には entry を 1 件しか作れない（コンテンツ API が 1 件しか返さないので、2 件目は見えない物になる）。
    @Test
    def testPgSingletonSingleEntry(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"s1", "s2"}, () -> {
            let settings = ContentTypes.create(Session.grant(), { kind = TypeKind.Singleton | CmsTestKit.typeDraft("settings", "サイト設定") });
            discard ContentTypes.addField(Session.grant(), settings#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            discard ContentEntries.create(Session.grant(), settings#id, None, CmsTestKit.entryData(List#{("title", Util.Json.Json.JString("a"))}));
            CmsTestKit.failureMessage(() -> ContentEntries.create(Session.grant(), settings#id, None, CmsTestKit.entryData(List#{("title", Util.Json.Json.JString("b"))})))
        }));
        Assert.assertEq(expected = Ok(Ok(Err("typeId: SINGLETON の型には entry を 1 件しか作れません"))), result)

    /// apiId だけ渡して singular と plural が同じになる（status → Status / status）時、怒られるのは渡していない plural ではなく apiId。
    @Test
    def testPgDerivedNamesBlameApiId(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.failureMessage(() -> ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("status", "状態"))));
        Assert.assertEq(expected = Ok(Ok(Err("apiId: apiId から導いた plural が使えません（singular と同じ名前は使えません（コンテンツ API の 1 件と一覧のクエリ名が衝突します））。singular か plural を指定してください"))), result)

    /// 他の型が生やす型名（BlogCategory）と同じ singular の型は作れず、既にある型名と重なる名前のフィールド（where → BlogWhere）も足せない。
    /// 作れてしまうと graphql-java がスキーマを組めず、コンテンツ API 全体が止まる。
    @Test
    def testPgSchemaTypeNameCollisions(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), blogsDraft());
            discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("category", FieldKind.Select, { options = List#{"NEWS"} | FieldConfig.empty() }));
            let typeClash = CmsTestKit.failureMessage(() -> ContentTypes.create(Session.grant(), { singular = Some(CmsTestKit.typeName("BlogCategory")) | CmsTestKit.typeDraft("categories", "分類") }));
            let fieldClash = CmsTestKit.failureMessage(() -> ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("where", FieldKind.Object, FieldConfig.empty())));
            let plainField = CmsTestKit.messageOr(field -> ApiId.text(field#apiId), () -> ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("where", FieldKind.Text, FieldConfig.empty())));
            (typeClash, fieldClash, plainField)
        });
        Assert.assertEq(expected = Ok(Ok((
            Err("singular: 'BlogCategory' は他の型がコンテンツ API に生やす型名と重なります"),
            Err("apiId: 'BlogWhere' はコンテンツ API に既にある型名と重なります"),
            Ok("where")))), result)

    /// フィールドを消した後も、古い値が残った entry は更新も公開もできる。消えたフィールドの値は次の保存で落ちる。
    @Test
    def testPgRemovedFieldDoesNotBlockEntries(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"e1"}, () -> {
            let blogs = ContentTypes.create(Session.grant(), blogsDraft());
            discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let body = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.TextArea, FieldConfig.empty()));
            let created = ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Util.Json.Json.JString("a")), ("body", Util.Json.Json.JString("b"))}));
            ContentTypes.removeField(Session.grant(), body#id);
            let updated = ContentEntries.update(Session.grant(), created#id, CmsTestKit.entryData(List#{("title", Util.Json.Json.JString("c"))}), created#version);
            let published = ContentEntries.publish(Session.grant(), updated#id, "tester", false);
            (Map.keysOf(updated#data) |> Set.toList |> List.map(ApiId.text), published#stage)
        }));
        Assert.assertEq(expected = Ok(Ok((List#{"title"}, Stage.Published))), result)
}
