///
/// このサーバのスキーマ。schema.graphql から生成された Generated.Resolvers に、src/resolvers/ の型ごとのリゾルバを当てはめる。
///
mod AppSchema {

    ///
    /// スキーマを組み立てる。runApp は AppEff を IO に落とすハンドラ（本番は SQLite、テストはメモリ）。
    ///
    pub def make(runApp: Runner[AppEff]): Schema =
        Generated.schema({
            queryRoot    = QueryResolvers.resolvers(),
            mutationRoot = MutationResolvers.resolvers(),
            post         = PostResolvers.resolvers(),
            author       = AuthorResolvers.resolvers()
        }, runApp)

}
