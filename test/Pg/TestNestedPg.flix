///
/// object と blocks を実 PostgreSQL で通しで動かす。子フィールドの定義、下書きの検証、コンテンツ API の入れ子と union。
///
mod TestNestedPg {

    use Util.Json.Json

    ///
    /// pages（title / related: object{label, post→pages} / sections: blocks[hero{headline}, cta{caption, url}]）を作る。
    ///
    def pagesWithNested(): TypeId \ Db + CmsErr + IdGen + Tenant + Session =
        let pages = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("pages", "ページ"));
        discard ContentTypes.addField(Session.grant(), pages#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        let related = ContentTypes.addField(Session.grant(), pages#id, CmsTestKit.fieldDraft("related", FieldKind.Object, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), pages#id, { parent = Some(related#id) | CmsTestKit.fieldDraft("label", FieldKind.Text, FieldConfig.empty()) });
        discard ContentTypes.addField(Session.grant(), pages#id, { parent = Some(related#id), target = Some(pages#id) | CmsTestKit.fieldDraft("post", FieldKind.Reference, FieldConfig.empty()) });
        let sections = ContentTypes.addField(Session.grant(), pages#id, { many = true | CmsTestKit.fieldDraft("sections", FieldKind.Blocks, FieldConfig.empty()) });
        let hero = ContentTypes.addField(Session.grant(), pages#id, { parent = Some(sections#id) | CmsTestKit.fieldDraft("hero", FieldKind.Object, FieldConfig.empty()) });
        discard ContentTypes.addField(Session.grant(), pages#id, { parent = Some(hero#id) | CmsTestKit.fieldDraft("headline", FieldKind.Text, FieldConfig.empty()) });
        let cta = ContentTypes.addField(Session.grant(), pages#id, { parent = Some(sections#id) | CmsTestKit.fieldDraft("cta", FieldKind.Object, FieldConfig.empty()) });
        discard ContentTypes.addField(Session.grant(), pages#id, { parent = Some(cta#id) | CmsTestKit.fieldDraft("caption", FieldKind.Text, FieldConfig.empty()) });
        discard ContentTypes.addField(Session.grant(), pages#id, { parent = Some(cta#id) | CmsTestKit.fieldDraft("url", FieldKind.Text, FieldConfig.empty()) });
        pages#id

    /// 子は親の children に入り、blocks の子は object しか置けない。
    @Test
    def testPgNestedDefinition(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let pages = pagesWithNested();
            let loaded = ContentTypes.get(Session.grant(), pages);
            let sections = loaded#fields |> List.find(field -> ApiId.text(field#apiId) == "sections");
            let badChild = CmsTestKit.failureMessage(() -> ContentTypes.addField(Session.grant(), pages, { parent = sections |> Option.map(field -> field#id) | CmsTestKit.fieldDraft("loose", FieldKind.Text, FieldConfig.empty()) }));
            (loaded#fields |> List.map(field -> ApiId.text(field#apiId)),
             sections |> Option.map(field -> Children.toList(field#children) |> List.map(variant -> (ApiId.text(variant#apiId), Children.toList(variant#children) |> List.map(child -> ApiId.text(child#apiId))))),
             badChild)
        });
        Assert.assertEq(expected = (
            List#{"title", "related", "sections"},
            Some(List#{("hero", List#{"headline"}), ("cta", List#{"caption", "url"})}),
            Err("parentFieldId: BLOCKS の子は OBJECT（variant）だけです")), result)

    /// 並べ替えは最上位のフィールドだけ。子の id を混ぜると invalid。
    @Test
    def testPgNestedReorderTopLevelOnly(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let pages = pagesWithNested();
            let top = ContentTypes.get(Session.grant(), pages) |> (owner -> owner#fields);
            let ids = top |> List.map(field -> field#id);
            let childId = FieldTree.flatten(top) |> List.find(field -> ApiId.text(field#apiId) == "headline") |> Option.map(field -> field#id);
            let reordered = ContentTypes.reorderFields(Session.grant(), pages, List.reverse(ids)) |> (owner -> owner#fields |> List.map(field -> ApiId.text(field#apiId)));
            let mixed = CmsTestKit.failurePaths(CmsTestKit.runWithResult(() -> ContentTypes.reorderFields(Session.grant(), pages, List.reverse(ids) |> List.drop(1) |> (rest -> Option.toList(childId) ::: rest))));
            (reordered, mixed)
        });
        Assert.assertEq(expected = (List#{"sections", "related", "title"}, List#{"ids"}), result)

    /// コンテンツ API では object が入れ子の型、blocks が union になり、中の参照も展開される。
    @Test
    def testPgNestedContentApi(): Unit \ {IO, Assert} =
        let seed = () -> CmsTestKit.withIds(List#{"g1", "g2"}, () -> {
            let pages = pagesWithNested();
            discard ContentEntries.create(Session.grant(), pages, None, CmsTestKit.entryData(List#{("title", Json.JString("Other"))}));
            discard ContentEntries.create(Session.grant(), pages, None, CmsTestKit.entryData(List#{
                ("title", Json.JString("Home")),
                ("related", Json.JObject(Map#{ "label" => Json.JString("see also"), "post" => Json.JString("g1") })),
                ("sections", Json.JArray(Vector#{
                    Json.JObject(Map#{ "blockType" => Json.JString("hero"), "headline" => Json.JString("Welcome") }),
                    Json.JObject(Map#{ "blockType" => Json.JString("cta"), "caption" => Json.JString("Go"), "url" => Json.JString("https://example.com") })}))}))
        });
        let page = PgTestSupport.withContentApi(seed, ask ->
            ask("{ page(id: \"g2\", stage: DRAFT) { title related { label post { title } } sections { __typename ... on PageSectionsHero { headline } ... on PageSectionsCta { caption url } } } }"));
        Assert.assertEq(
            expected = (Value.Obj(Map#{ "page" => Value.Obj(Map#{
                "title" => Value.Str("Home"),
                "related" => Value.Obj(Map#{ "label" => Value.Str("see also"), "post" => Value.Obj(Map#{ "title" => Value.Str("Other") }) }),
                "sections" => Value.List(
                    Value.Obj(Map#{ "__typename" => Value.Str("PageSectionsHero"), "headline" => Value.Str("Welcome") }) ::
                    Value.Obj(Map#{ "__typename" => Value.Str("PageSectionsCta"), "caption" => Value.Str("Go"), "url" => Value.Str("https://example.com") }) :: Nil) }) }), None),
            page)

}
