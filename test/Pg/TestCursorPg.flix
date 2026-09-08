///
/// コンテンツ API の cursor（after / pageInfo / edges）を実 PostgreSQL で通す。ページを辿って重複せず、途中で 1 件足しても崩れず、
/// orderBy が JSONB のフィールドでも同じで、他のプロジェクトの cursor は 0 件、after と skip の同時指定と壊れた cursor は INVALID。
///
mod TestCursorPg {

    use Util.Json.Json

    ///
    /// blogs（title / views）に b1 〜 b7。順に作るので更新順は b7 が最新。views は 10 〜 70 で、b3 だけ文字列（数値として NULL。並びの末尾）。
    ///
    def seed(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("views", FieldKind.Number, FieldConfig.empty()));
        List.range(1, 8) |> List.forEach(n ->
            discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b${n}")), CmsTestKit.entryData(List#{("title", Json.JString("t${n}")), ("views", CmsTestKit.intJson(n * 10))})));
        discard EntriesQueries.upsertContent({ entryId = "b3", stage = "draft", data = Json.JObject(Map#{ "title" => Json.JString("t3"), "views" => Json.JString("many") }) })

    /// 応答の nodes の id、pageInfo.hasNextPage、pageInfo.endCursor。
    def pageOf(response: (Value, Option[String])): (List[String], Value, Option[String]) =
        (GraphqlTestKit.listAt(List#{"blogs", "nodes"}, response) |> List.filterMap(node -> Value.field("id", node) |> Value.asStr),
         Value.path(List#{"blogs", "pageInfo", "hasNextPage"}, fst(response)),
         Value.path(List#{"blogs", "pageInfo", "endCursor"}, fst(response)) |> Value.asStr)

    /// 3 件ずつのページ。after があれば付ける。
    def pageQuery(orderBy: String, after: Option[String]): String =
        let afterArg = after |> Option.map(cursor -> ", after: \"${cursor}\"") |> Option.getWithDefault("");
        "{ blogs(stage: DRAFT, first: 3${orderBy}${afterArg}) { nodes { id } pageInfo { hasNextPage endCursor } } }"

    /// endCursor を after に渡して 3 ページ辿る。(ページごとの id, hasNextPage) の並び。
    def threePages(ask: String -> (Value, Option[String]) \ IO, orderBy: String, between: Unit -> Unit \ IO): List[(List[String], Value)] \ IO =
        let (first, firstNext, firstCursor) = pageOf(ask(pageQuery(orderBy, None)));
        between();
        let (second, secondNext, secondCursor) = pageOf(ask(pageQuery(orderBy, firstCursor)));
        let (third, thirdNext, _) = pageOf(ask(pageQuery(orderBy, secondCursor)));
        List#{(first, firstNext), (second, secondNext), (third, thirdNext)}

    ///
    /// 既定の並び（更新が新しい順）で 3 ページ辿ると 7 件が重複せず出て、最後のページで hasNextPage が false。
    /// 1 ページ目の後に b8（更新が一番新しい = 並びの先頭）を足しても、2 ページ目は 1 ページ目の末尾の次から（b8 は cursor より前なので出ない）。
    ///
    @Test
    def testPgCursorPagesWithoutDuplicates(): Unit \ {IO, Assert} =
        let pages = PgTestSupport.withContentApiAndPool(seed, (pool, ask) ->
            threePages(ask, "", () -> discard PgTestSupport.mutateOrBug(pool, () -> {
                let blogs = ContentTypes.findByApiId(Session.grant(), CmsTestKit.apiId("blogs")) |> CmsErr.orNotFound(Entity.ContentType, "blogs");
                ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b8")), CmsTestKit.entryData(List#{("title", Json.JString("t8"))}))
            })));
        Assert.assertEq(
            expected = List#{(List#{"b7", "b6", "b5"}, Value.Bool(true)), (List#{"b4", "b3", "b2"}, Value.Bool(true)), (List#{"b1"}, Value.Bool(false))},
            pages)

    ///
    /// orderBy が JSONB のフィールド（views）でも同じ。ASC は 10, 20, 40, …、DESC は 70, 60, …。
    /// 数値でない b3 は NULL なので、どちらの向きでも末尾のページに 1 件で出る。
    ///
    @Test
    def testPgCursorOrderByJsonbField(): Unit \ {IO, Assert} =
        let (ascending, descending) = PgTestSupport.withContentApi(seed, ask ->
            (threePages(ask, ", orderBy: [views_ASC]", () -> ()), threePages(ask, ", orderBy: [views_DESC]", () -> ())));
        Assert.assertEq(
            expected = (List#{(List#{"b1", "b2", "b4"}, Value.Bool(true)), (List#{"b5", "b6", "b7"}, Value.Bool(true)), (List#{"b3"}, Value.Bool(false))},
                        List#{(List#{"b7", "b6", "b5"}, Value.Bool(true)), (List#{"b4", "b2", "b1"}, Value.Bool(true)), (List#{"b3"}, Value.Bool(false))}),
            (ascending, descending))

    ///
    /// edges の cursor は nodes と同じ順で、末尾が endCursor。edges の cursor を after に渡しても続きが取れる（2 件目の次 = 3 件目から）。
    ///
    @Test
    def testPgCursorEdges(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withContentApi(seed, ask -> {
            let first = ask("{ blogs(stage: DRAFT, first: 3) { edges { cursor node { id } } pageInfo { endCursor } } }");
            let edges = GraphqlTestKit.listAt(List#{"blogs", "edges"}, first);
            let cursors = edges |> List.filterMap(edge -> Value.field("cursor", edge) |> Value.asStr);
            let secondCursor = List.drop(1, cursors) |> List.head |> Option.getWithDefault("");
            let (fromSecond, _, _) = pageOf(ask(pageQuery("", Some(secondCursor))));
            (edges |> List.filterMap(edge -> Value.path(List#{"node", "id"}, edge) |> Value.asStr),
             List.last(cursors) == (Value.path(List#{"blogs", "pageInfo", "endCursor"}, fst(first)) |> Value.asStr),
             fromSecond)
        });
        Assert.assertEq(expected = (List#{"b7", "b6", "b5"}, true, List#{"b5", "b4", "b3"}), outcome)

    ///
    /// 他のプロジェクトの entry の cursor（更新は一番新しい = 位置としては全件がその後）を渡しても、効かず 0 件で hasNextPage も false。
    ///
    @Test
    def testPgCursorOfOtherProjectMatchesNothing(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withContentApiAndPool(seed, (pool, ask) -> {
            let foreign = PgTestSupport.mutateOrBug(pool, () -> {
                let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
                PgTestSupport.asProject(shop, () -> {
                    let items = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("items", "商品"));
                    Cursor.encode(Cursor.ofEntry(Nil, Nil, ContentEntries.create(Session.grant(), items#id, Some(CmsTestKit.entryId("s1")), CmsTestKit.entryData(Nil))))
                })
            });
            pageOf(ask(pageQuery("", Some(foreign))))
        });
        Assert.assertEq(expected = ((Nil: List[String]), Value.Bool(false), None), outcome)

    /// errors[].message に文言を含むか。
    def mentions(text: String, response: (Value, Option[String])): Bool =
        snd(response) |> Option.map(String.contains(substr = text)) |> Option.getWithDefault(false)

    ///
    /// after と skip の同時指定、壊れた after、orderBy を変えた古い after は INVALID（data は null）。skip: 0 は指定なしなので通る。
    ///
    @Test
    def testPgCursorInvalid(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withContentApi(seed, ask -> {
            let (_, _, cursor) = pageOf(ask(pageQuery("", None)));
            let text = cursor |> Option.getWithDefault("");
            let both = ask("{ blogs(stage: DRAFT, first: 3, skip: 1, after: \"${text}\") { nodes { id } } }");
            let zeroSkip = ask("{ blogs(stage: DRAFT, first: 3, skip: 0, after: \"${text}\") { nodes { id } } }");
            let broken = ask("{ blogs(stage: DRAFT, first: 3, after: \"not-a-cursor\") { nodes { id } } }");
            let stale = ask("{ blogs(stage: DRAFT, first: 3, orderBy: [views_ASC], after: \"${text}\") { nodes { id } } }");
            (mentions("同時に指定できません", both), fst(both),
             GraphqlTestKit.listAt(List#{"blogs", "nodes"}, zeroSkip) |> List.length,
             mentions("cursor が壊れています", broken),
             mentions("orderBy と合いません", stale))
        });
        Assert.assertEq(expected = (true, Value.Null, 3, true, true), outcome)

}
