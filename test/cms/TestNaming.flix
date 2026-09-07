///
/// Naming: content type とフィールドの名前の規則。全部純粋。
///
///
/// 既存の型。blogs / Blog と tags / Tag。
///
mod TestNaming {

    def existing(): List[Naming.TypeNames] =
        CmsTestKit.names("blogs", "Blog", "blogs") :: CmsTestKit.names("tags", "Tag", "tags") :: Nil

    // ---- 導出 ----

    /// apiId から singular を導く。ies → y、末尾の s を落とす、ss / us / is / ws は残す、s で終わらなければそのまま。
    @Test
    def testNamingDeriveSingular(): Unit \ Assert =
        Assert.assertEq(expected = List#{"Blog", "Category", "Address", "News", "Status", "SiteSetting"},
            List.map(text -> Naming.deriveSingular(CmsTestKit.apiId(text)) |> TypeName.text, List#{"blogs", "categories", "address", "news", "status", "siteSettings"}))

    // ---- 型の名前 ----

    /// 規則に合う名前は通る。
    @Test
    def testNamingValidateTypeOk(): Unit \ Assert =
        Assert.assertEq(expected = Nil, Naming.validateType(existing(), CmsTestKit.names("profiles", "Profile", "profiles")))

    /// 既存と同じ apiId は使えず、その時は singular / plural を見ない（導出元が同じで同じ原因が並ぶだけ）。
    @Test
    def testNamingValidateTypeDuplicateApiId(): Unit \ Assert =
        Assert.assertEq(expected = List#{"apiId"},
            CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("blogs", "Blog", "blogs"))))

    /// singular は予約された型名と、Where / WhereLeaf などで終わる名前と、既存の型と同じ名前が使えない。
    @Test
    def testNamingValidateTypeSingular(): Unit \ Assert =
        Assert.assertEq(expected = (List#{"singular"}, List#{"singular"}, List#{"singular"}, List#{"singular"}),
            (CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("assets", "Asset", "assets"))),
             CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("somewheres", "SomeWhere", "somewheres"))),
             CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("leaves", "BlogWhereLeaf", "leaves"))),
             CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("posts", "Blog", "posts")))))

    /// singular と plural が同じ（news / News）だと 1 件と一覧のクエリ名が衝突するので使えない。既存の型の plural とも衝突しない事。
    @Test
    def testNamingValidateTypePlural(): Unit \ Assert =
        Assert.assertEq(expected = (List#{"plural"}, List#{"plural"}),
            (CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("news", "News", "news"))),
             CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("posts", "Post", "tags")))))

    /// singular の 1 件のクエリ名（先頭小文字）が既存の型の一覧のクエリ名と同じだと Query のフィールドが重なるので使えない。
    ///
    ///   既存: apiId "news"（plural news）→ 候補 singular "News" は 1 件のクエリ名が news になり衝突
    @Test
    def testNamingValidateTypeSingularVsExistingPlural(): Unit \ Assert =
        let others = CmsTestKit.names("news", "Article", "news") :: Nil;
        Assert.assertEq(expected = (List#{"singular"}, Nil),
            (CmsTestKit.violationPaths(Naming.validateType(others, CmsTestKit.names("stories", "News", "stories"))),
             CmsTestKit.violationPaths(Naming.validateType(others, CmsTestKit.names("stories", "Story", "stories")))))

    /// singular と plural の誤りはまとめて返る。
    @Test
    def testNamingValidateTypeBoth(): Unit \ Assert =
        Assert.assertEq(expected = List#{"singular", "plural"},
            CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("items", "Tag", "blogs"))))

    // ---- フィールドの名前 ----

    /// 規則に合えば通り、予約名と重複は落ちる。
    @Test
    def testNamingValidateFieldApiId(): Unit \ Assert =
        let siblings = List#{CmsTestKit.apiId("title"), CmsTestKit.apiId("body")};
        Assert.assertEq(expected = (Nil, List#{"apiId"}, List#{"apiId"}),
            (CmsTestKit.violationPaths(Naming.validateFieldApiId(siblings, CmsTestKit.apiId("memberOnly"))),
             CmsTestKit.violationPaths(Naming.validateFieldApiId(siblings, CmsTestKit.apiId("id"))),
             CmsTestKit.violationPaths(Naming.validateFieldApiId(siblings, CmsTestKit.apiId("title")))))

    /// 子フィールドには required / unique を付けられず、BLOCKS の variant は配列にできない。最上位なら構わない。
    @Test
    def testNamingValidateChildFlags(): Unit \ Assert =
        Assert.assertEq(expected = (Nil, List#{"required", "unique"}, List#{"many"}, Nil),
            (CmsTestKit.violationPaths(Naming.validateChildFlags({ hasParent = false, required = true, unique = true })),
             CmsTestKit.violationPaths(Naming.validateChildFlags({ hasParent = true, required = true, unique = true })),
             CmsTestKit.violationPaths(Naming.validateParent(Some(FieldKind.Blocks), FieldKind.Object, true)),
             CmsTestKit.violationPaths(Naming.validateParent(Some(FieldKind.Blocks), FieldKind.Object, false))))

    /// 性質の組み合わせ: 配列に unique は付けられず、BLOCKS は常に配列、OBJECT / BLOCKS に unique は付けられない。単数の Text の unique は通る。
    @Test
    def testNamingValidateFlags(): Unit \ Assert =
        Assert.assertEq(expected = (Nil, List#{"unique"}, List#{"many"}, List#{"unique"}, List#{"unique", "unique"}),
            (CmsTestKit.violationPaths(Naming.validateFlags({ kind = FieldKind.Text, many = false, unique = true })),
             CmsTestKit.violationPaths(Naming.validateFlags({ kind = FieldKind.Text, many = true, unique = true })),
             CmsTestKit.violationPaths(Naming.validateFlags({ kind = FieldKind.Blocks, many = false, unique = false })),
             CmsTestKit.violationPaths(Naming.validateFlags({ kind = FieldKind.Object, many = false, unique = true })),
             CmsTestKit.violationPaths(Naming.validateFlags({ kind = FieldKind.Blocks, many = true, unique = true }))))

    // ---- config ----

    /// SLUG は sourceField が要り、それは同じ型にあるフィールドでなければならない。
    @Test
    def testNamingValidateConfigSlug(): Unit \ Assert =
        let base = FieldConfig.empty();
        let siblings = List#{CmsTestKit.apiId("title")};
        Assert.assertEq(expected = (List#{"config.sourceField"}, List#{"config.sourceField"}, Nil),
            (CmsTestKit.violationPaths(Naming.validateConfig(siblings, FieldKind.Slug, base)),
             CmsTestKit.violationPaths(Naming.validateConfig(siblings, FieldKind.Slug, { sourceField = Some(CmsTestKit.apiId("name")) | base })),
             CmsTestKit.violationPaths(Naming.validateConfig(siblings, FieldKind.Slug, { sourceField = Some(CmsTestKit.apiId("title")) | base }))))

    /// maxLength は 1 以上、max は min 以上。min / max / integer は NUMBER 以外に付けられない。
    @Test
    def testNamingValidateConfigRanges(): Unit \ Assert =
        let base = FieldConfig.empty();
        Assert.assertEq(expected = (List#{"config.maxLength"}, List#{"config.max"}, List#{"config"}, Nil),
            (CmsTestKit.violationPaths(Naming.validateConfig(Nil, FieldKind.Text, { maxLength = Some(0) | base })),
             CmsTestKit.violationPaths(Naming.validateConfig(Nil, FieldKind.Number, { min = Some(10.0), max = Some(1.0) | base })),
             CmsTestKit.violationPaths(Naming.validateConfig(Nil, FieldKind.Text, { integer = Some(true) | base })),
             CmsTestKit.violationPaths(Naming.validateConfig(Nil, FieldKind.Number, { min = Some(0.0), max = Some(100.0), integer = Some(true) | base }))))

    // ---- 生える型名 ----

    ///
    /// blogs（title / category: select / sections: blocks[hero{headline}]）。
    ///
    def blogFields(): List[FieldDef] =
        let hero = { children = Children.Children(CmsTestKit.fieldDef("headline", FieldKind.Text) :: Nil) | CmsTestKit.fieldDef("hero", FieldKind.Object) };
        CmsTestKit.fieldDef("title", FieldKind.Text) ::
        CmsTestKit.fieldDef("category", FieldKind.Select) ::
        { many = true, children = Children.Children(hero :: Nil) | CmsTestKit.fieldDef("sections", FieldKind.Blocks) } :: Nil

    def blogSingular(): TypeName = CmsTestKit.names("blogs", "Blog", "blogs")#singular

    /// 型が生やす型名は、singular と接尾辞付き、Select の enum、Blocks の union と variant（入れ子は名前が続く）。Text からは生えない。
    @Test
    def testNamingSchemaTypeNames(): Unit \ Assert =
        Assert.assertEq(expected = List#{"Blog", "BlogWhere", "BlogWhereLeaf", "BlogOrderBy", "BlogConnection", "BlogCategory", "BlogSections", "BlogSectionsHero"},
            Naming.schemaTypeNames(blogSingular(), blogFields()))

    /// 他の型が生やす名前（BlogCategory）と同じ singular は invalid。重ならなければ通る。
    /// singular を変える時は自分のフィールドから生え直す名前も見る（Tag + blogSections が生やす TagBlogSections と、TagBlog + sections が重なる）。
    /// 既にある型名と重なる名前のフィールド（where → BlogWhere）も invalid。
    @Test
    def testNamingValidateSchemaTypeNames(): Unit \ Assert =
        let taken = Naming.schemaTypeNames(blogSingular(), blogFields());
        let tagTaken = Naming.schemaTypeNames(CmsTestKit.names("tags", "Tag", "tags")#singular, CmsTestKit.fieldDef("blogSections", FieldKind.Select) :: Nil);
        let sections = CmsTestKit.fieldDef("sections", FieldKind.Select) :: Nil;
        Assert.assertEq(expected = (List#{"singular"}, Nil, List#{"singular"}, List#{"apiId"}, Nil),
            (CmsTestKit.violationPaths(Naming.validateSchemaTypeNames(taken, CmsTestKit.names("categories", "BlogCategory", "categories")#singular, Nil)),
             CmsTestKit.violationPaths(Naming.validateSchemaTypeNames(taken, CmsTestKit.names("tags", "Tag", "tags")#singular, sections)),
             CmsTestKit.violationPaths(Naming.validateSchemaTypeNames(tagTaken, CmsTestKit.names("zzzs", "TagBlog", "zzzs")#singular, sections)),
             CmsTestKit.violationPaths(Naming.validateFieldTypeNames(taken, "Blog", CmsTestKit.fieldDef("where", FieldKind.Object))),
             CmsTestKit.violationPaths(Naming.validateFieldTypeNames(taken, "Blog", CmsTestKit.fieldDef("where", FieldKind.Text)))))
}
