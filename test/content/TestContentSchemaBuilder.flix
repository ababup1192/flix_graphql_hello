///
/// ContentSchemaBuilder: 型の定義から生える SDL。DB は使わない（Runner は呼ばれない）。
///
///
/// DB に触らない Runner。リゾルバは SDL を出すだけなら呼ばれない。
///
mod TestContentSchemaBuilder {

    def dryRunner(): Runner[ContentEff] =
        (_, f) -> match DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Tenant.runWith(ProjectId.default(), () -> Session.runWith(Actor.System, () -> ObjectStore.runWithFake(Map.empty(), () -> Log.runWith(Log.Sink.silent(), () -> DbTest.runWithRows(Nil, f))))))) {
            case Ok(Ok(result))   => result
            case Ok(Err(failure)) => Err(GraphqlErrors.toFieldError(failure))
            case Err(failure)     => Err(GraphqlErrors.fromApplicationFailure(None, ApplicationFailure.Infrastructure(failure)))
        }

    ///
    /// blogs（collection）と siteSettings（singleton）。
    ///
    def sampleTypes(): List[ContentType] =
        CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事",
            { name = "題名" | CmsTestKit.fieldDef("title", FieldKind.Text) } :: CmsTestKit.fieldDef("views", FieldKind.Number) :: { many = true | CmsTestKit.fieldDef("tags", FieldKind.Text) } :: Nil) ::
        CmsTestKit.contentType(2i64, "siteSettings", TypeKind.Singleton, "サイト設定", CmsTestKit.fieldDef("title", FieldKind.Text) :: Nil) :: Nil

    /// collection には 1 件と一覧のクエリ、singleton には 1 件だけが生える。Where / OrderBy / Connection は型ごと。
    @Test
    def testContentSchemaBuilderSdl(): Unit \ Assert =
        let sdl = match Schema.toSdl(ContentSchemaBuilder.build(sampleTypes(), dryRunner())) {
            case Ok(text)     => text
            case Err(message) => bug!("sdl: ${message}")
        };
        Assert.assertEq(expected = (true, true, true, true, true, true, true, false),
            (String.contains(substr = "blog(id: ID!, stage: Stage = PUBLISHED): Blog", sdl),
             String.contains(substr = "blogs(where: BlogWhere, orderBy: [BlogOrderBy!], first: Int = 20, skip: Int = 0, stage: Stage = PUBLISHED): BlogConnection!", sdl),
             String.contains(substr = "siteSetting(stage: Stage = PUBLISHED): SiteSetting", sdl),
             String.contains(substr = "title_contains: String", sdl) and String.contains(substr = "views_gte: Float", sdl) and String.contains(substr = "tags_isNull: Boolean", sdl),
             String.contains(substr = "OR: [BlogWhereLeaf!]", sdl),
             String.contains(substr = "views_DESC", sdl) and not String.contains(substr = "tags_ASC", sdl),
             String.contains(substr = "tags: [String!]!", sdl) and String.contains(substr = "views: Float", sdl),
             String.contains(substr = "siteSettings(", sdl)))

    /// DATE は String で出て、_eq と範囲の 4 つで絞れ、orderBy に出る。配列の SELECT は enum の配列で出て、_contains は enum を受ける。
    @Test
    def testContentSchemaBuilderDateAndMultiSelect(): Unit \ Assert =
        let fields = CmsTestKit.fieldDef("publishOn", FieldKind.Date) ::
                     { many = true, config = { options = List#{"NEWS", "TECH"} | FieldConfig.empty() } | CmsTestKit.fieldDef("topics", FieldKind.Select) } :: Nil;
        let sdl = Schema.toSdl(ContentSchemaBuilder.build(CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", fields) :: Nil, dryRunner()));
        Assert.assertEq(
            expected = Ok((true, true, true, true, true, false)),
            sdl |> Result.map(text -> (
                String.contains(substr = "publishOn: String", text),
                String.contains(substr = "publishOn_gte: String", text) and String.contains(substr = "publishOn_lt: String", text) and String.contains(substr = "publishOn_eq: String", text),
                String.contains(substr = "publishOn_DESC", text),
                String.contains(substr = "topics: [BlogTopics!]!", text),
                String.contains(substr = "topics_contains: BlogTopics", text),
                String.contains(substr = "topics_ASC", text))))

    /// 子の無い OBJECT / BLOCKS は生やさない（空の型で graphql-java が落ちない）。子があれば生える。
    @Test
    def testContentSchemaBuilderSkipsEmptyNested(): Unit \ Assert =
        let empties = CmsTestKit.fieldDef("related", FieldKind.Object) :: { many = true | CmsTestKit.fieldDef("sections", FieldKind.Blocks) } :: Nil;
        let filled = { children = Children.Children(CmsTestKit.fieldDef("label", FieldKind.Text) :: Nil) | CmsTestKit.fieldDef("related", FieldKind.Object) } :: Nil;
        let sdlOf = fields -> Schema.toSdl(ContentSchemaBuilder.build(CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", fields) :: Nil, dryRunner()));
        Assert.assertEq(expected = (Ok((false, false)), Ok(true)),
            (sdlOf(empties) |> Result.map(sdl -> (String.contains(substr = "related", sdl), String.contains(substr = "sections", sdl))),
             sdlOf(filled) |> Result.map(String.contains(substr = "related: BlogRelated"))))

    /// ASSET は共通の Asset 型に、RICH_TEXT は RichText 型に生え、どちらも orderBy には出ない。配列の ASSET は _contains で絞れる。
    @Test
    def testContentSchemaBuilderAssetAndRichText(): Unit \ Assert =
        let fields = CmsTestKit.fieldDef("cover", FieldKind.Asset) :: { many = true | CmsTestKit.fieldDef("gallery", FieldKind.Asset) } :: CmsTestKit.fieldDef("body", FieldKind.RichText) :: Nil;
        let sdl = Schema.toSdl(ContentSchemaBuilder.build(CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", fields) :: Nil, dryRunner()));
        Assert.assertEq(
            expected = Ok((true, true, true, true, true, true, false, false)),
            sdl |> Result.map(text -> (
                String.contains(substr = "cover: Asset", text),
                String.contains(substr = "gallery: [Asset!]!", text),
                String.contains(substr = "body: RichText", text),
                String.contains(substr = "html: String!", text),
                String.contains(substr = "cover_id_eq: ID", text),
                String.contains(substr = "gallery_contains: ID", text),
                String.contains(substr = "cover_ASC", text),
                String.contains(substr = "body_ASC", text))))

    /// 型が 1 つも無くても Query は組める（_types だけ）。
    @Test
    def testContentSchemaBuilderEmpty(): Unit \ Assert =
        Assert.assertEq(expected = Ok(true),
            Schema.toSdl(ContentSchemaBuilder.build(Nil, dryRunner())) |> Result.map(String.contains(substr = "_types: Int!")))

}
