///
/// このサーバのスキーマ。schema.graphql から生成された Generated.Resolvers に、各 feature のリゾルバを当てはめる。
/// 型ごとに注釈付きの関数で作るのは、型が合わないときのエラーをその型の中に閉じ込めるため。
///
mod AppSchema {

    ///
    /// スキーマを組み立てる。runStore はカウンタの保存先（本番は SQLite）。
    ///
    pub def make(runStore: Counter.StoreRunner): Schema =
        Generated.schema({
            queryRoot    = queryResolvers(runStore),
            mutationRoot = mutationResolvers(runStore),
            post         = PostResolvers.post(),
            author       = PostResolvers.author()
        })

    ///
    /// type Query。
    ///
    def queryResolvers(runStore: Counter.StoreRunner): Generated.QueryResolvers = {
        add       = (_context, a, b) -> Ok(Calc.add(a, b)),
        fibonacci = (_context, n) -> Ok(Calc.fibonacci(n)),
        post      = (_context, id) -> Ok(Post.find(id)),
        posts     = (_context, status) -> Ok(status |> Option.map(Post.byStatus) |> Option.getWithDefault(Post.all())),
        counter   = context -> Counter.counter(runStore, context)
    }

    ///
    /// type Mutation。
    ///
    def mutationResolvers(runStore: Counter.StoreRunner): Generated.MutationResolvers = {
        increment = (context, by) -> Counter.increment(runStore, context, by)
    }

}
