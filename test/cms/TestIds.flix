///
/// Ids: 識別子の parse と表示。規則に合う物しか作れない。
///

/// ApiId は lowerCamel だけ通る。表示は中の文字列そのもの。
@Test
def testApiIdParse(): Unit \ Assert =
    Assert.assertEq(expected = (Some("memberOnly"), None, None, None),
        (ApiId.parse("memberOnly") |> Option.map(id -> "${id}"),
         ApiId.parse("MemberOnly") |> Option.map(ApiId.text),
         ApiId.parse("member_only") |> Option.map(ApiId.text),
         ApiId.parse("") |> Option.map(ApiId.text)))

/// TypeName は UpperCamel だけ通る。
@Test
def testTypeNameParse(): Unit \ Assert =
    Assert.assertEq(expected = (Some("BlogPost"), None, None),
        (TypeName.parse("BlogPost") |> Option.map(TypeName.text),
         TypeName.parse("blogPost") |> Option.map(TypeName.text),
         TypeName.parse("Blog-Post") |> Option.map(TypeName.text)))

/// TypeId / FieldId の表示は中の数字（エラーメッセージや GraphQL の Id にそのまま出る）。
@Test
def testNumericIds(): Unit \ Assert =
    Assert.assertEq(expected = ("42", "7"),
        ("${TypeId.TypeId(42i64)}", "${FieldId.FieldId(7i64)}"))

/// プロジェクト slug は DNS のラベル。大文字・先頭の -・65 文字は None。
@Test
def testProjectSlugParse(): Unit \ Assert =
    Assert.assertEq(expected = (Some("blog"), Some("my-shop-2"), None, None, None, "default"),
        (ProjectSlug.parse("blog") |> Option.map(ProjectSlug.text),
         ProjectSlug.parse("my-shop-2") |> Option.map(ProjectSlug.text),
         ProjectSlug.parse("Blog") |> Option.map(ProjectSlug.text),
         ProjectSlug.parse("-blog") |> Option.map(ProjectSlug.text),
         ProjectSlug.parse(String.repeat(65, "a")) |> Option.map(ProjectSlug.text),
         ProjectSlug.text(ProjectSlug.default())))
