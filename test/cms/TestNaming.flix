use GeneratedAdmin.FieldKind

///
/// Naming: content type とフィールドの名前の規則。全部純粋。
///


///
/// 既存の型。blogs / Blog と tags / Tag。
///
def existing(): List[Naming.TypeNames] =
    { apiId = "blogs", singular = "Blog", plural = "blogs" } ::
    { apiId = "tags", singular = "Tag", plural = "tags" } :: Nil

///
/// 誤りのパスだけ取り出す（メッセージの文言はテストしない）。
///
def violationPaths(violations: List[Violation]): List[String] =
    violations |> List.map(violation -> { let Violation.Violation(path, _) = violation; path })

// ---- 導出 ----

/// apiId から singular を導く。ies → y、末尾の s を落とす、ss は残す、s で終わらなければそのまま。
@Test
def testNamingDeriveSingular(): Unit \ Assert =
    Assert.assertEq(expected = List#{"Blog", "Category", "Address", "News", "SiteSetting"},
        List.map(Naming.deriveSingular, List#{"blogs", "categories", "address", "news", "siteSettings"}))

// ---- 型の名前 ----

/// 規則に合う名前は通る。
@Test
def testNamingValidateTypeOk(): Unit \ Assert =
    Assert.assertEq(expected = Nil,
        Naming.validateType(existing(), { apiId = "profiles", singular = "Profile", plural = "profiles" }))

/// apiId は lowerCamel。既存と同じ apiId は使えない。
@Test
def testNamingValidateTypeApiId(): Unit \ Assert =
    Assert.assertEq(expected = (List#{"apiId"}, List#{"apiId"}),
        (violationPaths(Naming.validateType(existing(), { apiId = "Blog-posts", singular = "BlogPost", plural = "blogPosts" })),
         violationPaths(Naming.validateType(existing(), { apiId = "blogs", singular = "Post", plural = "posts" }))))

/// singular は予約された型名と、Where などで終わる名前と、既存の型と同じ名前が使えない。
@Test
def testNamingValidateTypeSingular(): Unit \ Assert =
    Assert.assertEq(expected = (List#{"singular"}, List#{"singular"}, List#{"singular"}),
        (violationPaths(Naming.validateType(existing(), { apiId = "assets", singular = "Asset", plural = "assets" })),
         violationPaths(Naming.validateType(existing(), { apiId = "somewheres", singular = "SomeWhere", plural = "somewheres" })),
         violationPaths(Naming.validateType(existing(), { apiId = "posts", singular = "Blog", plural = "posts" }))))

/// singular と plural が同じ（news / News）だと 1 件と一覧のクエリ名が衝突するので使えない。
@Test
def testNamingValidateTypeSingularEqualsPlural(): Unit \ Assert =
    Assert.assertEq(expected = List#{"plural"},
        violationPaths(Naming.validateType(existing(), { apiId = "news", singular = "News", plural = "news" })))

/// singular と plural の誤りはまとめて返る。apiId に誤りがあれば、そこから導く singular / plural は見ない。
@Test
def testNamingValidateTypeAll(): Unit \ Assert =
    Assert.assertEq(expected = (List#{"singular", "plural"}, List#{"apiId"}),
        (violationPaths(Naming.validateType(existing(), { apiId = "items", singular = "query", plural = "Query" })),
         violationPaths(Naming.validateType(existing(), { apiId = "9", singular = "query", plural = "Query" }))))

// ---- フィールドの名前 ----

/// 規則に合えば通り、識別子でない・予約名・重複は落ちる。
@Test
def testNamingValidateFieldApiId(): Unit \ Assert =
    let siblings = List#{"title", "body"};
    Assert.assertEq(expected = (Nil, List#{"apiId"}, List#{"apiId"}, List#{"apiId"}),
        (violationPaths(Naming.validateFieldApiId(siblings, "memberOnly")),
         violationPaths(Naming.validateFieldApiId(siblings, "member_only")),
         violationPaths(Naming.validateFieldApiId(siblings, "id")),
         violationPaths(Naming.validateFieldApiId(siblings, "title"))))

// ---- config ----

/// SLUG は sourceField が要り、それは同じ型にあるフィールドでなければならない。
@Test
def testNamingValidateConfigSlug(): Unit \ Assert =
    let base = ContentModel.emptyConfig();
    Assert.assertEq(expected = (List#{"config.sourceField"}, List#{"config.sourceField"}, Nil),
        (violationPaths(Naming.validateConfig(List#{"title"}, FieldKind.Slug, base)),
         violationPaths(Naming.validateConfig(List#{"title"}, FieldKind.Slug, { sourceField = Some("name") | base })),
         violationPaths(Naming.validateConfig(List#{"title"}, FieldKind.Slug, { sourceField = Some("title") | base }))))

/// maxLength は 1 以上、max は min 以上。min / max / integer は NUMBER 以外に付けられない。
@Test
def testNamingValidateConfigRanges(): Unit \ Assert =
    let base = ContentModel.emptyConfig();
    Assert.assertEq(expected = (List#{"config.maxLength"}, List#{"config.max"}, List#{"config"}, Nil),
        (violationPaths(Naming.validateConfig(Nil, FieldKind.Text, { maxLength = Some(0) | base })),
         violationPaths(Naming.validateConfig(Nil, FieldKind.Number, { min = Some(10.0), max = Some(1.0) | base })),
         violationPaths(Naming.validateConfig(Nil, FieldKind.Text, { integer = Some(true) | base })),
         violationPaths(Naming.validateConfig(Nil, FieldKind.Number, { min = Some(0.0), max = Some(100.0), integer = Some(true) | base }))))
