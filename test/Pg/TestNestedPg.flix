use Util.Json.Json

///
/// object と blocks を実 PostgreSQL で通しで動かす。子フィールドの定義、下書きの検証、コンテンツ API の入れ子と union。
///

///
/// pages（title / related: object{label, post→pages} / sections: blocks[hero{headline}, cta{caption, url}]）を作る。
///
def pagesWithNested(): TypeId \ Db + CmsErr =
    let pages = ContentTypes.create(CmsTestKit.typeDraft("pages", "ページ"));
    discard ContentTypes.addField(pages#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
    let related = ContentTypes.addField(pages#id, CmsTestKit.fieldDraft("related", FieldKind.Object, FieldConfig.empty()));
    discard ContentTypes.addField(pages#id, { parent = Some(related#id) | CmsTestKit.fieldDraft("label", FieldKind.Text, FieldConfig.empty()) });
    discard ContentTypes.addField(pages#id, { parent = Some(related#id), target = Some(pages#id) | CmsTestKit.fieldDraft("post", FieldKind.Reference, FieldConfig.empty()) });
    let sections = ContentTypes.addField(pages#id, { many = true | CmsTestKit.fieldDraft("sections", FieldKind.Blocks, FieldConfig.empty()) });
    let hero = ContentTypes.addField(pages#id, { parent = Some(sections#id) | CmsTestKit.fieldDraft("hero", FieldKind.Object, FieldConfig.empty()) });
    discard ContentTypes.addField(pages#id, { parent = Some(hero#id) | CmsTestKit.fieldDraft("headline", FieldKind.Text, FieldConfig.empty()) });
    let cta = ContentTypes.addField(pages#id, { parent = Some(sections#id) | CmsTestKit.fieldDraft("cta", FieldKind.Object, FieldConfig.empty()) });
    discard ContentTypes.addField(pages#id, { parent = Some(cta#id) | CmsTestKit.fieldDraft("caption", FieldKind.Text, FieldConfig.empty()) });
    discard ContentTypes.addField(pages#id, { parent = Some(cta#id) | CmsTestKit.fieldDraft("url", FieldKind.Text, FieldConfig.empty()) });
    pages#id

/// 子は親の children に入り、blocks の子は object しか置けない。
@Test
def testPgNestedDefinition(): Unit \ {IO, Assert} =
    let result = PgTestSupport.withDb(() -> IdGen.runWithFixed(Nil, () -> {
        let pages = pagesWithNested();
        let loaded = ContentTypes.get(pages);
        let sections = loaded#fields |> List.find(field -> ApiId.text(field#apiId) == "sections");
        let badChild = CmsErr.runWithResult(() -> ContentTypes.addField(pages, { parent = sections |> Option.map(field -> field#id) | CmsTestKit.fieldDraft("loose", FieldKind.Text, FieldConfig.empty()) }))
            |> Result.map(field -> field#position) |> Result.mapErr(CmsErr.toMessage);
        (loaded#fields |> List.map(field -> ApiId.text(field#apiId)),
         sections |> Option.map(field -> Children.toList(field#children) |> List.map(variant -> (ApiId.text(variant#apiId), Children.toList(variant#children) |> List.map(child -> ApiId.text(child#apiId))))),
         badChild)
    }));
    Assert.assertEq(expected = Ok(Ok((
        List#{"title", "related", "sections"},
        Some(List#{("hero", List#{"headline"}), ("cta", List#{"caption", "url"})}),
        Err("parentFieldId: BLOCKS の子は OBJECT（variant）だけです")))), result)

/// コンテンツ API では object が入れ子の型、blocks が union になり、中の参照も展開される。
@Test
def testPgNestedContentApi(): Unit \ {IO, Assert} =
    let pool = Pool.open(Pool.defaultConfig(PgTestSupport.config()));
    discard PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"g1", "g2"}, () -> {
        let pages = pagesWithNested();
        discard ContentEntries.create(pages, None, CmsTestKit.entryData(List#{("title", Json.JString("Other"))}));
        discard ContentEntries.create(pages, None, CmsTestKit.entryData(List#{
            ("title", Json.JString("Home")),
            ("related", Json.JObject(Map#{ "label" => Json.JString("see also"), "post" => Json.JString("g1") })),
            ("sections", Json.JArray(Vector#{
                Json.JObject(Map#{ "blockType" => Json.JString("hero"), "headline" => Json.JString("Welcome") }),
                Json.JObject(Map#{ "blockType" => Json.JString("cta"), "caption" => Json.JString("Go"), "url" => Json.JString("https://example.com") })}))}))
    }));
    let cache = ContentEngine.create();
    let ask = queryText -> match ContentEngine.current(cache, pool) {
        case Ok(engine)   => Graphql.runWithEngine(engine, () -> Graphql.execute(GraphqlTestKit.queryOnly(queryText), Context.anonymous())) |> (response -> (response#data, GraphqlTestKit.firstMessage(response)))
        case Err(message) => bug!(message)
    };
    let page = ask("{ page(id: \"g2\", stage: DRAFT) { title related { label post { title } } sections { __typename ... on PageSectionsHero { headline } ... on PageSectionsCta { caption url } } } }");
    Pool.close(pool);
    Assert.assertEq(
        expected = (Value.Obj(Map#{ "page" => Value.Obj(Map#{
            "title" => Value.Str("Home"),
            "related" => Value.Obj(Map#{ "label" => Value.Str("see also"), "post" => Value.Obj(Map#{ "title" => Value.Str("Other") }) }),
            "sections" => Value.List(
                Value.Obj(Map#{ "__typename" => Value.Str("PageSectionsHero"), "headline" => Value.Str("Welcome") }) ::
                Value.Obj(Map#{ "__typename" => Value.Str("PageSectionsCta"), "caption" => Value.Str("Go"), "url" => Value.Str("https://example.com") }) :: Nil) }) }), None),
        page)
