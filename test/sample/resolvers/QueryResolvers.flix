///
/// type Query のリゾルバ。`make scaffold` が作った雛形で、人が所有する（作り直されない）。
///
mod QueryResolvers {

    /// Query.add
    pub def add(): Generated.QueryAddResolver[AppEff] =
        (_context, a, b) -> Ok(Calc.add(a, b))

    /// Query.fibonacci
    pub def fibonacci(): Generated.QueryFibonacciResolver[AppEff] =
        (_context, n) -> Ok(Calc.fibonacci(n))

    /// Query.post
    pub def post(): Generated.QueryPostResolver[AppEff] =
        (_context, id) -> Ok(Post.find(id))

    /// Query.posts
    pub def posts(): Generated.QueryPostsResolver[AppEff] =
        (_context, status) -> Ok(status |> Option.map(Post.byStatus) |> Option.getWithDefault(Post.all()))

    /// Query.counter
    pub def counter(): Generated.QueryCounterResolver[AppEff] =
        context -> Counter.counter(context)

    /// Query.search。title か name に text を含む物
    pub def search(): Generated.QuerySearchResolver[AppEff] =
        (_context, text) -> Ok(
            (Post.all() |> List.filter(post -> String.contains(substr = text, post#title)) |> List.map(Generated.SearchResult.Post))
            ::: (Post.authors() |> List.filter(author -> String.contains(substr = text, author#name)) |> List.map(Generated.SearchResult.Author)))

    /// Query.node。記事を先に探し、無ければ書き手
    pub def node(): Generated.QueryNodeResolver[AppEff] =
        (_context, id) -> Ok(match Post.find(id) {
            case Some(post) => Some(Generated.Node.Post(post))
            case None       => Post.findAuthor(id) |> Option.map(Generated.Node.Author)
        })

    /// type Query のリゾルバ一式
    pub def resolvers(): Generated.QueryResolvers[AppEff] =
        { add = add(), fibonacci = fibonacci(), post = post(), posts = posts(), counter = counter(), search = search(), node = node() }

}
