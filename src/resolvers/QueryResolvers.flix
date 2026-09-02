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

    /// type Query のリゾルバ一式
    pub def resolvers(): Generated.QueryResolvers[AppEff] =
        { add = add(), fibonacci = fibonacci(), post = post(), posts = posts(), counter = counter() }

}
