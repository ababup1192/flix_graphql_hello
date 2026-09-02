///
/// type Post / type Author のリゾルバ。生成された Generated.PostResolvers / AuthorResolvers に合わせる。
///
mod PostResolvers {

    ///
    /// type Post。source は Post のレコード。
    ///
    pub def post(): Generated.PostResolvers = {
        id     = (_context, post) -> Ok(post#id),
        title  = (_context, post) -> Ok(post#title),
        status = (_context, post) -> Ok(post#status),
        author = (_context, post) -> Post.findAuthor(post#authorId) |> Option.toOk("author '${post#authorId}' not found")
    }

    ///
    /// type Author。source は Author のレコード。
    ///
    pub def author(): Generated.AuthorResolvers = {
        id    = (_context, author) -> Ok(author#id),
        name  = (_context, author) -> Ok(author#name),
        posts = (_context, author) -> Ok(Post.byAuthor(author#id))
    }

}
