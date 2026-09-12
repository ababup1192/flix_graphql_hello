///
/// DATE と複数選択の SELECT を実 PostgreSQL で通しで動かす。型を作り、entry を入れて公開し、コンテンツ API の絞り込み・並び替えで引く。
///
mod TestDateAndSelectPg {

    use Util.Json.Json

    ///
    /// events（title / heldOn: DATE / topics: SELECT の配列）に 3 件作って公開する。
    ///
    ///   e1  2026-09-01T00:00:00Z  topics: NEWS
    ///   e2  2026-09-10T09:00:00Z  topics: NEWS, TECH
    ///   e3  2026-09-20T09:00:00Z  topics: TECH
    ///
    def seed(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let events = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("events", "イベント"));
        discard ContentTypes.addField(Session.grant(), events#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), events#id, CmsTestKit.fieldDraft("heldOn", FieldKind.Date, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), events#id, { many = true | CmsTestKit.fieldDraft("topics", FieldKind.Select, { options = List#{"NEWS", "TECH"} | FieldConfig.empty() }) });
        let topics = names -> Json.JArray(names |> List.map(Json.JString) |> List.toVector);
        discard ContentEntries.create(Session.grant(), events#id, Some(CmsTestKit.entryId("e1")), CmsTestKit.entryData(List#{("title", Json.JString("e1")), ("heldOn", Json.JString("2026-09-01T00:00:00Z")), ("topics", topics(List#{"NEWS"}))}));
        discard ContentEntries.create(Session.grant(), events#id, Some(CmsTestKit.entryId("e2")), CmsTestKit.entryData(List#{("title", Json.JString("e2")), ("heldOn", Json.JString("2026-09-10T09:00:00Z")), ("topics", topics(List#{"NEWS", "TECH"}))}));
        discard ContentEntries.create(Session.grant(), events#id, Some(CmsTestKit.entryId("e3")), CmsTestKit.entryData(List#{("title", Json.JString("e3")), ("heldOn", Json.JString("2026-09-20T09:00:00Z")), ("topics", topics(List#{"TECH"}))}));
        List.forEach(id -> discard ContentEntries.publish(Session.grant(), CmsTestKit.entryId(id), "tester", false), List#{"e1", "e2", "e3"})

    /// DATE は保存した UTC の形のまま返り、_gte / _lt は timestamptz で比べ（引数は日付だけでも offset 付きでも効く）、_DESC で並ぶ。
    @Test
    def testPgDateFilterAndOrder(): Unit \ {IO, Assert} =
        let ids = nodes -> Value.Obj(Map#{ "events" => Value.Obj(Map#{ "nodes" => Value.List(nodes |> List.map(id -> Value.Obj(Map#{ "id" => Value.Str(id) }))) }) });
        let (values, since, before, between, latestFirst, badDate) = PgTestSupport.withContentApi(seed, ask ->
            (ask("{ events(orderBy: [id_ASC]) { nodes { heldOn } } }"),
             ask("{ events(where: { heldOn_gte: \"2026-09-10T09:00:00Z\" }, orderBy: [id_ASC]) { nodes { id } } }"),
             ask("{ events(where: { heldOn_lt: \"2026-09-10\" }, orderBy: [id_ASC]) { nodes { id } } }"),
             ask("{ events(where: { heldOn_gt: \"2026-09-01\", heldOn_lte: \"2026-09-20T09:00:00Z\" }, orderBy: [id_ASC]) { nodes { id } } }"),
             ask("{ events(orderBy: [heldOn_DESC]) { nodes { id } } }"),
             ask("{ events(where: { heldOn_gte: \"someday\" }) { totalCount } }")));
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "events" => Value.Obj(Map#{ "nodes" => Value.List(
                    Value.Obj(Map#{ "heldOn" => Value.Str("2026-09-01T00:00:00Z") }) ::
                    Value.Obj(Map#{ "heldOn" => Value.Str("2026-09-10T09:00:00Z") }) ::
                    Value.Obj(Map#{ "heldOn" => Value.Str("2026-09-20T09:00:00Z") }) :: Nil) }) }), None),
                (ids(List#{"e2", "e3"}), None),
                (ids(List#{"e1"}), None),
                (ids(List#{"e2", "e3"}), None),
                (ids(List#{"e3", "e2", "e1"}), None),
                (Value.Obj(Map#{ "events" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }), None)),
            (values, since, before, between, latestFirst, badDate))

    /// 複数選択の SELECT は enum の配列で返り、_contains は選択肢 1 つを含む物を返す。選択肢に無い値は GraphQL の検証で落ちる。
    @Test
    def testPgMultiSelect(): Unit \ {IO, Assert} =
        let (values, byTech, byNews, unknown) = PgTestSupport.withContentApi(seed, ask ->
            (ask("{ events(orderBy: [id_ASC]) { nodes { topics } } }"),
             ask("{ events(where: { topics_contains: TECH }, orderBy: [id_ASC]) { nodes { id } } }"),
             ask("{ events(where: { topics_contains: NEWS }, orderBy: [id_ASC]) { totalCount } }"),
             ask("{ events(where: { topics_contains: SPORTS }) { totalCount } }") |> snd |> GraphqlTestKit.isValidationError));
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "events" => Value.Obj(Map#{ "nodes" => Value.List(
                    Value.Obj(Map#{ "topics" => Value.List(Value.Str("NEWS") :: Nil) }) ::
                    Value.Obj(Map#{ "topics" => Value.List(Value.Str("NEWS") :: Value.Str("TECH") :: Nil) }) ::
                    Value.Obj(Map#{ "topics" => Value.List(Value.Str("TECH") :: Nil) }) :: Nil) }) }), None),
                (Value.Obj(Map#{ "events" => Value.Obj(Map#{ "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str("e2") }) :: Value.Obj(Map#{ "id" => Value.Str("e3") }) :: Nil) }) }), None),
                (Value.Obj(Map#{ "events" => Value.Obj(Map#{ "totalCount" => Value.Int(2) }) }), None),
                true),
            (values, byTech, byNews, unknown))

    /// 管理側の検査: DATE は UTC の ISO 8601 ちょうど 1 通りだけ通る。日付だけ・offset 付き・ミリ秒付き・でたらめは invalid で、
    /// 直せる値は言い分に送るべき形が載る。複数選択に選択肢の外の値も invalid。
    @Test
    def testPgDateAndSelectValidation(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withDb(() -> {
            let events = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("events", "イベント"));
            discard ContentTypes.addField(Session.grant(), events#id, CmsTestKit.fieldDraft("heldOn", FieldKind.Date, FieldConfig.empty()));
            discard ContentTypes.addField(Session.grant(), events#id, { many = true | CmsTestKit.fieldDraft("topics", FieldKind.Select, { options = List#{"NEWS"} | FieldConfig.empty() }) });
            let write = value -> ContentEntries.create(Session.grant(), events#id, None, CmsTestKit.entryData(List#{("heldOn", Json.JString(value))}));
            let paths = value -> CmsTestKit.failurePaths(CmsTestKit.runWithResult(() -> write(value)));
            let badTopic = CmsTestKit.failurePaths(CmsTestKit.runWithResult(() -> ContentEntries.create(Session.grant(), events#id, None, CmsTestKit.entryData(List#{("topics", Json.JArray(Vector#{Json.JString("SPORTS")}))}))));
            let saved = write("2026-09-08T00:00:00Z");
            (List#{paths("2026-09-08"), paths("2026-09-08T18:00:00+09:00"), paths("2026-09-08T00:00:00.000Z"), paths("someday")},
             badTopic, Map.get(CmsTestKit.apiId("heldOn"), saved#data))
        });
        let bad = List#{"fields.heldOn"};
        Assert.assertEq(expected = (List#{bad, bad, bad, bad}, List#{"fields.topics[0]"}, Some(Json.JString("2026-09-08T00:00:00Z"))), outcome)

    ///
    /// milestones（name / due: DATE_ONLY）に 3 件作って公開する。
    ///
    ///   m1  2026-09-01   m2  2026-09-10   m3  2026-09-20
    ///
    def seedDateOnly(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let milestones = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("milestones", "節目"));
        discard ContentTypes.addField(Session.grant(), milestones#id, CmsTestKit.fieldDraft("name", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), milestones#id, CmsTestKit.fieldDraft("due", FieldKind.DateOnly, FieldConfig.empty()));
        List#{("m1", "2026-09-01"), ("m2", "2026-09-10"), ("m3", "2026-09-20")} |> List.forEach(match (id, due) ->
            discard ContentEntries.create(Session.grant(), milestones#id, Some(CmsTestKit.entryId(id)),
                CmsTestKit.entryData(List#{("name", Json.JString(id)), ("due", Json.JString(due))})));
        List.forEach(id -> discard ContentEntries.publish(Session.grant(), CmsTestKit.entryId(id), "tester", false), List#{"m1", "m2", "m3"})

    /// DATE_ONLY は保存した日付のまま返り、_gte / _lt / _eq は ::date で比べ（引数は時刻付きでも UTC の日付として読む）、_DESC で並ぶ。
    @Test
    def testPgDateOnlyFilterAndOrder(): Unit \ {IO, Assert} =
        let ids = names -> Value.Obj(Map#{ "milestones" => Value.Obj(Map#{ "nodes" => Value.List(names |> List.map(id -> Value.Obj(Map#{ "id" => Value.Str(id) }))) }) });
        let (values, since, before, exact, byInstant, latestFirst, badDay) = PgTestSupport.withContentApi(seedDateOnly, ask ->
            (ask("{ milestones(orderBy: [id_ASC]) { nodes { due } } }"),
             ask("{ milestones(where: { due_gte: \"2026-09-10\" }, orderBy: [id_ASC]) { nodes { id } } }"),
             ask("{ milestones(where: { due_lt: \"2026-09-10\" }, orderBy: [id_ASC]) { nodes { id } } }"),
             ask("{ milestones(where: { due_eq: \"2026-09-20\" }, orderBy: [id_ASC]) { nodes { id } } }"),
             ask("{ milestones(where: { due_gt: \"2026-09-10T23:59:59Z\" }, orderBy: [id_ASC]) { nodes { id } } }"),
             ask("{ milestones(orderBy: [due_DESC]) { nodes { id } } }"),
             ask("{ milestones(where: { due_gte: \"someday\" }) { totalCount } }")));
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "milestones" => Value.Obj(Map#{ "nodes" => Value.List(
                    Value.Obj(Map#{ "due" => Value.Str("2026-09-01") }) ::
                    Value.Obj(Map#{ "due" => Value.Str("2026-09-10") }) ::
                    Value.Obj(Map#{ "due" => Value.Str("2026-09-20") }) :: Nil) }) }), None),
                (ids(List#{"m2", "m3"}), None),
                (ids(List#{"m1"}), None),
                (ids(List#{"m3"}), None),
                (ids(List#{"m3"}), None),
                (ids(List#{"m3", "m2", "m1"}), None),
                (Value.Obj(Map#{ "milestones" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }), None)),
            (values, since, before, exact, byInstant, latestFirst, badDay))

    /// DATE_ONLY で並べた cursor（値は epoch day）で続きが読める。first: 1 を 3 回で m1 → m2 → m3。
    @Test
    def testPgDateOnlyCursor(): Unit \ {IO, Assert} =
        let page = response -> (GraphqlTestKit.listAt(List#{"milestones", "nodes"}, response) |> List.filterMap(node -> Value.field("id", node) |> Value.asStr),
                                Value.path(List#{"milestones", "pageInfo", "endCursor"}, fst(response)) |> Value.asStr |> Option.getWithDefault(""));
        let pages = PgTestSupport.withContentApi(seedDateOnly, ask -> {
            let read = after -> page(ask("{ milestones(orderBy: [due_ASC], first: 1${after}) { nodes { id } pageInfo { endCursor } } }"));
            let (first, c1) = read("");
            let (second, c2) = read(", after: \"${c1}\"");
            let (third, _) = read(", after: \"${c2}\"");
            (first, second, third)
        });
        Assert.assertEq(expected = (List#{"m1"}, List#{"m2"}, List#{"m3"}), pages)

    /// 管理側の検査: DATE_ONLY は `2026-09-09` の形だけ通る。時刻付き・ゼロ詰めなし・暦にない日は invalid。
    @Test
    def testPgDateOnlyValidation(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withDb(() -> {
            let milestones = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("milestones", "節目"));
            discard ContentTypes.addField(Session.grant(), milestones#id, CmsTestKit.fieldDraft("due", FieldKind.DateOnly, FieldConfig.empty()));
            let write = value -> ContentEntries.create(Session.grant(), milestones#id, None, CmsTestKit.entryData(List#{("due", Json.JString(value))}));
            let paths = value -> CmsTestKit.failurePaths(CmsTestKit.runWithResult(() -> write(value)));
            let saved = write("2026-09-09");
            (List#{paths("2026-09-09T00:00:00Z"), paths("2026-9-9"), paths("2023-02-29"), paths("someday")},
             Map.get(CmsTestKit.apiId("due"), saved#data))
        });
        let bad = List#{"fields.due"};
        Assert.assertEq(expected = (List#{bad, bad, bad, bad}, Some(Json.JString("2026-09-09"))), outcome)

    /// システムの日時の絞り込み。コンテンツ API の publishedAt_gte / createdAt_lt は entries の列で比べる。
    /// 未来から絞れば 0 件、過去から絞れば全件（3 件とも今公開した物）。
    @Test
    def testPgSystemDateFilter(): Unit \ {IO, Assert} =
        let totals = PgTestSupport.withContentApi(seed, ask ->
            (ask("{ events(where: { publishedAt_gte: \"2000-01-01T00:00:00Z\" }) { totalCount } }"),
             ask("{ events(where: { publishedAt_gte: \"2999-01-01T00:00:00Z\" }) { totalCount } }"),
             ask("{ events(where: { createdAt_lt: \"2000-01-01\" }) { totalCount } }"),
             ask("{ events(where: { updatedAt_gt: \"2000-01-01T00:00:00Z\", updatedAt_lte: \"2999-01-01T00:00:00Z\" }) { totalCount } }")));
        let count = n -> (Value.Obj(Map#{ "events" => Value.Obj(Map#{ "totalCount" => Value.Int(n) }) }), None);
        Assert.assertEq(expected = (count(3), count(0), count(0), count(3)), totals)

}
