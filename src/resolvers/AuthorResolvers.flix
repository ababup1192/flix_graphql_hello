///
/// type Author のリゾルバ。`make scaffold` が作った雛形で、人が所有する（作り直されない）。
/// id / name は source の Author の同名ラベルを返す既定リゾルバに任せる。
///
mod AuthorResolvers {

    /// Author.posts
    pub def posts(): Generated.AuthorPostsResolver[AppEff] =
        (_context, author) -> Ok(Post.byAuthor(author#id))

    /// type Author のリゾルバ一式
    pub def resolvers(): Generated.AuthorResolvers[AppEff] =
        { +posts = posts() | Generated.authorDefaults() }

}
