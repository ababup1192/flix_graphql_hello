///
/// schemagen: SDL を読んで Flix の生成物を出す。小さな SDL ごとに要点の断片を確かめる。
///

///
/// SDL から生成物の本文を作る。
///
def generate(sdl: String): Result[String, String] \ IO =
    SdlReader.read(sdl) |> Result.flatMap(document -> Emit.render(document, sdl))

///
/// 生成物に無い断片の一覧。全部あれば Ok(Nil)。
///
def missing(fragments: List[String], source: Result[String, String]): Result[String, List[String]] =
    source |> Result.map(text -> List.filter(fragment -> not String.contains(substr = fragment, text), fragments))

///
/// 生成の Err メッセージ。Ok なら "ok"。
///
def errorOf(source: Result[String, String]): String = match source {
    case Ok(_)        => "ok"
    case Err(message) => message
}

// ---- 型の対応 ----

/// スカラーと nullable / list が Flix の型・Codec・Out に対応する。
@Test
def testGenerateScalars(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(Nil), missing(
        "half = Context -> Float64 -> Result[FieldError, Option[Float64]] \\ IO" ::
        "tags = Context -> Option[List[Option[String]]] -> Result[FieldError, List[Id]] \\ IO" ::
        "Schema.arg(\"x\", GqlCodec.float64())" ::
        "Schema.arg(\"xs\", GqlCodec.option(GqlCodec.list(GqlCodec.option(GqlCodec.string()))))" ::
        "Out.list(Out.id())" ::
        "Out.option(Out.float64())" :: Nil,
        generate("type Query { half(x: Float!): Float  tags(xs: [String]): [ID!]! }")))

/// オブジェクト型は人が定義する Flix の型を source に取り、Out.obj で子へ渡す。相互参照も書ける。
@Test
def testGenerateObjects(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(Nil), missing(
        "author = Context -> Post -> Result[FieldError, Author] \\ IO" ::
        "posts = Context -> Author -> Result[FieldError, List[Post]] \\ IO" ::
        "Out.option(Out.obj(postType(resolvers)))" ::
        "def postType(resolvers: Resolvers): ObjectType[Post]" ::
        "(resolvers#author#posts)(context, src)" ::
        "post = PostResolvers" :: Nil,
        generate("type Query { post(id: ID!): Post }  type Post { author: Author! }  type Author { posts: [Post!]! }")))

/// enum は Flix の enum と Codec を生成し、値名は先頭大文字・残り小文字（_ 区切り）になる。
@Test
def testGenerateEnum(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(Nil), missing(
        "pub enum Status with Eq, Order, ToString {" ::
        "case InProgress" ::
        "case Status.InProgressFake => \"IN_PROGRESS_FAKE\"" ::
        "GqlCodec.enumOf(\"Status\", value -> match value { case Status.Draft => \"DRAFT\" case Status.InProgress => \"IN_PROGRESS\"" ::
        "status = Context -> Status -> Result[FieldError, Status] \\ IO" ::
        "Out.scalar(statusCodec())" :: Nil,
        generate("enum Status { DRAFT IN_PROGRESS IN_PROGRESS_FAKE }  type Query { status(s: Status!): Status! }")))

// ---- 飾り ----

/// description / @deprecated / 既定値が生成物に載る。
@Test
def testGenerateDecorations(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(Nil), missing(
        "|> Field.withDescription(\"挨拶\")" ::
        "|> Field.withDeprecation(\"use hello\")" ::
        "|> Arg.withDescription(\"名前\")" ::
        "|> Arg.withDefaultValue(Value.Str(\"world\"))" ::
        "|> Arg.withDefaultValue(Value.List(Value.Int(1) :: Value.Int(2) :: Nil))" :: Nil,
        generate("type Query { \"\"\"挨拶\"\"\" greet(\"名前\" name: String! = \"world\", xs: [Int!]! = [1, 2]): String! @deprecated(reason: \"use hello\") }")))

/// 予約語のフィールド名はラベルの末尾に _ が付き、SDL 名はそのまま残る。
@Test
def testGenerateReservedWord(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(Nil), missing(
        "from_ = Context -> Result[FieldError, String] \\ IO" ::
        "Schema.fieldRaw(\"from\"" ::
        "(resolvers#queryRoot#from_)(context)" :: Nil,
        generate("type Query { from: String! }")))

/// schema ブロックでルート型の名前を変えられる。Mutation が無ければ None。
@Test
def testGenerateSchemaBlock(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(Nil), missing(
        "queryRoot = RootResolvers" ::
        "Schema.make(rootType(resolvers), None)" :: Nil,
        generate("schema { query: Root }  type Root { ping: String! }")))

// ---- エラー ----

/// 未対応の定義、引数へのオブジェクト型、禁止した型名、未定義の型、enum 値の衝突はどれも Err。
@Test
def testGenerateErrors(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = ("対応していない定義です: InputObjectTypeDefinition", "オブジェクト型 Post は引数に使えません（input 型は未対応）",
                                "型名 Value は生成物の名前と衝突するので使えません", "型 Missing が定義されていません", "enum E の値が Flix の名前に変換すると衝突します"),
        (generate("input In { a: Int }  type Query { x: Int }") |> errorOf,
         generate("type Query { x(p: Post!): Int }  type Post { a: Int }") |> errorOf,
         generate("type Query { v: Value! }  type Value { a: Int }") |> errorOf,
         generate("type Query { v: Missing! }") |> errorOf,
         generate("enum E { AB Ab }  type Query { e: E! }") |> errorOf))

/// 生成物が Flix にならない SDL は生成器で止める: 大文字始まりのフィールド名、小文字始まりの型名、
/// ルートから届かない型、先頭が数字になる enum 値。
@Test
def testGenerateIdentifierErrors(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = ("フィールド名・引数名 Query.Big, Query.x(Y) は小文字で始めてください（Flix のラベルの決まり）",
                                "型名 item は大文字で始めてください（Flix の型名の決まり）",
                                "型 Orphan は Query / Mutation から届きません",
                                "enum E の値 _2XL は Flix の名前にできません"),
        (generate("type Query { Big: Int!  x(Y: Int!): Int! }") |> errorOf,
         generate("type Query { i: item! }  type item { a: Int! }") |> errorOf,
         generate("type Query { a: Int! }  type Orphan { a: Int! }") |> errorOf,
         generate("enum E { XL _2XL }  type Query { e: E! }") |> errorOf))

/// subscription（schema ブロックでも type Subscription でも）、@deprecated 以外の directive、extend は未対応として Err。
@Test
def testGenerateUnsupportedErrors(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = ("subscription は未対応です", "subscription は未対応です", "対応していない directive です: @key", "対応していない directive です: @auth", "対応していない定義です: ObjectTypeExtensionDefinition"),
        (generate("schema { query: Query subscription: Sub }  type Query { a: Int! }  type Sub { b: Int! }") |> errorOf,
         generate("type Query { a: Int! }  type Subscription { b: Int! }") |> errorOf,
         generate("type Query { a: Int! @key(x: 1) }") |> errorOf,
         generate("type Query { a(x: Int! @auth): Int! }") |> errorOf,
         generate("type Query { a: Int! }  extend type Query { b: Int! }") |> errorOf))

/// 型・enum・enum 値に付いた directive と extend schema は黙って落とさず Err。生成物の名前と重なる型名（ObjectType）も Err。
@Test
def testGenerateTypeLevelUnsupportedErrors(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = ("対応していない directive です: @key", "対応していない directive です: @deprecated", "対応していない directive です: @internal",
                                "対応していない定義です: SchemaExtensionDefinition", "型名 ObjectType は生成物の名前と衝突するので使えません"),
        (generate("type Query @key(fields: \"a\") { a: Int! }") |> errorOf,
         generate("enum E { A @deprecated(reason: \"x\") B }  type Query { e: E! }") |> errorOf,
         generate("enum E @internal { A }  type Query { e: E! }") |> errorOf,
         generate("extend schema @foo { query: Query }  type Query { a: Int! }") |> errorOf,
         generate("type Query { o: ObjectType! }  type ObjectType { a: Int! }") |> errorOf))

/// 生成元の SDL 本文がそのまま生成物に埋まる（引用符と改行はエスケープ）。
@Test
def testGenerateEmbedsSdl(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(Nil), missing(
        "pub def sdlText(): String = \"type Query {\\n  \\\"\\\"\\\"a\\\"\\\"\\\" a: Int!\\n}\"" :: Nil,
        generate("type Query {\n  \"\"\"a\"\"\" a: Int!\n}")))

/// Float の既定値は指数表記でも Flix のリテラルになり、enum の既定値は Value.Str、reason 無しの @deprecated は Field.deprecate になる。
@Test
def testGenerateMoreDecorations(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(Nil), missing(
        "Arg.withDefaultValue(Value.Float(10000000000.0))" ::
        "Arg.withDefaultValue(Value.Float(0.5))" ::
        "Arg.withDefaultValue(Value.Str(\"RED\"))" ::
        "|> Field.deprecate" :: Nil,
        generate("enum Color { RED }  type Query { a(x: Float = 1e10, y: Float = 0.5, c: Color = RED): Int! @deprecated }")))

/// schema ブロックで Mutation の名前も変えられ、Mutation が定義されていなければ None になる。HTTP_2 は Http2。
@Test
def testGenerateRootsAndEnumNames(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = (Ok(Nil), Ok(Nil), Ok(Nil)),
        (missing("Schema.make(queryType(resolvers), Some(changesType(resolvers)))" :: "mutationRoot = ChangesResolvers" :: Nil,
            generate("schema { query: Query mutation: Changes }  type Query { a: Int! }  type Changes { b: Int! }")),
         missing("Schema.make(queryType(resolvers), None)" :: Nil, generate("type Query { a: Int! }")),
         missing("case Http2" :: "case Status.Http2 => \"HTTP_2\"" :: Nil, generate("enum Status { HTTP_2 }  type Query { s: Status! }"))))

/// 壊れた SDL は Err（例外にならない）。
@Test
def testGenerateBrokenSdl(): Unit \ {Assert, IO} =
    Assert.assertTrue(generate("type Query { x: ") |> Result.isErr)
