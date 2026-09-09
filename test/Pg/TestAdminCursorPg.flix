///
/// 管理 API の一覧の cursor と絞り込みを実 PostgreSQL で通す。entries の where / orderBy / after、assets の after、
/// webhookDeliveries / schedules の after（id が cursor）。
///
mod TestAdminCursorPg {

    use Util.Json.Json

    /// blogs（title / views）に b1 〜 b5（views 10 〜 50）を作り、b2 と b4 を公開する。
    def seed(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("views", FieldKind.Number, FieldConfig.empty()));
        List.range(1, 6) |> List.forEach(n ->
            discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b${n}")), CmsTestKit.entryData(List#{("title", Json.JString("t${n}")), ("views", CmsTestKit.intJson(n * 10))})));
        discard ContentEntries.publish(Session.grant(), CmsTestKit.entryId("b2"), "tester", false);
        discard ContentEntries.publish(Session.grant(), CmsTestKit.entryId("b4"), "tester", false)

    /// 応答の entries.nodes の id と pageInfo.endCursor。
    def idsAndCursor(response: (Value, Option[String])): (List[String], Option[String]) =
        (GraphqlTestKit.listAt(List#{"entries", "nodes"}, response) |> List.filterMap(node -> Value.field("id", node) |> Value.asStr),
         Value.path(List#{"entries", "pageInfo", "endCursor"}, fst(response)) |> Value.asStr)

    ///
    /// where（stage: PUBLISHED / views の範囲 / id_in）と orderBy（views_DESC、title_ASC）が SQL に落ち、after で続きが読める。
    /// after と skip の同時指定は INVALID、規則外の orderBy.field も INVALID。
    ///
    @Test
    def testPgAdminEntriesWhereOrderByAfter(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(seed, (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            let typeId = GraphqlTestKit.stringAt(List#{"contentType", "id"}, ask("{ contentType(apiId: \"blogs\") { id } }"));
            let published = ask("{ entries(typeId: \"${typeId}\", where: { stage: PUBLISHED }, orderBy: [{ field: \"title\", direction: ASC }]) { totalCount nodes { id } } }");
            let ranged = ask("{ entries(typeId: \"${typeId}\", where: { fields: [{ apiId: \"views\", op: GTE, value: 30 }], id_in: [\"b3\", \"b5\", \"b1\"] }, orderBy: [{ field: \"views\", direction: DESC }]) { totalCount nodes { id } } }");
            let (page1, cursor) = idsAndCursor(ask("{ entries(typeId: \"${typeId}\", orderBy: [{ field: \"views\", direction: DESC }], first: 2) { nodes { id } pageInfo { hasNextPage endCursor } } }"));
            let (page2, _) = idsAndCursor(ask("{ entries(typeId: \"${typeId}\", orderBy: [{ field: \"views\", direction: DESC }], first: 2, after: \"${cursor |> Option.getWithDefault("")}\") { nodes { id } pageInfo { hasNextPage endCursor } } }"));
            let both = ask("{ entries(typeId: \"${typeId}\", skip: 1, after: \"${cursor |> Option.getWithDefault("")}\") { nodes { id } } }");
            let badField = ask("{ entries(typeId: \"${typeId}\", orderBy: [{ field: \"Bad Name\", direction: ASC }]) { nodes { id } } }");
            (fst(published), fst(ranged), page1, page2,
             snd(both) |> Option.map(String.contains(substr = "同時に指定できません")),
             snd(badField) |> Option.map(String.contains(substr = "orderBy.field")))
        });
        Assert.assertEq(
            expected = (
                Value.Obj(Map#{ "entries" => Value.Obj(Map#{ "totalCount" => Value.Int(2), "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str("b2") }) :: Value.Obj(Map#{ "id" => Value.Str("b4") }) :: Nil) }) }),
                Value.Obj(Map#{ "entries" => Value.Obj(Map#{ "totalCount" => Value.Int(2), "nodes" => Value.List(Value.Obj(Map#{ "id" => Value.Str("b5") }) :: Value.Obj(Map#{ "id" => Value.Str("b3") }) :: Nil) }) }),
                List#{"b5", "b4"}, List#{"b3", "b2"}, Some(true), Some(true)),
            outcome)

    ///
    /// where のシステムの日時。createdAt / updatedAt / publishedAt を entries の列で比べる。
    /// 未公開の entry は published_at が NULL なので publishedAt の条件にはどれも合わない（b2 と b4 だけ）。
    /// 読めない値を渡すと 0 件（黙って全件に広がらない）。
    ///
    @Test
    def testPgAdminEntriesSystemDateFilter(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(seed, (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            let typeId = GraphqlTestKit.stringAt(List#{"contentType", "id"}, ask("{ contentType(apiId: \"blogs\") { id } }"));
            let total = filter -> Value.path(List#{"entries", "totalCount"},
                fst(ask("{ entries(typeId: \"${typeId}\", where: ${filter}) { totalCount } }"))) |> Value.asInt;
            (total("{ createdAt: { gte: \"2000-01-01T00:00:00Z\" } }"),
             total("{ createdAt: { gte: \"2999-01-01T00:00:00Z\" } }"),
             total("{ updatedAt: { gt: \"2000-01-01\", lte: \"2999-01-01T00:00:00Z\" } }"),
             total("{ publishedAt: { gte: \"2000-01-01T00:00:00Z\" } }"),
             total("{ createdAt: { gte: \"someday\" } }"))
        });
        Assert.assertEq(expected = (Some(5), Some(0), Some(5), Some(2), Some(0)), outcome)

    ///
    /// assets の after。3 件を作り、first: 2 → endCursor → 残りの 1 件。after と skip の同時指定は INVALID。
    ///
    @Test
    def testPgAdminAssetsAfter(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            List.range(0, 3) |> List.forEach(n -> discard ask("mutation { createUploadUrl(input: { fileName: \"a${n}.png\", mime: \"image/png\", size: 5 }) { asset { id } } }"));
            let page1 = ask("{ assets(first: 2) { nodes { id } edges { cursor node { id } } pageInfo { hasNextPage endCursor } } }");
            let cursor = Value.path(List#{"assets", "pageInfo", "endCursor"}, fst(page1)) |> Value.asStr |> Option.getWithDefault("");
            let page2 = ask("{ assets(first: 2, after: \"${cursor}\") { nodes { id } pageInfo { hasNextPage endCursor } } }");
            let both = ask("{ assets(skip: 1, after: \"${cursor}\") { nodes { id } } }");
            let idsOf = page -> GraphqlTestKit.listAt(List#{"assets", "nodes"}, page) |> List.filterMap(node -> Value.field("id", node) |> Value.asStr);
            let all = idsOf(ask("{ assets { nodes { id } } }"));
            (List.length(all), idsOf(page1) == List.take(2, all), Value.path(List#{"assets", "pageInfo", "hasNextPage"}, fst(page1)),
             idsOf(page2) == List.drop(2, all), Value.path(List#{"assets", "pageInfo", "hasNextPage"}, fst(page2)),
             GraphqlTestKit.listAt(List#{"assets", "edges"}, page1) |> List.filterMap(edge -> Value.field("cursor", edge) |> Value.asStr) |> List.last == Some(cursor),
             snd(both) |> Option.map(String.contains(substr = "同時に指定できません")))
        });
        Assert.assertEq(expected = (3, true, Value.Bool(true), true, Value.Bool(false), true, Some(true)), outcome)

    ///
    /// webhookDeliveries と schedules の after は id（ULID）。first: 1 で読んだ最後の id を after に渡すと、その次（古い方）が来る。
    ///
    @Test
    def testPgAdminUlidListsAfter(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(seed, (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            let webhookId = GraphqlTestKit.stringAt(List#{"createWebhook", "webhook", "id"}, ask("mutation { createWebhook(input: { name: \"w\", url: \"https://example.com/hook\", events: [ENTRY_PUBLISHED] }) { webhook { id } } }"));
            discard ask("mutation { publishEntry(id: \"b1\") { id } }");
            discard ask("mutation { publishEntry(id: \"b3\") { id } }");
            let deliveries = GraphqlTestKit.listAt(List#{"webhookDeliveries"}, ask("{ webhookDeliveries(webhookId: \"${webhookId}\") { id } }")) |> List.filterMap(delivery -> Value.field("id", delivery) |> Value.asStr);
            let firstDelivery = List.head(deliveries) |> Option.getWithDefault("");
            let afterDelivery = GraphqlTestKit.listAt(List#{"webhookDeliveries"}, ask("{ webhookDeliveries(webhookId: \"${webhookId}\", after: \"${firstDelivery}\") { id } }")) |> List.filterMap(delivery -> Value.field("id", delivery) |> Value.asStr);
            discard ask("mutation { schedulePublish(entryId: \"b5\", at: \"2100-01-01T00:00:00Z\") { id } }");
            discard ask("mutation { scheduleUnpublish(entryId: \"b5\", at: \"2100-01-02T00:00:00Z\") { id } }");
            let schedules = GraphqlTestKit.listAt(List#{"schedules"}, ask("{ schedules { id } }")) |> List.filterMap(schedule -> Value.field("id", schedule) |> Value.asStr);
            let firstSchedule = List.head(schedules) |> Option.getWithDefault("");
            let afterSchedule = GraphqlTestKit.listAt(List#{"schedules"}, ask("{ schedules(after: \"${firstSchedule}\") { id } }")) |> List.filterMap(schedule -> Value.field("id", schedule) |> Value.asStr);
            let afterScheduleOfEntry = GraphqlTestKit.listAt(List#{"schedules"}, ask("{ schedules(entryId: \"b5\", after: \"${firstSchedule}\") { id } }")) |> List.filterMap(schedule -> Value.field("id", schedule) |> Value.asStr);
            (List.length(deliveries), afterDelivery == List.drop(1, deliveries), List.length(schedules), afterSchedule == List.drop(1, schedules), afterScheduleOfEntry == List.drop(1, schedules))
        });
        Assert.assertEq(expected = (2, true, 2, true, true), outcome)

}
