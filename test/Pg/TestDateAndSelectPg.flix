///
/// DATE と複数選択の SELECT を実 PostgreSQL で通しで動かす。型を作り、entry を入れて公開し、コンテンツ API の絞り込み・並び替えで引く。
///
mod TestDateAndSelectPg {

    use Util.Json.Json

    ///
    /// events（title / heldOn: DATE / topics: SELECT の配列）に 3 件作って公開する。
    ///
    ///   e1  2026-09-01（日付だけ → 0 時 UTC に揃う）  topics: NEWS
    ///   e2  2026-09-10T09:00:00Z                       topics: NEWS, TECH
    ///   e3  2026-09-20T18:00:00+09:00                  topics: TECH
    ///
    def seed(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let events = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("events", "イベント"));
        discard ContentTypes.addField(Session.grant(), events#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), events#id, CmsTestKit.fieldDraft("heldOn", FieldKind.Date, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), events#id, { many = true | CmsTestKit.fieldDraft("topics", FieldKind.Select, { options = List#{"NEWS", "TECH"} | FieldConfig.empty() }) });
        let topics = names -> Json.JArray(names |> List.map(Json.JString) |> List.toVector);
        discard ContentEntries.create(events#id, Some(CmsTestKit.entryId("e1")), CmsTestKit.entryData(List#{("title", Json.JString("e1")), ("heldOn", Json.JString("2026-09-01")), ("topics", topics(List#{"NEWS"}))}));
        discard ContentEntries.create(events#id, Some(CmsTestKit.entryId("e2")), CmsTestKit.entryData(List#{("title", Json.JString("e2")), ("heldOn", Json.JString("2026-09-10T09:00:00Z")), ("topics", topics(List#{"NEWS", "TECH"}))}));
        discard ContentEntries.create(events#id, Some(CmsTestKit.entryId("e3")), CmsTestKit.entryData(List#{("title", Json.JString("e3")), ("heldOn", Json.JString("2026-09-20T18:00:00+09:00")), ("topics", topics(List#{"TECH"}))}));
        List.forEach(id -> discard ContentEntries.publish(CmsTestKit.entryId(id), "tester", false), List#{"e1", "e2", "e3"})

    /// DATE は ISO 8601 で返り（日付だけの物は 0 時 UTC に揃う）、_gte / _lt は timestamptz で比べ（offset 付きの値も日付だけの引数も効く）、_DESC で並ぶ。
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
                    Value.Obj(Map#{ "heldOn" => Value.Str("2026-09-20T18:00:00+09:00") }) :: Nil) }) }), None),
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

    /// 管理側の検査: DATE にでたらめな文字列、複数選択に選択肢の外の値は invalid。日付だけの値は下書きに 0 時 UTC で保存される。
    @Test
    def testPgDateAndSelectValidation(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withDb(() -> {
            let events = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("events", "イベント"));
            discard ContentTypes.addField(Session.grant(), events#id, CmsTestKit.fieldDraft("heldOn", FieldKind.Date, FieldConfig.empty()));
            discard ContentTypes.addField(Session.grant(), events#id, { many = true | CmsTestKit.fieldDraft("topics", FieldKind.Select, { options = List#{"NEWS"} | FieldConfig.empty() }) });
            let badDate = CmsTestKit.failurePaths(CmsErr.runWithResult(() -> ContentEntries.create(events#id, None, CmsTestKit.entryData(List#{("heldOn", Json.JString("someday"))}))));
            let badTopic = CmsTestKit.failurePaths(CmsErr.runWithResult(() -> ContentEntries.create(events#id, None, CmsTestKit.entryData(List#{("topics", Json.JArray(Vector#{Json.JString("SPORTS")}))}))));
            let saved = ContentEntries.create(events#id, None, CmsTestKit.entryData(List#{("heldOn", Json.JString("2026-09-08"))}));
            (badDate, badTopic, Map.get(CmsTestKit.apiId("heldOn"), saved#data))
        });
        Assert.assertEq(expected = Ok(Ok((List#{"fields.heldOn"}, List#{"fields.topics[0]"}, Some(Json.JString("2026-09-08T00:00:00Z"))))), outcome)

}
