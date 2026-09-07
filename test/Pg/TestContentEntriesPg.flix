///
/// ContentEntries を実 PostgreSQL で通しで動かす。
///
mod TestContentEntriesPg {

    use Util.Json.Json
    use CmsErr.CmsFailure

    ///
    /// blogs 型（title / views）を作って id を返す。
    ///
    def blogsWithFields(): TypeId \ Db + CmsErr + Tenant =
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, { maxLength = Some(10) | FieldConfig.empty() }));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("views", FieldKind.Number, FieldConfig.empty()));
        blogs#id

    /// 作る・読む・直す・消す。version は保存のたびに進み、JSONB を往復して中身が戻る。
    ///
    ///   create(a1) v1 → update(title) v2 → update(views: null で消す) v3 → delete → find = None
    @Test
    def testPgEntryLifecycle(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"a1"}, () -> {
            let blogs = blogsWithFields();
            let created = ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("hello")), ("views", CmsTestKit.intJson(3))}));
            let renamed = ContentEntries.update(created#id, CmsTestKit.entryData(List#{("title", Json.JString("hi"))}), created#version);
            let cleared = ContentEntries.update(created#id, CmsTestKit.entryData(List#{("views", Json.JNull)}), renamed#version);
            ContentEntries.delete(created#id);
            ((EntryId.text(created#id), created#version, created#stage, Map.size(created#data)),
             (renamed#version, Map.get(CmsTestKit.apiId("title"), renamed#data)),
             (cleared#version, Map.keysOf(cleared#data) |> Set.toList |> List.map(ApiId.text)),
             ContentEntries.find(created#id) |> Option.isEmpty)
        }));
        Assert.assertEq(expected = Ok(Ok((("a1", 1, Stage.Draft, 2), (2, Some(Json.JString("hi"))), (3, List#{"title"}), true))), result)

    /// 古い version で保存すると conflict になり、中身は変わらない。
    @Test
    def testPgEntryConflict(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"c1"}, () -> {
            let blogs = blogsWithFields();
            let created = ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("v1"))}));
            discard ContentEntries.update(created#id, CmsTestKit.entryData(List#{("title", Json.JString("v2"))}), 1);
            let stale = CmsErr.runWithResult(() -> ContentEntries.update(created#id, CmsTestKit.entryData(List#{("title", Json.JString("v3"))}), 1));
            (stale |> Result.map(entry -> entry#version), ContentEntries.get(created#id) |> (entry -> Map.get(CmsTestKit.apiId("title"), entry#data)))
        }));
        Assert.assertEq(expected = Ok(Ok((Err(CmsFailure.Conflict(Entity.Entry, "c1", 2)), Some(Json.JString("v2"))))), result)

    /// 一覧は更新が新しい順、search で絞れ、totalCount は絞った後の件数。渡した id はそのまま使われる。
    @Test
    def testPgEntryList(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(Nil, () -> {
            let blogs = blogsWithFields();
            discard ContentEntries.create(blogs, Some(CmsTestKit.entryId("first")), CmsTestKit.entryData(List#{("title", Json.JString("apple"))}));
            discard ContentEntries.create(blogs, Some(CmsTestKit.entryId("second")), CmsTestKit.entryData(List#{("title", Json.JString("banana"))}));
            discard ContentEntries.create(blogs, Some(CmsTestKit.entryId("third")), CmsTestKit.entryData(List#{("title", Json.JString("apricot"))}));
            let all = ContentEntries.list(blogs, { search = "", first = 10, skip = 0 });
            let searched = ContentEntries.list(blogs, { search = "ap", first = 10, skip = 0 });
            let paged = ContentEntries.list(blogs, { search = "", first = 1, skip = 1 });
            (all#totalCount, searched#entries |> List.map(entry -> EntryId.text(entry#id)) |> List.sort, searched#totalCount, paged#entries |> List.length)
        }));
        Assert.assertEq(expected = Ok(Ok((3i64, List#{"first", "third"}, 2i64, 1))), result)

    /// search は値だけに当たり（キー名 "title" では当たらない）、% と _ はそのままの文字として当たる。
    @Test
    def testPgEntrySearchEscapes(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"s1", "s2"}, () -> {
            let blogs = blogsWithFields();
            discard ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("100% flix"))}));
            discard ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("plain"))}));
            let byKey = ContentEntries.list(blogs, { search = "title", first = 10, skip = 0 });
            let byPercent = ContentEntries.list(blogs, { search = "100%", first = 10, skip = 0 });
            let byBarePercent = ContentEntries.list(blogs, { search = "%", first = 10, skip = 0 });
            (byKey#totalCount, byPercent#totalCount, byBarePercent#totalCount)
        }));
        Assert.assertEq(expected = Ok(Ok((0i64, 1i64, 1i64))), result)

    /// ゴミ箱の entry と同じ id では作れない（PK が残っているので、500 ではなく invalid で止める）。
    @Test
    def testPgEntryIdNotReusedFromTrash(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"t1"}, () -> {
            let blogs = blogsWithFields();
            let created = ContentEntries.create(blogs, None, CmsTestKit.entryData(Nil));
            ContentEntries.delete(created#id);
            CmsTestKit.failureMessage(() -> ContentEntries.create(blogs, Some(created#id), CmsTestKit.entryData(Nil)))
        }));
        Assert.assertEq(expected = Ok(Ok(Err("id: 't1' は既にあります（ゴミ箱の物を含む）"))), result)

    /// 型に合わない中身は invalid で、entry が残っている型は消せない。
    @Test
    def testPgEntryGuards(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"g1"}, () -> {
            let blogs = blogsWithFields();
            let invalid = CmsTestKit.failureMessage(() -> ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("0123456789ab"))})));
            discard ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("ok"))}));
            let blocked = CmsTestKit.failureMessage(() -> ContentTypes.delete(blogs));
            (invalid, blocked)
        }));
        Assert.assertEq(expected = Ok(Ok((Err("fields.title: 10 文字以内にしてください"), Err("id: entry が 1 件あります。先に消してください")))), result)

    /// 管理 API のエンジンを通して JSON scalar が往復する。数値は Int、null で消す、規則外のキーは invalid。
    @Test
    def testPgAdminEntryRoundTrip(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(blogsWithFields, (schema, blogs) -> {
            let typeId = "${blogs}";
            let created = GraphqlTestKit.ask(schema,
                "mutation { createEntry(typeId: \"${typeId}\", id: \"e1\", fields: { title: \"hello\", views: 7 }) { id version stage fields } }");
            let updated = GraphqlTestKit.ask(schema,
                "mutation { updateEntry(id: \"e1\", expectedVersion: 1, fields: { views: null }) { version fields } }");
            let badKey = GraphqlTestKit.askRequest(schema, GraphqlTestKit.request(
                "mutation($f: JSON!) { updateEntry(id: \"e1\", expectedVersion: 2, fields: $f) { version } }",
                Map#{ "f" => Value.Obj(Map#{ "Bad Key" => Value.Int(1) }) })) |> snd;
            let listed = GraphqlTestKit.ask(schema, "{ entries(typeId: \"${typeId}\") { totalCount nodes { id } } }");
            (created, updated, badKey, listed)
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "createEntry" => Value.Obj(Map#{ "id" => Value.Str("e1"), "version" => Value.Int(1), "stage" => Value.Str("DRAFT"), "fields" => Value.Obj(Map#{ "title" => Value.Str("hello"), "views" => Value.Int(7) }) }) }), None),
                (Value.Obj(Map#{ "updateEntry" => Value.Obj(Map#{ "version" => Value.Int(2), "fields" => Value.Obj(Map#{ "title" => Value.Str("hello") }) }) }), None),
                Some("fields.Bad Key: フィールドの apiId は lowerCamel の識別子（[a-z][A-Za-z0-9]*）です"),
                (Value.Obj(Map#{ "entries" => Value.Obj(Map#{ "totalCount" => Value.Int(1), "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str("e1") }) :: Nil) }) }), None)),
            outcome)

}
