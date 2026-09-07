///
/// コンテンツ API を実 PostgreSQL で通しで動かす。型を作り、entry を入れ、定義から組んだエンジンで引く。
///
mod TestContentApiPg {

    use Util.Json.Json

    ///
    /// blogs（title / views / tags）に 3 件。まだ公開は無いので DRAFT で引く。
    ///
    def seed(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("views", FieldKind.Number, FieldConfig.empty()));
        discard ContentTypes.addField(blogs#id, { many = true | CmsTestKit.fieldDraft("tags", FieldKind.Text, FieldConfig.empty()) });
        discard ContentEntries.create(blogs#id, Some(CmsTestKit.entryId("b1")), CmsTestKit.entryData(List#{("title", Json.JString("Flix で GraphQL")), ("views", CmsTestKit.intJson(10)), ("tags", Json.JArray(Vector#{Json.JString("flix")}))}));
        discard ContentEntries.create(blogs#id, Some(CmsTestKit.entryId("b2")), CmsTestKit.entryData(List#{("title", Json.JString("Elm の話")), ("views", CmsTestKit.intJson(30))}));
        discard ContentEntries.create(blogs#id, Some(CmsTestKit.entryId("b3")), CmsTestKit.entryData(List#{("title", Json.JString("flix と PostgreSQL")), ("views", CmsTestKit.intJson(20))}))

    /// where / orderBy / first / skip / stage が効き、値は kind の型で返る。PUBLISHED はまだ無いので 0 件。
    @Test
    def testPgContentApiQueries(): Unit \ {IO, Assert} =
        let (byContains, byOr, paged, one, published) = PgTestSupport.withContentApi(seed, ask ->
            (ask("{ blogs(stage: DRAFT, where: { title_contains: \"flix\" }, orderBy: [views_DESC]) { totalCount nodes { id views tags } } }"),
             ask("{ blogs(stage: DRAFT, where: { OR: [{ views_gte: 30 }, { id_eq: \"b1\" }] }, orderBy: [id_ASC]) { nodes { id } } }"),
             ask("{ blogs(stage: DRAFT, orderBy: [views_ASC], first: 1, skip: 1) { totalCount nodes { title } } }"),
             ask("{ blog(id: \"b2\", stage: DRAFT) { title views stage } }"),
             ask("{ blogs { totalCount } blog(id: \"b1\") { id } }")));
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

    /// 規則外の id で絞ると全件ではなく 0 件（条件が消えない）。OR: [] も「どれにも合わない」なので 0 件。
    @Test
    def testPgContentApiEmptyFiltersMatchNothing(): Unit \ {IO, Assert} =
        let none = (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }), None);
        let (byBadId, byBadIdIn, byEmptyOr, byEmptyGroup) = PgTestSupport.withContentApi(seed, ask ->
            (ask("{ blogs(stage: DRAFT, where: { id_eq: \"not an id!\" }) { totalCount } }"),
             ask("{ blogs(stage: DRAFT, where: { id_in: [\"not an id!\"] }) { totalCount } }"),
             ask("{ blogs(stage: DRAFT, where: { OR: [] }) { totalCount } }"),
             ask("{ blogs(stage: DRAFT, where: { OR: [{}] }) { totalCount } }")));
        Assert.assertEq(expected = (none, none, none, none), (byBadId, byBadIdIn, byEmptyOr, byEmptyGroup))

    /// 検証をすり抜けた古い値（配列のはずの tags が文字列、数値のはずの views が文字列）があっても、絞り込みと並び替えは落ちずにその entry を外す。
    @Test
    def testPgContentApiTolerantOfStaleShapes(): Unit \ {IO, Assert} =
        let stale = () -> {
            seed();
            discard EntriesQueries.upsertContent({ entryId = "b3", stage = "draft", data = Util.Json.Json.JObject(Map#{ "title" => Util.Json.Json.JString("stale"), "tags" => Util.Json.Json.JString("flix"), "views" => Util.Json.Json.JString("many") }) })
        };
        let (byTag, byViews, ordered) = PgTestSupport.withContentApi(stale, ask ->
            (ask("{ blogs(stage: DRAFT, where: { tags_contains: \"flix\" }) { nodes { id } } }"),
             ask("{ blogs(stage: DRAFT, where: { views_gte: 0 }) { nodes { id } } }"),
             ask("{ blogs(stage: DRAFT, orderBy: [views_DESC]) { totalCount } }")));
        Assert.assertEq(
            expected = ((Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str("b1") }) :: Nil) }) }), None),
                        (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str("b2") }) :: Value.Obj(Map#{ "id" => Value.Str("b1") }) :: Nil) }) }), None),
                        (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(3) }) }), None)),
            (byTag, byViews, ordered))

    /// 型の定義が変わるとエンジンが組み直される。フィールドを足せば引けるようになり、型を足せば query が増え、型を消せば query が消える。
    ///
    ///   blog { excerpt } ── 無い ──▶ addField(excerpt) ──▶ null で引ける
    ///   tags             ── 無い ──▶ create(tags)     ──▶ 引ける ──▶ delete(tags) ──▶ 無い
    @Test
    def testPgContentEngineRebuilds(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withContentApiAndPool(seed, (pool, ask) -> {
            let before = ask("{ blog(id: \"b1\", stage: DRAFT) { excerpt } }") |> snd |> GraphqlTestKit.isValidationError;
            let added = PgTestSupport.mutate(pool, () -> {
                let blogs = ContentTypes.findByApiId(CmsTestKit.apiId("blogs")) |> CmsErr.orNotFound(Entity.ContentType, "blogs");
                discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("excerpt", FieldKind.TextArea, FieldConfig.empty()))
            });
            let after = ask("{ blog(id: \"b1\", stage: DRAFT) { excerpt } }") |> fst;
            let askTags = () -> ask("{ tags(stage: DRAFT) { totalCount } }") |> (found -> (fst(found), snd(found) |> GraphqlTestKit.isValidationError));
            let noTags = askTags();
            let tagsCreated = PgTestSupport.mutate(pool, () -> {
                let tags = ContentTypes.create(CmsTestKit.typeDraft("tags", "タグ"));
                discard ContentTypes.addField(tags#id, CmsTestKit.fieldDraft("name", FieldKind.Text, FieldConfig.empty()));
                tags#id
            });
            let withTags = askTags();
            let tagsDeleted = tagsCreated |> Result.map(Result.map(tagsId -> PgTestSupport.mutate(pool, () -> ContentTypes.delete(tagsId))));
            let withoutTags = askTags();
            (before, added, after, noTags, withTags, tagsDeleted, withoutTags)
        });
        Assert.assertEq(
            expected = (true, Ok(Ok(())), Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "excerpt" => Value.Null }) }),
                        (Value.Null, true), (Value.Obj(Map#{ "tags" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }), false), Ok(Ok(Ok(Ok(())))), (Value.Null, true)),
            outcome)

}
