///
/// 参照（reference / select）を実 PostgreSQL で通しで動かす。entry_links、公開の依存、取り下げの防止、コンテンツ API の展開。
///
mod TestReferencesPg {

    use Util.Json.Json

    ///
    /// profiles（name）と blogs（title: required / category: select / profile: reference / tags: reference many）を作る。
    ///
    def typesWithReferences(): (TypeId, TypeId, TypeId) \ Db + CmsErr =
        let profiles = ContentTypes.create(CmsTestKit.typeDraft("profiles", "書き手"));
        discard ContentTypes.addField(profiles#id, CmsTestKit.fieldDraft("name", FieldKind.Text, FieldConfig.empty()));
        let tags = ContentTypes.create(CmsTestKit.typeDraft("tags", "タグ"));
        discard ContentTypes.addField(tags#id, CmsTestKit.fieldDraft("label", FieldKind.Text, FieldConfig.empty()));
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, { required = true | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("category", FieldKind.Select, { options = List#{"KNOWLEDGE", "NEWS"} | FieldConfig.empty() }));
        discard ContentTypes.addField(blogs#id, { target = Some(profiles#id) | CmsTestKit.fieldDraft("profile", FieldKind.Reference, FieldConfig.empty()) });
        discard ContentTypes.addField(blogs#id, { target = Some(tags#id), many = true | CmsTestKit.fieldDraft("tags", FieldKind.Reference, FieldConfig.empty()) });
        (profiles#id, blogs#id, tags#id)

    /// reference には型の存在と参照先が要り、select は選択肢の中だけ通る。
    @Test
    def testPgReferenceRules(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"r1"}, () -> {
            let (_, blogs, _) = typesWithReferences();
            let noTarget = CmsTestKit.failureMessage(() -> ContentTypes.addField(blogs, CmsTestKit.fieldDraft("author", FieldKind.Reference, FieldConfig.empty())));
            let missingType = CmsTestKit.failureMessage(() -> ContentTypes.addField(blogs, { target = Some(TypeId.TypeId(999i64)) | CmsTestKit.fieldDraft("author", FieldKind.Reference, FieldConfig.empty()) }));
            let badOptions = CmsTestKit.failureMessage(() -> ContentTypes.addField(blogs, CmsTestKit.fieldDraft("kind", FieldKind.Select, { options = List#{"bad-value"} | FieldConfig.empty() })));
            let badValue = CmsTestKit.failureMessage(() -> ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("x")), ("category", Json.JString("OTHER")), ("profile", Json.JString("not valid!"))})));
            (noTarget, missingType, badOptions, badValue)
        }));
        Assert.assertEq(expected = Ok(Ok((
            Err("targetTypeId: REFERENCE には参照先の型が要ります"),
            Err("targetTypeId: 型 '999' がありません"),
            Err("config.options: 選択肢は UPPER_SNAKE（[A-Z][A-Z0-9_]*）にしてください"),
            Err("fields.category: 選択肢（KNOWLEDGE, NEWS）にありません; fields.profile: entry の id（英数字と _ - を 1 〜 64 文字）にしてください")))), result)

    /// 参照先が未公開なら publish は止まり、withDependencies で一緒に公開できる。公開中に参照されている物は取り下げられない。
    ///
    ///   blog b1 → profile p1、tags [t1, t2]
    ///   publish(b1) ✗（p1, t1, t2 が未公開）→ publish(b1, withDependencies) ✓ → unpublish(p1) ✗ → unpublish(b1) ✓ → unpublish(p1) ✓
    @Test
    def testPgPublishDependencies(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"p1", "t1", "t2", "b1"}, () -> {
            let (profiles, blogs, tags) = typesWithReferences();
            let profile = ContentEntries.create(profiles, None, CmsTestKit.entryData(List#{("name", Json.JString("abab"))}));
            let tagA = ContentEntries.create(tags, None, CmsTestKit.entryData(List#{("label", Json.JString("flix"))}));
            let tagB = ContentEntries.create(tags, None, CmsTestKit.entryData(List#{("label", Json.JString("graphql"))}));
            let blog = ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("Hello")), ("profile", Json.JString("p1")), ("tags", Json.JArray(Vector#{Json.JString("t1"), Json.JString("t2")}))}));
            let blocked = CmsTestKit.failureMessage(() -> ContentEntries.publish(blog#id, "tester", false));
            let published = ContentEntries.publish(blog#id, "tester", true);
            let deps = List#{profile#id, tagA#id, tagB#id} |> List.map(id -> ContentEntries.get(id) |> (entry -> entry#stage));
            let stuck = CmsTestKit.failureMessage(() -> ContentEntries.unpublish(profile#id));
            discard ContentEntries.unpublish(blog#id);
            let freed = ContentEntries.unpublish(profile#id);
            (blocked, published#stage, deps, stuck, freed#stage)
        }));
        Assert.assertEq(expected = Ok(Ok((
            Err("references: 参照先 'p1' が未公開です（withDependencies: true で一緒に公開できます）; references: 参照先 't1' が未公開です（withDependencies: true で一緒に公開できます）; references: 参照先 't2' が未公開です（withDependencies: true で一緒に公開できます）"),
            Stage.Published,
            List#{Stage.Published, Stage.Published, Stage.Published},
            Err("references: 公開中の entry 'b1' が参照しています。先にそちらを取り下げるか、参照を外してください"),
            Stage.Draft))), result)

    /// コンテンツ API で参照が展開され、select は enum、配列の参照は _contains で絞れる。参照の展開は同じ stage で行う。
    @Test
    def testPgContentApiReferences(): Unit \ {IO, Assert} =
        let seed = () -> CmsTestKit.withIds(List#{"p1", "t1", "t2", "b1", "b2"}, () -> {
            let (profiles, blogs, tags) = typesWithReferences();
            discard ContentEntries.create(profiles, None, CmsTestKit.entryData(List#{("name", Json.JString("abab"))}));
            discard ContentEntries.create(tags, None, CmsTestKit.entryData(List#{("label", Json.JString("flix"))}));
            discard ContentEntries.create(tags, None, CmsTestKit.entryData(List#{("label", Json.JString("graphql"))}));
            discard ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("One")), ("category", Json.JString("KNOWLEDGE")), ("profile", Json.JString("p1")), ("tags", Json.JArray(Vector#{Json.JString("t1"), Json.JString("t2")}))}));
            discard ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("Two")), ("category", Json.JString("NEWS")), ("tags", Json.JArray(Vector#{Json.JString("t2")}))}));
            discard ContentEntries.publish(CmsTestKit.entryId("b1"), "tester", true)
        });
        let (expanded, byTag, byCategory, sdl) = PgTestSupport.withContentApi(seed, ask ->
            (ask("{ blog(id: \"b1\") { title category profile { name } tags { label } } }"),
             ask("{ blogs(stage: DRAFT, where: { tags_contains: \"t1\" }) { nodes { id } } }"),
             ask("{ blogs(stage: DRAFT, where: { category_eq: \"NEWS\" }) { nodes { id } } }"),
             ask("{ __type(name: \"BlogCategory\") { enumValues { name } } }")));
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "title" => Value.Str("One"), "category" => Value.Str("KNOWLEDGE"), "profile" => Value.Obj(Map#{ "name" => Value.Str("abab") }), "tags" => Value.List(Value.Obj(Map#{ "label" => Value.Str("flix") }) :: Value.Obj(Map#{ "label" => Value.Str("graphql") }) :: Nil) }) }), None),
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str("b1") }) :: Nil) }) }), None),
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str("b2") }) :: Nil) }) }), None),
                (Value.Obj(Map#{ "__type" => Value.Obj(Map#{ "enumValues" => Value.List(Value.Obj(Map#{ "name" => Value.Str("KNOWLEDGE") }) :: Value.Obj(Map#{ "name" => Value.Str("NEWS") }) :: Nil) }) }), None)),
            (expanded, byTag, byCategory, sdl))

}
