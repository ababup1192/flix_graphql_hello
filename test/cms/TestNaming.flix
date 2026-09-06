///
/// Naming: content type とフィールドの名前の規則。全部純粋。
///

///
/// 既存の型。blogs / Blog と tags / Tag。
///
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

/// singular は予約された型名と、Where などで終わる名前と、既存の型と同じ名前が使えない。
@Test
def testNamingValidateTypeSingular(): Unit \ Assert =
    Assert.assertEq(expected = (List#{"singular"}, List#{"singular"}, List#{"singular"}),
        (CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("assets", "Asset", "assets"))),
         CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("somewheres", "SomeWhere", "somewheres"))),
         CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("posts", "Blog", "posts")))))

/// singular と plural が同じ（news / News）だと 1 件と一覧のクエリ名が衝突するので使えない。既存の型の plural とも衝突しない事。
@Test
def testNamingValidateTypePlural(): Unit \ Assert =
    Assert.assertEq(expected = (List#{"plural"}, List#{"plural"}),
        (CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("news", "News", "news"))),
         CmsTestKit.violationPaths(Naming.validateType(existing(), CmsTestKit.names("posts", "Post", "tags")))))

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
