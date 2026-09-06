///
/// ContentSchemaBuilder: 型の定義から生える SDL。DB は使わない（Runner は呼ばれない）。
///
///
/// DB に触らない Runner。リゾルバは SDL を出すだけなら呼ばれない。
///
mod TestContentSchemaBuilder {

    def dryRunner(): Runner[ContentEff] =
        f -> match DbError.runWithFailure(() -> DbTest.runWithRows(Nil, f)) {
            case Ok(result)   => result
            case Err(failure) => Err("${failure}")
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

}
