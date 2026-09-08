///
/// microCMS のスキーマ（実物の export。test/fixtures/microcms）を写し、ダミーの entry を作って公開し、コンテンツ API で読めるかを見る。
/// 「器として載せ替え可能か」の確認。
///
mod TestMicrocmsPg {

    def apis(): List[MicrocmsSchema.Api] \ {IO, Fs.FileRead} =
        match MicrocmsCli.readApis("test/fixtures/microcms") { case Ok(found) => found case Err(message) => bug!(message) }

    /// 9 つの API を読む。エンドポイント名は apiId に写る（"insidesales-category-keywords" → insidesalesCategoryKeywords）。写せない種類は無い。
    @Test
    def testPgMicrocmsSchemaParses(): Unit \ {IO, Assert, Fs.FileRead} =
        Assert.assertEq(
            expected = (9, List#{"blogs", "categories", "insidesaleServices", "insidesalesCategoryKeywords", "insidesalesCategory", "insidesalesFeature", "insidesalesIssue", "profiles", "tags"}, Nil),
            (List.length(apis()), apis() |> List.map(api -> ApiId.text(api#apiId)), apis() |> List.flatMap(MicrocmsSchema.unsupported)))

    ///
    /// 型を写してダミーを 2 件ずつ積み、公開まで通る（型 9、entry 18）。コンテンツ API で blogs の参照（profile / tags / 前編）・画像・
    /// 本文の見出しが読め、repeater は BLOCKS として variant（blockType）ごとの中身を持つ。
    ///
    @Test
    def testPgMicrocmsImportAndRead(): Unit \ {IO, Assert, Fs.FileRead} =
        let loaded = apis();
        let seed = () -> {
            let types = MicrocmsImport.importSchema(loaded);
            let created = Net.Http.runWithIO(() -> MicrocmsImport.seedDummy(loaded, types, 2));
            (Map.size(types), created |> Map.valuesOf |> List.map(List.length) |> List.sum)
        };
        let (blog, services, blocks, summary) = PgTestSupport.withContentApiAndPool(seed, (pool, ask) -> {
            let summary = PgTestSupport.mutateOrBug(pool, () -> List.length(ContentTypes.list(Session.grant())));
            let blocks = PgTestSupport.mutateOrBug(pool, () ->
                ContentTypes.findByApiId(Session.grant(), CmsTestKit.apiId("insidesaleServices"))
                    |> Option.flatMap(owner -> ContentEntries.list(owner#id, { search = "", first = 1, skip = 0 })#entries |> List.head)
                    |> Option.flatMap(entry -> Map.get(CmsTestKit.apiId("implementationCases"), entry#data))
                    |> Option.map(Util.Json.toCompactString));
            (ask("{ blogs(where: { title_eq: \"タイトル 1\" }) { totalCount nodes { title memberOnly thumbnail { alt } profile { name } tags { tag } theFirstPart { title } content { headings { level text } } } } }"),
             ask("{ insidesaleServices(where: { name_eq: \"名前 2\" }) { nodes { name sortOrder logo { alt } blogs { title } } } }"),
             blocks, summary)
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1), "nodes" => Value.List(Value.Obj(Map#{
                    "title" => Value.Str("タイトル 1"), "memberOnly" => Value.Bool(false),
                    "thumbnail" => Value.Obj(Map#{ "alt" => Value.Str("ダミー画像") }),
                    "profile" => Value.Obj(Map#{ "name" => Value.Str("名前 1") }),
                    "tags" => Value.List(Value.Obj(Map#{ "tag" => Value.Str("タグ 1") }) :: Value.Obj(Map#{ "tag" => Value.Str("タグ 2") }) :: Nil),
                    "theFirstPart" => Value.Obj(Map#{ "title" => Value.Str("タイトル 1") }),
                    "content" => Value.Obj(Map#{ "headings" => Value.List(Value.Obj(Map#{ "level" => Value.Int(2), "text" => Value.Str("内容 1 の見出し") }) :: Nil) })
                }) :: Nil) }) }), None),
                (Value.Obj(Map#{ "insidesaleServices" => Value.Obj(Map#{ "nodes" => Value.List(Value.Obj(Map#{
                    "name" => Value.Str("名前 2"), "sortOrder" => Value.Float(2.0), "logo" => Value.Obj(Map#{ "alt" => Value.Str("ダミー画像") }),
                    "blogs" => Value.List(Value.Obj(Map#{ "title" => Value.Str("タイトル 1") }) :: Value.Obj(Map#{ "title" => Value.Str("タイトル 2") }) :: Nil)
                }) :: Nil) }) }), None),
                Some("[{\"blockType\":\"implementationCase\",\"companyName\":\"企業名 2\",\"detail\":\"詳細 2 の 1 行目\\n2 行目\",\"reference\":\"引用元URL 2\",\"summary\":\"概要 2\"}]"),
                9),
            (blog, services, blocks, summary))

}
