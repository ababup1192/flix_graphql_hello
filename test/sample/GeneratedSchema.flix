///
/// schema.graphql から schemagen が生成したファイル。手で編集しない（`make generate` で作り直す）。
///
mod Generated {

    /// 生成元の SDL 本文（改行は LF）。GeneratedCheck が schema.graphql と照合する
    pub def sdlText(): String = "type Query {\n  add(a: Int!, b: Int!): Int!\n  \"\"\"n 番目のフィボナッチ数\"\"\"\n  fibonacci(n: Int!): Int!\n  post(id: ID!): Post\n  \"\"\"status を省くと PUBLISHED だけ。null を渡すと全件\"\"\"\n  posts(status: PostStatus = PUBLISHED): [Post!]!\n  counter: Int!\n  \"\"\"title か name に text を含む記事と書き手\"\"\"\n  search(text: String!): [SearchResult!]!\n  node(id: ID!): Node\n}\n\n\"\"\"ID で引ける物\"\"\"\ninterface Node {\n  id: ID!\n}\n\n\"\"\"検索結果\"\"\"\nunion SearchResult = Post | Author\n\n\"\"\"記事の公開状態\"\"\"\nenum PostStatus {\n  \"\"\"下書き。一覧には出ない\"\"\"\n  DRAFT\n  PUBLISHED\n}\n\n\"\"\"記事\"\"\"\ntype Post implements Node {\n  id: ID!\n  title: String!\n  status: PostStatus!\n  author: Author!\n}\n\ntype Author implements Node {\n  id: ID!\n  name: String!\n  posts: [Post!]!\n}\n\n\"\"\"createPost の入力\"\"\"\ninput PostInput {\n  title: String!\n  status: PostStatus = DRAFT\n  authorId: ID!\n}\n\ntype Mutation {\n  increment(by: Int!): Int!\n  \"\"\"保存はしない。input から組み立てた Post を返すだけ\"\"\"\n  createPost(input: PostInput!): Post!\n}\n"

    /// 生成した schemagen のバージョン
    pub def generatorVersion(): String = "6"

    /// enum PostStatus。記事の公開状態
    pub enum PostStatus with Eq, Order, ToString {
        /// 下書き。一覧には出ない
        case Draft
        /// PUBLISHED
        case Published
    }

    /// PostStatus の Codec
    pub def postStatusCodec(): GqlCodec[PostStatus] =
        GqlCodec.enumOf("PostStatus", value -> match value { case PostStatus.Draft => "DRAFT" case PostStatus.Published => "PUBLISHED" }, PostStatus.Draft :: PostStatus.Published :: Nil) |> GqlCodec.describe("記事の公開状態") |> GqlCodec.describeValue(PostStatus.Draft, "下書き。一覧には出ない")

    /// input PostInput
    pub type alias PostInput = { title = String, status = Option[PostStatus], authorId = Id }

    /// PostInput の Codec
    pub def postInputCodec(): GqlCodec[PostInput] =
        let f0 = Schema.arg("title", GqlCodec.string());
        let f1 = Schema.arg("status", GqlCodec.option(postStatusCodec())) |> Arg.withDefaultValue(Value.Str("DRAFT"));
        let f2 = Schema.arg("authorId", GqlCodec.id());
        GqlCodec.inputObject("PostInput", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields)) yield { title = v0, status = v1, authorId = v2 }) |> GqlCodec.describe("createPost の入力")

    /// union SearchResult。検索結果。人はこの enum に包んで返す
    pub enum SearchResult {
        /// Post
        case Post(Post)
        /// Author
        case Author(Author)
    }

    /// union SearchResult の Out
    def searchResultOut(resolvers: Resolvers[ef]): Out[SearchResult, ef] =
        Out.union("SearchResult", Out.member(postType(resolvers)) :: Out.member(authorType(resolvers)) :: Nil, (context, value) -> match value { case SearchResult.Post(x) => Out.taggedObj(postType(resolvers), context, x) case SearchResult.Author(x) => Out.taggedObj(authorType(resolvers), context, x) }) |> Out.describe("検索結果")

    /// interface Node。ID で引ける物。人はこの enum に包んで返す
    pub enum Node {
        /// Post
        case Post(Post)
        /// Author
        case Author(Author)
    }

    /// interface Node の Out
    def nodeOut(resolvers: Resolvers[ef]): Out[Node, ef] =
        Out.interface("Node",
            {
                Schema.abstractField("id", Nil, Out.id())
            } ::
            Nil, Out.member(postType(resolvers)) :: Out.member(authorType(resolvers)) :: Nil, (context, value) -> match value { case Node.Post(x) => Out.taggedObj(postType(resolvers), context, x) case Node.Author(x) => Out.taggedObj(authorType(resolvers), context, x) }) |> Out.describe("ID で引ける物")

    /// Query.add
    pub type alias QueryAddResolver[ef: Eff] = Context -> Int32 -> Int32 -> Result[FieldError, Int32] \ ef
    /// Query.fibonacci
    pub type alias QueryFibonacciResolver[ef: Eff] = Context -> Int32 -> Result[FieldError, Int32] \ ef
    /// Query.post
    pub type alias QueryPostResolver[ef: Eff] = Context -> Id -> Result[FieldError, Option[Post]] \ ef
    /// Query.posts
    pub type alias QueryPostsResolver[ef: Eff] = Context -> Option[PostStatus] -> Result[FieldError, List[Post]] \ ef
    /// Query.counter
    pub type alias QueryCounterResolver[ef: Eff] = Context -> Result[FieldError, Int32] \ ef
    /// Query.search
    pub type alias QuerySearchResolver[ef: Eff] = Context -> String -> Result[FieldError, List[SearchResult]] \ ef
    /// Query.node
    pub type alias QueryNodeResolver[ef: Eff] = Context -> Id -> Result[FieldError, Option[Node]] \ ef
    /// Post.id
    pub type alias PostIdResolver[ef: Eff] = Context -> Post -> Result[FieldError, Id] \ ef
    /// Post.title
    pub type alias PostTitleResolver[ef: Eff] = Context -> Post -> Result[FieldError, String] \ ef
    /// Post.status
    pub type alias PostStatusResolver[ef: Eff] = Context -> Post -> Result[FieldError, PostStatus] \ ef
    /// Post.author
    pub type alias PostAuthorResolver[ef: Eff] = Context -> Post -> Result[FieldError, Author] \ ef
    /// Author.id
    pub type alias AuthorIdResolver[ef: Eff] = Context -> Author -> Result[FieldError, Id] \ ef
    /// Author.name
    pub type alias AuthorNameResolver[ef: Eff] = Context -> Author -> Result[FieldError, String] \ ef
    /// Author.posts
    pub type alias AuthorPostsResolver[ef: Eff] = Context -> Author -> Result[FieldError, List[Post]] \ ef
    /// Mutation.increment
    pub type alias MutationIncrementResolver[ef: Eff] = Context -> Int32 -> Result[FieldError, Int32] \ ef
    /// Mutation.createPost
    pub type alias MutationCreatePostResolver[ef: Eff] = Context -> PostInput -> Result[FieldError, Post] \ ef

    /// type Query のリゾルバ一式。ef はリゾルバの効果
    pub type alias QueryResolvers[ef: Eff] = {
        add = QueryAddResolver[ef],
        fibonacci = QueryFibonacciResolver[ef],
        post = QueryPostResolver[ef],
        posts = QueryPostsResolver[ef],
        counter = QueryCounterResolver[ef],
        search = QuerySearchResolver[ef],
        node = QueryNodeResolver[ef]
    }

    /// type Post のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias PostResolvers[ef: Eff] = {
        id = PostIdResolver[ef],
        title = PostTitleResolver[ef],
        status = PostStatusResolver[ef],
        author = PostAuthorResolver[ef]
    }

    /// type Author のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias AuthorResolvers[ef: Eff] = {
        id = AuthorIdResolver[ef],
        name = AuthorNameResolver[ef],
        posts = AuthorPostsResolver[ef]
    }

    /// type Mutation のリゾルバ一式。ef はリゾルバの効果
    pub type alias MutationResolvers[ef: Eff] = {
        increment = MutationIncrementResolver[ef],
        createPost = MutationCreatePostResolver[ef]
    }

    /// type Post の既定リゾルバ。source の同名ラベルをそのまま返す。author は含まない（オブジェクト型を返すか、引数を持つ）
    pub def postDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        title = Context -> { title = String | r1 } -> Result[FieldError, String] \ ef,
        status = Context -> { status = PostStatus | r2 } -> Result[FieldError, PostStatus] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        title = (_context, src) -> Ok(src#title),
        status = (_context, src) -> Ok(src#status)
    }

    /// type Author の既定リゾルバ。source の同名ラベルをそのまま返す。posts は含まない（オブジェクト型を返すか、引数を持つ）
    pub def authorDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        name = Context -> { name = String | r1 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        name = (_context, src) -> Ok(src#name)
    }

    /// 全型のリゾルバ。1 つでも欠けるとコンパイルエラー。ef は全リゾルバで共有する 1 つの効果
    pub type alias Resolvers[ef: Eff] = {
        queryRoot = QueryResolvers[ef],
        post = PostResolvers[ef],
        author = AuthorResolvers[ef],
        mutationRoot = MutationResolvers[ef]
    }

    /// リゾルバ一式からスキーマを組み立てる。runner が ef を IO に落とす
    pub def schema(resolvers: Resolvers[ef], runner: Runner[ef]): Schema =
        Schema.make(queryType(resolvers), Some(mutationType(resolvers)), runner)

    /// type Query
    def queryType(resolvers: Resolvers[ef]): ObjectType[Unit, ef] =
        Schema.objectType("Query", () ->
            {
                let arg0 = Schema.arg("a", GqlCodec.int32());
                let arg1 = Schema.arg("b", GqlCodec.int32());
                Schema.fieldRaw("add", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.int32(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#queryRoot#add)(context, v0, v1)) yield result)
            } ::
            {
                let arg0 = Schema.arg("n", GqlCodec.int32());
                Schema.fieldRaw("fibonacci", Arg.info(arg0) :: Nil, Out.int32(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#fibonacci)(context, v0)) yield result) |> Field.withDescription("n 番目のフィボナッチ数")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("post", Arg.info(arg0) :: Nil, Out.option(Out.obj(postType(resolvers))), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#post)(context, v0)) yield result)
            } ::
            {
                let arg0 = Schema.arg("status", GqlCodec.option(postStatusCodec())) |> Arg.withDefaultValue(Value.Str("PUBLISHED"));
                Schema.fieldRaw("posts", Arg.info(arg0) :: Nil, Out.list(Out.obj(postType(resolvers))), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#posts)(context, v0)) yield result) |> Field.withDescription("status を省くと PUBLISHED だけ。null を渡すと全件")
            } ::
            {
                Schema.fieldRaw("counter", Nil, Out.int32(), (context, _src, _args) ->
                    (resolvers#queryRoot#counter)(context))
            } ::
            {
                let arg0 = Schema.arg("text", GqlCodec.string());
                Schema.fieldRaw("search", Arg.info(arg0) :: Nil, Out.list(searchResultOut(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#search)(context, v0)) yield result) |> Field.withDescription("title か name に text を含む記事と書き手")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("node", Arg.info(arg0) :: Nil, Out.option(nodeOut(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#node)(context, v0)) yield result)
            } ::
            Nil)

    /// type Post
    def postType(resolvers: Resolvers[ef]): ObjectType[Post, ef] =
        Schema.objectType("Post", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#post#id)(context, src))
            } ::
            {
                Schema.fieldRaw("title", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#post#title)(context, src))
            } ::
            {
                Schema.fieldRaw("status", Nil, Out.scalar(postStatusCodec()), (context, src, _args) ->
                    (resolvers#post#status)(context, src))
            } ::
            {
                Schema.fieldRaw("author", Nil, Out.obj(authorType(resolvers)), (context, src, _args) ->
                    (resolvers#post#author)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("記事") |> ObjectType.implementing("Node" :: Nil)

    /// type Author
    def authorType(resolvers: Resolvers[ef]): ObjectType[Author, ef] =
        Schema.objectType("Author", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#author#id)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#author#name)(context, src))
            } ::
            {
                Schema.fieldRaw("posts", Nil, Out.list(Out.obj(postType(resolvers))), (context, src, _args) ->
                    (resolvers#author#posts)(context, src))
            } ::
            Nil) |> ObjectType.implementing("Node" :: Nil)

    /// type Mutation
    def mutationType(resolvers: Resolvers[ef]): ObjectType[Unit, ef] =
        Schema.objectType("Mutation", () ->
            {
                let arg0 = Schema.arg("by", GqlCodec.int32());
                Schema.fieldRaw("increment", Arg.info(arg0) :: Nil, Out.int32(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#increment)(context, v0)) yield result)
            } ::
            {
                let arg0 = Schema.arg("input", postInputCodec());
                Schema.fieldRaw("createPost", Arg.info(arg0) :: Nil, Out.obj(postType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#createPost)(context, v0)) yield result) |> Field.withDescription("保存はしない。input から組み立てた Post を返すだけ")
            } ::
            Nil)

}
