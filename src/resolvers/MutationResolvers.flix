///
/// type Mutation のリゾルバ。`make scaffold` が作った雛形で、人が所有する（作り直されない）。
///
mod MutationResolvers {

    /// Mutation.increment
    pub def increment(): Generated.MutationIncrementResolver[AppEff] =
        (context, by) -> Counter.increment(context, by)

    /// Mutation.createPost。保存先が無いので input から Post を組み立てて返すだけ
    pub def createPost(): Generated.MutationCreatePostResolver[AppEff] =
        (_context, input) -> Ok({
            id       = Id.Id("new"),
            title    = input#title,
            status   = input#status |> Option.getWithDefault(Generated.PostStatus.Draft),
            authorId = input#authorId
        })

    /// type Mutation のリゾルバ一式
    pub def resolvers(): Generated.MutationResolvers[AppEff] =
        { increment = increment(), createPost = createPost() }

}
