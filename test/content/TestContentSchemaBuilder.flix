///
/// ContentSchemaBuilder: 型の定義から生える SDL。DB は使わない（Runner は呼ばれない）。
///

///
/// DB に触らない Runner。リゾルバは SDL を出すだけなら呼ばれない。
///
def dryRunner(): Runner[ContentEff] =
    f -> match DbError.runWithFailure(() -> DbTest.runWithRows(Nil, f)) {
        case Ok(result)   => result
        case Err(failure) => Err("${failure}")
    }

///
/// blogs（collection）と siteSettings（singleton）。
///
def sampleTypes(): List[ContentType] =
    let at = Timestamp.at("2026-09-01T00:00:00Z");
    let fieldBase = { id = FieldId.FieldId(0i64), typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("x"), name = "", kind = FieldKind.Text, many = false, required = false, unique = false, localized = false, target = None, config = FieldConfig.empty(), position = 0 };
    let blogs = {
        id = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("blogs"), kind = TypeKind.Collection, name = "記事",
        singular = CmsTestKit.typeName("Blog"), plural = CmsTestKit.apiId("blogs"), previewUrl = None,
        fields = { apiId = CmsTestKit.apiId("title"), name = "題名" | fieldBase } :: { apiId = CmsTestKit.apiId("views"), kind = FieldKind.Number | fieldBase } :: { apiId = CmsTestKit.apiId("tags"), many = true | fieldBase } :: Nil,
        createdAt = at, updatedAt = at };
    let settings = {
        id = TypeId.TypeId(2i64), apiId = CmsTestKit.apiId("siteSettings"), kind = TypeKind.Singleton, name = "サイト設定",
        singular = CmsTestKit.typeName("SiteSetting"), plural = CmsTestKit.apiId("siteSettings"), previewUrl = None,
        fields = { apiId = CmsTestKit.apiId("title") | fieldBase } :: Nil,
        createdAt = at, updatedAt = at };
    blogs :: settings :: Nil

/// collection には 1 件と一覧のクエリ、singleton には 1 件だけが生える。Where / OrderBy / Connection は型ごと。
@Test
def testContentSchemaBuilderSdl(): Unit \ Assert =
    let sdl = Schema.toSdl(ContentSchemaBuilder.build(sampleTypes(), dryRunner())) |> Result.getWithDefault("");
    Assert.assertEq(expected = (true, true, true, true, true, true, true, false),
        (String.contains(substr = "blog(id: ID!, stage: Stage = PUBLISHED): Blog", sdl),
         String.contains(substr = "blogs(where: BlogWhere, orderBy: [BlogOrderBy!], first: Int = 20, skip: Int = 0, stage: Stage = PUBLISHED): BlogConnection!", sdl),
         String.contains(substr = "siteSetting(stage: Stage = PUBLISHED): SiteSetting", sdl),
         String.contains(substr = "title_contains: String", sdl) and String.contains(substr = "views_gte: Float", sdl) and String.contains(substr = "tags_isNull: Boolean", sdl),
         String.contains(substr = "OR: [BlogWhereLeaf!]", sdl),
         String.contains(substr = "views_DESC", sdl) and not String.contains(substr = "tags_ASC", sdl),
         String.contains(substr = "tags: [String!]!", sdl) and String.contains(substr = "views: Float", sdl),
         String.contains(substr = "siteSettings(", sdl)))

/// 型が 1 つも無くても Query は組める（_types だけ）。
@Test
def testContentSchemaBuilderEmpty(): Unit \ Assert =
    Assert.assertEq(expected = Ok(true),
        Schema.toSdl(ContentSchemaBuilder.build(Nil, dryRunner())) |> Result.map(String.contains(substr = "_types: Int!")))
