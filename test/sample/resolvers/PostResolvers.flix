///
/// type Post のリゾルバ。`make scaffold` が作った雛形で、人が所有する（作り直されない）。
/// id / title / status は source の Post の同名ラベルを返す既定リゾルバに任せる。
///
mod PostResolvers {

    /// Post.author
    pub def author(): Generated.PostAuthorResolver[AppEff] =
        (_context, post) -> Post.findAuthor(post#authorId) |> Option.toOk(FieldError.of(ErrorCode.NotFound, "author '${post#authorId}' not found"))

    /// type Post のリゾルバ一式
    pub def resolvers(): Generated.PostResolvers[AppEff] =
        { +author = author() | Generated.postDefaults() }

}
