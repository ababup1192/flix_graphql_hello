use CmsErr.CmsFailure

///
/// ContentTypes を実 PostgreSQL で通しで動かす。migrations もここで毎回当たる。
///

///
/// blogs 型の入力。
///
def blogsDraft(): ContentTypeDraft =
    { apiId = CmsTestKit.apiId("blogs"), kind = TypeKind.Collection, name = "記事", singular = None, plural = None, previewUrl = Some("https://staging.example.com/blog/{id}") }

/// 型を作ってフィールドを 3 つ足すと、position 順に並び、config が JSONB を往復して戻る。
///
///   blogs: title(text, maxLength 120) → body(textArea) → slug(slug from title)
@Test
def testPgCreateTypeAndFields(): Unit \ {IO, Assert} =
    let result = PgTestSupport.withDb(() -> {
        let blogs = ContentTypes.create(blogsDraft());
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, { maxLength = Some(120) | FieldConfig.empty() }));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("body", FieldKind.TextArea, FieldConfig.empty()));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("slug", FieldKind.Slug, { sourceField = Some(CmsTestKit.apiId("title")) | FieldConfig.empty() }));
        let loaded = ContentTypes.get(blogs#id);
        (TypeName.text(loaded#singular), ApiId.text(loaded#plural), loaded#kind, loaded#previewUrl,
         loaded#fields |> List.map(field -> (ApiId.text(field#apiId), field#position, field#config#maxLength, field#config#sourceField |> Option.map(ApiId.text))))
    });
    Assert.assertEq(expected = Ok(Ok(("Blog", "blogs", TypeKind.Collection, Some("https://staging.example.com/blog/{id}"),
        List#{("title", 0, Some(120), None), ("body", 1, None, None), ("slug", 2, None, Some("title"))}))), result)

/// 並べ替えは position を書き換え、型を消すとフィールドも消える（ON DELETE CASCADE）。
@Test
def testPgReorderAndDelete(): Unit \ {IO, Assert} =
    let result = PgTestSupport.withDb(() -> {
        let blogs = ContentTypes.create(blogsDraft());
        let title = ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        let body = ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("body", FieldKind.TextArea, FieldConfig.empty()));
        let reordered = ContentTypes.reorderFields(blogs#id, List#{body#id, title#id}) |> (found -> found#fields |> List.map(field -> ApiId.text(field#apiId)));
        ContentTypes.delete(blogs#id);
        (reordered, ContentTypes.find(blogs#id) |> Option.isEmpty, ContentFieldsQueries.listAllFields() |> List.length)
    });
    Assert.assertEq(expected = Ok(Ok((List#{"body", "title"}, true, 0))), result)

/// update は触った項目だけ変え、singular の衝突は invalid になる。
@Test
def testPgUpdateAndCollision(): Unit \ {IO, Assert} =
    let result = PgTestSupport.withDb(() -> {
        let blogs = ContentTypes.create(blogsDraft());
        discard ContentTypes.create({ apiId = CmsTestKit.apiId("tags"), kind = TypeKind.Collection, name = "タグ", singular = None, plural = None, previewUrl = None });
        let renamed = ContentTypes.update(blogs#id, { name = Some("ブログ記事"), singular = None, plural = None, previewUrl = None });
        let collision = CmsErr.runWithResult(() -> ContentTypes.update(blogs#id, { name = None, singular = TypeName.parse("Tag"), plural = None, previewUrl = None }));
        (renamed#name, TypeName.text(renamed#singular), collision |> Result.map(found -> TypeName.text(found#singular)))
    });
    Assert.assertEq(expected = Ok(Ok(("ブログ記事", "Blog", Err(CmsFailure.Invalid(List#{Violation.Violation("singular", "'Tag' は既に他の型が使っています")}))))), result)

/// 同じ apiId の型は DB の一意制約でも止まる（検証をすり抜けた同時作成の最後の砦）。
@Test
def testPgApiIdUniqueInDb(): Unit \ {IO, Assert} =
    let kind = PgTestSupport.withDb(() -> {
        discard ContentTypes.create(blogsDraft());
        DbError.runWithKind(() -> ContentTypesQueries.insertContentType({ apiId = "blogs", kind = "collection", name = "x", singular = "X", plural = "xs", previewUrl = "" }))
            |> Result.map(Option.map(row -> row#id))
    });
    Assert.assertEq(expected = Ok(Ok(Err(DbError.DbErrorKind.UniqueViolation("content_types_api_id_key")))), kind)

/// 管理 API のエンジンを通しても同じ。SDL・リゾルバ・Runner・GraphQL とドメインの写しをここで 1 回だけ確かめる。
@Test
def testPgAdminEngineRoundTrip(): Unit \ {IO, Assert} =
    let pool = Pool.open(Pool.defaultConfig(PgTestSupport.config()));
    discard PgTestSupport.withDb(() -> ());
    let schema = AdminSchema.make(AdminRunner.make(pool));
    let created = GraphqlTestKit.executeQuery(schema,
        "mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id apiId singular plural kind fields { apiId } } }");
    let createdId = created |> Result.map(fst) |> Result.map(data -> Value.field("createContentType", data) |> (found -> Value.field("id", found)) |> Value.asStr |> Option.getWithDefault("?")) |> Result.getWithDefault("?");
    let added = GraphqlTestKit.executeQuery(schema,
        "mutation { addField(typeId: \"${createdId}\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true, config: { maxLength: 120 } }) { apiId kind required position config { maxLength sourceField } } }");
    let listed = GraphqlTestKit.executeQuery(schema, "{ contentTypes { apiId fields { apiId } } contentType(apiId: \"blogs\") { singular } }");
    let invalid = GraphqlTestKit.executeQuery(schema, "mutation { createContentType(input: { apiId: \"Bad Id\", name: \"x\" }) { id } }");
    let badId = GraphqlTestKit.executeQuery(schema, "mutation { removeField(id: \"abc\") }");
    Pool.close(pool);
    Assert.assertEq(
        expected = (
            Ok((Value.Obj(Map#{ "createContentType" => Value.Obj(Map#{ "id" => Value.Str(createdId), "apiId" => Value.Str("blogs"), "singular" => Value.Str("Blog"), "plural" => Value.Str("blogs"), "kind" => Value.Str("COLLECTION"), "fields" => Value.List(Nil) }) }), None)),
            Ok((Value.Obj(Map#{ "addField" => Value.Obj(Map#{ "apiId" => Value.Str("title"), "kind" => Value.Str("TEXT"), "required" => Value.Bool(true), "position" => Value.Int(0), "config" => Value.Obj(Map#{ "maxLength" => Value.Int(120), "sourceField" => Value.Null }) }) }), None)),
            Ok((Value.Obj(Map#{ "contentTypes" => Value.List(Value.Obj(Map#{ "apiId" => Value.Str("blogs"), "fields" => Value.List(Value.Obj(Map#{ "apiId" => Value.Str("title") }) :: Nil) }) :: Nil), "contentType" => Value.Obj(Map#{ "singular" => Value.Str("Blog") }) }), None)),
            Ok(Some("apiId: lowerCamel の識別子（[a-z][A-Za-z0-9]*）にしてください")),
            Ok(Some("id: 'abc' は数字の ID ではありません"))),
        (created, added, listed, invalid |> Result.map(snd), badId |> Result.map(snd)))
