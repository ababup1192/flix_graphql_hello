///
/// Post: 固定データの検索。
///

/// find は ID で記事を返し、無ければ None。
@Test
def testPostFind(): Unit \ Assert =
    Assert.assertEq(expected = (Some("Flix で GraphQL"), None),
        (Post.find(Id.Id("p1")) |> Option.map(post -> post#title), Post.find(Id.Id("nope")) |> Option.map(post -> post#title)))

/// byAuthor は書き手の記事だけを返す。
@Test
def testPostByAuthor(): Unit \ Assert =
    Assert.assertEq(expected = Id.Id("p1") :: Id.Id("p2") :: Nil,
        Post.byAuthor(Id.Id("a1")) |> List.map(post -> post#id))

/// byStatus は状態で絞る。DRAFT は p4 だけ。
@Test
def testPostByStatus(): Unit \ Assert =
    Assert.assertEq(expected = Id.Id("p4") :: Nil,
        Post.byStatus(Generated.PostStatus.Draft) |> List.map(post -> post#id))

/// findAuthor は ID で書き手を返す。
@Test
def testPostFindAuthor(): Unit \ Assert =
    Assert.assertEq(expected = Some("abab"),
        Post.findAuthor(Id.Id("a1")) |> Option.map(author -> author#name))
