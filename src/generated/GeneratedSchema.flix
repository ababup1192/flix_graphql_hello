///
/// schema.graphql から schemagen が生成したファイル。手で編集しない（`make generate` で作り直す）。
///
mod Generated {

    /// 生成元の SDL 本文（改行は LF）。GeneratedCheck が schema.graphql と照合する
    pub def sdlText(): String = "type Query {\n  add(a: Int!, b: Int!): Int!\n  \"\"\"n 番目のフィボナッチ数\"\"\"\n  fibonacci(n: Int!): Int!\n  post(id: ID!): Post\n  \"\"\"status を省くと PUBLISHED だけ。null を渡すと全件\"\"\"\n  posts(status: PostStatus = PUBLISHED): [Post!]!\n  counter: Int!\n}\n\nenum PostStatus {\n  DRAFT\n  PUBLISHED\n}\n\ntype Post {\n  id: ID!\n  title: String!\n  status: PostStatus!\n  author: Author!\n}\n\ntype Author {\n  id: ID!\n  name: String!\n  posts: [Post!]!\n}\n\ntype Mutation {\n  increment(by: Int!): Int!\n}\n"

    /// 生成した schemagen のバージョン
    pub def generatorVersion(): String = "1"

    /// enum PostStatus
    pub enum PostStatus with Eq, Order, ToString {
        /// DRAFT
        case Draft
        /// PUBLISHED
        case Published
    }

    /// PostStatus の Codec
    pub def postStatusCodec(): GqlCodec[PostStatus] =
        GqlCodec.enumOf("PostStatus", value -> match value { case PostStatus.Draft => "DRAFT" case PostStatus.Published => "PUBLISHED" }, PostStatus.Draft :: PostStatus.Published :: Nil)

    /// type Query のリゾルバ一式
    pub type alias QueryResolvers = {
        add = Context -> Int32 -> Int32 -> Result[FieldError, Int32] \ IO,
        fibonacci = Context -> Int32 -> Result[FieldError, Int32] \ IO,
        post = Context -> Id -> Result[FieldError, Option[Post]] \ IO,
        posts = Context -> Option[PostStatus] -> Result[FieldError, List[Post]] \ IO,
        counter = Context -> Result[FieldError, Int32] \ IO
    }

    /// type Post のリゾルバ一式。第 2 引数が source
    pub type alias PostResolvers = {
        id = Context -> Post -> Result[FieldError, Id] \ IO,
        title = Context -> Post -> Result[FieldError, String] \ IO,
        status = Context -> Post -> Result[FieldError, PostStatus] \ IO,
        author = Context -> Post -> Result[FieldError, Author] \ IO
    }

    /// type Author のリゾルバ一式。第 2 引数が source
    pub type alias AuthorResolvers = {
        id = Context -> Author -> Result[FieldError, Id] \ IO,
        name = Context -> Author -> Result[FieldError, String] \ IO,
        posts = Context -> Author -> Result[FieldError, List[Post]] \ IO
    }

    /// type Mutation のリゾルバ一式
    pub type alias MutationResolvers = {
        increment = Context -> Int32 -> Result[FieldError, Int32] \ IO
    }

    /// 全型のリゾルバ。1 つでも欠けるとコンパイルエラー
    pub type alias Resolvers = {
        queryRoot = QueryResolvers,
        post = PostResolvers,
        author = AuthorResolvers,
        mutationRoot = MutationResolvers
    }

    /// リゾルバ一式からスキーマを組み立てる
    pub def schema(resolvers: Resolvers): Schema =
        Schema.make(queryType(resolvers), Some(mutationType(resolvers)))

    /// type Query
    def queryType(resolvers: Resolvers): ObjectType[Unit] =
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
            Nil)

    /// type Post
    def postType(resolvers: Resolvers): ObjectType[Post] =
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
            Nil)

    /// type Author
    def authorType(resolvers: Resolvers): ObjectType[Author] =
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
            Nil)

    /// type Mutation
    def mutationType(resolvers: Resolvers): ObjectType[Unit] =
        Schema.objectType("Mutation", () ->
            {
                let arg0 = Schema.arg("by", GqlCodec.int32());
                Schema.fieldRaw("increment", Arg.info(arg0) :: Nil, Out.int32(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#increment)(context, v0)) yield result)
            } ::
            Nil)

}
