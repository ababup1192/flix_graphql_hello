///
/// ContentSchemaBuilder: 型の定義から生える SDL。DB は使わない（Runner は呼ばれない）。
///
///
/// DB に触らない Runner。リゾルバは SDL を出すだけなら呼ばれない。
///
mod TestContentSchemaBuilder {

    def dryRunner(): Runner[ContentEff] =
        (_, f) -> match DbError.runWithFailure(() -> CmsTestKit.runWithResult(() -> Tenant.runWith(ProjectId.default(), () -> Session.runWith(Actor.System, () -> ObjectStore.runWithFake(Map.empty(), () -> Log.runWith(Log.Sink.silent(), () -> DbTest.runWithRows(Nil, f))))))) {
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

    /// collection には 1 件と一覧のクエリ、singleton には 1 件だけが生える。Where / OrderBy / Connection / Edge は型ごと、PageInfo は共通。
    @Test
    def testContentSchemaBuilderSdl(): Unit \ Assert =
        let sdl = match Schema.toSdl(ContentSchemaBuilder.build(sampleTypes(), dryRunner())) {
            case Ok(text)     => text
            case Err(message) => bug!("sdl: ${message}")
        };
        Assert.assertEq(expected = (true, true, true, true, true, true, true, false, true),
            // 意図した変更: id は slug と選べるように ID! から ID へ。slug の無い型に slug の引数は出ない
            // 意図した変更: 引数に description が付き `"説明" id: ID` の形になったので、引数の並びは名前と型の対で見る
            (String.contains(substr = "blog(\"", sdl) and String.contains(substr = " id: ID, \"", sdl) and String.contains(substr = " stage: Stage = PUBLISHED): Blog\n", sdl),
             String.contains(substr = "blogs(\"", sdl) and String.contains(substr = " where: BlogWhere, \"", sdl) and String.contains(substr = " orderBy: [BlogOrderBy!], \"", sdl)
                and String.contains(substr = " first: Int = 20, \"", sdl) and String.contains(substr = " skip: Int = 0, \"", sdl) and String.contains(substr = " after: String, \"", sdl)
                and String.contains(substr = " stage: Stage = PUBLISHED): BlogConnection!", sdl),
             String.contains(substr = "siteSetting(\"", sdl) and String.contains(substr = " stage: Stage = PUBLISHED): SiteSetting\n", sdl),
             String.contains(substr = "title_contains: String", sdl) and String.contains(substr = "views_gte: Float", sdl) and String.contains(substr = "tags_isNull: Boolean", sdl),
             String.contains(substr = "OR: [BlogWhereLeaf!]", sdl),
             String.contains(substr = "views_DESC", sdl) and not String.contains(substr = "tags_ASC", sdl),
             String.contains(substr = "tags: [String!]!", sdl) and String.contains(substr = "views: Float", sdl),
             String.contains(substr = "siteSettings(", sdl),
             String.contains(substr = "edges: [BlogEdge!]!", sdl) and String.contains(substr = "pageInfo: PageInfo!", sdl) and String.contains(substr = "endCursor: String", sdl) and String.contains(substr = "node: Blog!", sdl)))

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

    /// RichText には markdown（方言のまま）と assets（本文の asset）が生える。
    @Test
    def testContentSchemaBuilderRichTextMarkdownAndAssets(): Unit \ Assert =
        let fields = CmsTestKit.fieldDef("body", FieldKind.RichText) :: Nil;
        let sdl = Schema.toSdl(ContentSchemaBuilder.build(CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", fields) :: Nil, dryRunner()));
        Assert.assertEq(
            expected = Ok((true, true)),
            sdl |> Result.map(text -> (
                String.contains(substr = "markdown: String!", text),
                String.contains(substr = "assets: [Asset!]!", text))))

    ///
    /// slug の引数は、unique な SLUG のフィールドを 1 つだけ持つ型にだけ生える。
    ///
    ///   unique 1 つ  → blog(id: ID, slug: String, stage: ...)
    ///   unique でない → 引数ごと出ない
    ///   2 つある      → どちらで引くか決まらないので出ない
    ///
    @Test
    def testContentSchemaBuilderSlugArg(): Unit \ Assert =
        let slugField = api -> { unique = true | CmsTestKit.fieldDef(api, FieldKind.Slug) };
        let sdlOf = fields -> Schema.toSdl(ContentSchemaBuilder.build(CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", fields) :: Nil, dryRunner()));
        Assert.assertEq(
            expected = (Ok(true), Ok(false), Ok(false)),
            // 意図した変更: 引数に description が付いたので、slug の引数は名前と型の対で見る
            (sdlOf(slugField("slug") :: Nil) |> Result.map(sdl -> String.contains(substr = " id: ID, \"", sdl) and String.contains(substr = " slug: String, \"", sdl) and String.contains(substr = " stage: Stage = PUBLISHED): Blog\n", sdl)),
             sdlOf(CmsTestKit.fieldDef("slug", FieldKind.Slug) :: Nil) |> Result.map(String.contains(substr = "slug: String,")),
             sdlOf(slugField("slug") :: slugField("altSlug") :: Nil) |> Result.map(String.contains(substr = "slug: String,"))))

    ///
    /// 引数・input のフィールド・enum の値・オブジェクトのフィールドに description が出る（GraphiQL や codegen が拾う）。
    ///
    ///   引数         → `"..." first: Int = 20`（同じ行の前）
    ///   input        → `"..." title_contains: String`
    ///   enum の値    → 直前の行に `"..."`、次の行に `updatedAt_DESC`
    ///   フィールド   → 直前の行に `"..."`、次の行に `totalCount: Int!`
    ///
    @Test
    def testContentSchemaBuilderDescriptions(): Unit \ Assert =
        let sdl = match Schema.toSdl(ContentSchemaBuilder.build(sampleTypes(), dryRunner())) {
            case Ok(text)     => text
            case Err(message) => bug!("sdl: ${message}")
        };
        Assert.assertEq(expected = (true, true, true, true, true, true),
            (String.contains(substr = "\"返す件数の上限。既定 20、最大 200（超える値は 200 に丸める）。0 なら totalCount だけ\" first: Int = 20", sdl),
             String.contains(substr = "\"部分一致。大文字小文字を区別しない\" title_contains: String", sdl),
             String.contains(substr = "\"publishedAt が以後（以上）。値は ISO 8601 の日時（例 2026-09-01T00:00:00Z、offset 付きも可）か日付（2026-09-01 は UTC の 0 時）。読めない値は何にも合わない\" publishedAt_gte: String", sdl),
             String.contains(substr = "  \"updatedAt の新しい順（既定）\"\n  updatedAt_DESC", sdl),
             String.contains(substr = "  \"題名（title）の昇順。値が無い entry は末尾\"\n  title_ASC", sdl),
             String.contains(substr = "  \"絞り込み後の総件数（ページに関係なく）\"\n  totalCount: Int!", sdl)))

    ///
    /// description を付けた SDL が graphql-java の SchemaParser を通り、クエリを流せる。
    /// 引数の description（`"..." first: Int = 20`）と日本語の文字列リテラルを含む全種類のフィールドで組む。
    ///
    @Test
    def testContentSchemaBuilderDescribedSdlBuildsEngine(): Unit \ {Assert, IO} =
        let fields = { name = "題名", unique = true | CmsTestKit.fieldDef("slug", FieldKind.Slug) } :: CmsTestKit.fieldDef("publishOn", FieldKind.Date) :: CmsTestKit.fieldDef("day", FieldKind.DateOnly) ::
                     CmsTestKit.fieldDef("views", FieldKind.Number) :: CmsTestKit.fieldDef("featured", FieldKind.Boolean) :: CmsTestKit.fieldDef("cover", FieldKind.Asset) ::
                     { many = true | CmsTestKit.fieldDef("gallery", FieldKind.Asset) } :: CmsTestKit.fieldDef("body", FieldKind.RichText) :: { many = true | CmsTestKit.fieldDef("tags", FieldKind.Text) } ::
                     { config = { options = List#{"NEWS", "TECH"} | FieldConfig.empty() } | CmsTestKit.fieldDef("topic", FieldKind.Select) } :: Nil;
        let schema = ContentSchemaBuilder.build(CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", fields) :: Nil, dryRunner());
        Assert.assertEq(expected = Ok((Value.Obj(Map#{ "_types" => Value.Int(1) }), None)),
            GraphqlTestKit.executeQuery(schema, "{ _types }"))

    /// 型が 1 つも無くても Query は組める（_types だけ）。
    @Test
    def testContentSchemaBuilderEmpty(): Unit \ Assert =
        Assert.assertEq(expected = Ok(true),
            Schema.toSdl(ContentSchemaBuilder.build(Nil, dryRunner())) |> Result.map(String.contains(substr = "_types: Int!")))

}
