use Util.Json.Json

///
/// コンテンツ API を実 PostgreSQL で通しで動かす。型を作り、entry を入れ、定義から組んだエンジンで引く。
///

///
/// blogs（title / views / tags）に 3 件。まだ公開は無いので DRAFT で引く。
///
def seed(): Unit \ Db + CmsErr + IdGen =
    let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
    discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
    discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("views", FieldKind.Number, FieldConfig.empty()));
    discard ContentTypes.addField(blogs#id, { many = true | CmsTestKit.fieldDraft("tags", FieldKind.Text, FieldConfig.empty()) });
    discard ContentEntries.create(blogs#id, EntryId.parse("b1"), CmsTestKit.entryData(List#{("title", Json.JString("Flix で GraphQL")), ("views", CmsTestKit.intJson(10)), ("tags", Json.JArray(Vector#{Json.JString("flix")}))}));
    discard ContentEntries.create(blogs#id, EntryId.parse("b2"), CmsTestKit.entryData(List#{("title", Json.JString("Elm の話")), ("views", CmsTestKit.intJson(30))}));
    discard ContentEntries.create(blogs#id, EntryId.parse("b3"), CmsTestKit.entryData(List#{("title", Json.JString("flix と PostgreSQL")), ("views", CmsTestKit.intJson(20))}))

/// where / orderBy / first / skip / stage が効き、値は kind の型で返る。PUBLISHED はまだ無いので 0 件。
@Test
def testPgContentApiQueries(): Unit \ {IO, Assert} =
    let pool = Pool.open(Pool.defaultConfig(PgTestSupport.config()));
    discard PgTestSupport.withDb(() -> IdGen.runWithFixed(Nil, seed));
    let cache = ContentEngine.create();
    let engine = match ContentEngine.current(cache, pool) {
        case Ok(built)    => built
        case Err(message) => bug!("engine: ${message}")
    };
    let ask = queryText -> Graphql.runWithEngine(engine, () -> Graphql.execute(GraphqlTestKit.queryOnly(queryText), Context.anonymous())) |> (response -> (response#data, GraphqlTestKit.firstMessage(response)));
    let byContains = ask("{ blogs(stage: DRAFT, where: { title_contains: \"flix\" }, orderBy: [views_DESC]) { totalCount nodes { id views tags } } }");
    let byOr = ask("{ blogs(stage: DRAFT, where: { OR: [{ views_gte: 30 }, { id_eq: \"b1\" }] }, orderBy: [id_ASC]) { nodes { id } } }");
    let paged = ask("{ blogs(stage: DRAFT, orderBy: [views_ASC], first: 1, skip: 1) { totalCount nodes { title } } }");
    let one = ask("{ blog(id: \"b2\", stage: DRAFT) { title views stage } }");
    let published = ask("{ blogs { totalCount } blog(id: \"b1\") { id } }");
    Pool.close(pool);
    Assert.assertEq(
        expected = (
            (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(2), "nodes" => Value.List(
                Value.Obj(Map#{ "id" => Value.Str("b3"), "views" => Value.Float(20.0), "tags" => Value.List(Nil) }) ::
                Value.Obj(Map#{ "id" => Value.Str("b1"), "views" => Value.Float(10.0), "tags" => Value.List(Value.Str("flix") :: Nil) }) :: Nil) }) }), None),
            (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str("b1") }) :: Value.Obj(Map#{ "id" => Value.Str("b2") }) :: Nil) }) }), None),
            (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(3), "nodes" => Value.List(Value.Obj(Map#{ "title" => Value.Str("flix と PostgreSQL") }) :: Nil) }) }), None),
            (Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "title" => Value.Str("Elm の話"), "views" => Value.Float(30.0), "stage" => Value.Str("DRAFT") }) }), None),
            (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }), "blog" => Value.Null }), None)),
        (byContains, byOr, paged, one, published))

/// 型の定義が変わるとエンジンが組み直される。フィールドを足せば引けるようになり、型を足せば query が増え、型を消せば query が消える。
///
///   blog { excerpt } ── 無い ──▶ addField(excerpt) ──▶ null で引ける
///   tags             ── 無い ──▶ create(tags)     ──▶ 引ける ──▶ delete(tags) ──▶ 無い
@Test
def testPgContentEngineRebuilds(): Unit \ {IO, Assert} =
    let pool = Pool.open(Pool.defaultConfig(PgTestSupport.config()));
    discard PgTestSupport.withDb(() -> IdGen.runWithFixed(Nil, seed));
    let cache = ContentEngine.create();
    let before = ContentEngine.current(cache, pool) |> Result.map(engine -> Graphql.runWithEngine(engine, () -> Graphql.execute(GraphqlTestKit.queryOnly("{ blog(id: \"b1\", stage: DRAFT) { excerpt } }"), Context.anonymous())) |> GraphqlTestKit.firstMessage |> Option.nonEmpty);
    let added = DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Pool.withLazyTx(pool, () -> {
        let blogs = ContentTypes.findByApiId(CmsTestKit.apiId("blogs")) |> CmsErr.orNotFound(Entity.ContentType, "blogs");
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("excerpt", FieldKind.TextArea, FieldConfig.empty()))
    })));
    let after = ContentEngine.current(cache, pool) |> Result.map(engine -> Graphql.runWithEngine(engine, () -> Graphql.execute(GraphqlTestKit.queryOnly("{ blog(id: \"b1\", stage: DRAFT) { excerpt } }"), Context.anonymous())) |> (response -> response#data));
    let askTags = () -> ContentEngine.current(cache, pool) |> Result.map(engine -> Graphql.runWithEngine(engine, () -> Graphql.execute(GraphqlTestKit.queryOnly("{ tags(stage: DRAFT) { totalCount } }"), Context.anonymous())) |> (response -> (response#data, GraphqlTestKit.firstMessage(response) |> Option.nonEmpty)));
    let noTags = askTags();
    let tagsCreated = DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Pool.withLazyTx(pool, () -> {
        let tags = ContentTypes.create(CmsTestKit.typeDraft("tags", "タグ"));
        discard ContentTypes.addField(tags#id, CmsTestKit.fieldDraft("name", FieldKind.Text, FieldConfig.empty()));
        tags#id
    })));
    let withTags = askTags();
    let tagsDeleted = tagsCreated |> Result.map(Result.map(tagsId -> DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Pool.withLazyTx(pool, () -> ContentTypes.delete(tagsId))))));
    let withoutTags = askTags();
    Pool.close(pool);
    Assert.assertEq(
        expected = (Ok(true), Ok(Ok(())), Ok(Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "excerpt" => Value.Null }) })),
                    Ok((Value.Null, true)), Ok((Value.Obj(Map#{ "tags" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }), false)), Ok(Ok(Ok(Ok(())))), Ok((Value.Null, true))),
        (before, added, after, noTags, withTags, tagsDeleted, withoutTags))
