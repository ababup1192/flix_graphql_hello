///
/// 記事。CMS の本体になる予定の型で、今は固定データ。status は SDL の enum から生成された型。
///
pub type alias Post = { id = Id, title = String, status = Generated.PostStatus, authorId = Id }

///
/// 記事の書き手。
///
pub type alias Author = { id = Id, name = String }

///
/// 記事と書き手の固定データ。Post.author と Author.posts が互いを参照する、ネストした型の見本。
///
mod Post {

    ///
    /// 全記事。
    ///
    pub def all(): List[Post] =
        { id = Id.Id("p1"), title = "Flix で GraphQL", status = Generated.PostStatus.Published, authorId = Id.Id("a1") } ::
        { id = Id.Id("p2"), title = "代数的 effect の使い所", status = Generated.PostStatus.Published, authorId = Id.Id("a1") } ::
        { id = Id.Id("p3"), title = "Raspberry Pi で自宅サーバ", status = Generated.PostStatus.Published, authorId = Id.Id("a2") } ::
        { id = Id.Id("p4"), title = "書きかけ", status = Generated.PostStatus.Draft, authorId = Id.Id("a2") } ::
        Nil

    ///
    /// 全書き手。
    ///
    pub def authors(): List[Author] =
        { id = Id.Id("a1"), name = "abab" } ::
        { id = Id.Id("a2"), name = "guest" } ::
        Nil

    ///
    /// 状態で記事を絞る。
    ///
    pub def byStatus(status: Generated.PostStatus): List[Post] =
        all() |> List.filter(post -> post#status == status)

    ///
    /// ID で記事を探す。
    ///
    pub def find(id: Id): Option[Post] =
        all() |> List.find(post -> post#id == id)

    ///
    /// ID で書き手を探す。
    ///
    pub def findAuthor(id: Id): Option[Author] =
        authors() |> List.find(author -> author#id == id)

    ///
    /// 書き手の記事一覧。
    ///
    pub def byAuthor(authorId: Id): List[Post] =
        all() |> List.filter(post -> post#authorId == authorId)

}
