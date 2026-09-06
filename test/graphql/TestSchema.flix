use Schema.{arg, field0, field1, field2, objectType}

///
/// Schema: DSL の値から SDL を出す。graphql-java は使わない。
///

///
/// Post ⇄ Author の相互参照を含むサンプル（アプリのスキーマそのもの）。
///
def sampleSchema(): Schema \ IO = GraphqlTestKit.appSchema(0)

/// Query から到達できる型が深さ優先で Query → Post → PostStatus → Author → SearchResult → Node → Mutation → PostInput の順に、重複なく 1 回ずつ出る。
/// Option は nullable、それ以外は !、List は [T!]!。
@Test
def testSchemaToSdl(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(List.join("\n",
        "schema {" ::
        "  query: Query" ::
        "  mutation: Mutation" ::
        "}" ::
        "" ::
        "type Query {" ::
        "  add(a: Int!, b: Int!): Int!" ::
        "  \"n 番目のフィボナッチ数\"" ::
        "  fibonacci(n: Int!): Int!" ::
        "  post(id: ID!): Post" ::
        "  \"status を省くと PUBLISHED だけ。null を渡すと全件\"" ::
        "  posts(status: PostStatus = PUBLISHED): [Post!]!" ::
        "  counter: Int!" ::
        "  \"title か name に text を含む記事と書き手\"" ::
        "  search(text: String!): [SearchResult!]!" ::
        "  node(id: ID!): Node" ::
        "}" ::
        "" ::
        "\"記事\"" ::
        "type Post implements Node {" ::
        "  id: ID!" ::
        "  title: String!" ::
        "  status: PostStatus!" ::
        "  author: Author!" ::
        "}" ::
        "" ::
        "\"記事の公開状態\"" ::
        "enum PostStatus {" ::
        "  \"下書き。一覧には出ない\"" ::
        "  DRAFT" ::
        "  PUBLISHED" ::
        "}" ::
        "" ::
        "type Author implements Node {" ::
        "  id: ID!" ::
        "  name: String!" ::
        "  posts: [Post!]!" ::
        "}" ::
        "" ::
        "\"検索結果\"" ::
        "union SearchResult = Post | Author" ::
        "" ::
        "\"ID で引ける物\"" ::
        "interface Node {" ::
        "  id: ID!" ::
        "}" ::
        "" ::
        "type Mutation {" ::
        "  increment(by: Int!): Int!" ::
        "  \"保存はしない。input から組み立てた Post を返すだけ\"" ::
        "  createPost(input: PostInput!): Post!" ::
        "}" ::
        "" ::
        "\"createPost の入力\"" ::
        "input PostInput {" ::
        "  title: String!" ::
        "  status: PostStatus = DRAFT" ::
        "  authorId: ID!" ::
        "}" :: Nil)),
        Schema.toSdl(sampleSchema()))

/// description は前の行の文字列リテラル、deprecated は @deprecated（reason 無しなら引数無し）、引数の default は = で出る。
@Test
def testSchemaToSdlDecorations(): Unit \ Assert =
    let schema = Schema.make(objectType("Query", () ->
        (field1("greet", arg("name", GqlCodec.string()) |> Arg.withDefault("world"), Out.string(), (_context, _root, name) -> Ok(name))
            |> Field.withDescription("挨拶") |> Field.withDeprecation("use hello")) ::
        (field0("old", Out.int32(), (_context, _root) -> Ok(1)) |> Field.deprecate) :: Nil), None, Runner.io());
    Assert.assertEq(expected = Ok("schema {\n  query: Query\n}\n\ntype Query {\n  \"挨拶\"\n  greet(name: String! = \"world\"): String! @deprecated(reason: \"use hello\")\n  old: Int! @deprecated\n}"),
        Schema.toSdl(schema))

/// 型の description は宣言の直前の行、enum 値の description は値の直前の行、enum 値の @deprecated は末尾に出る（Color は TestGraphqlJavaValues の enum）。
@Test
def testSchemaTypeDescriptions(): Unit \ Assert =
    let color = GqlCodec.enumOf("Color", c -> match c { case Color.Red => "RED" case Color.Blue => "BLUE" }, Color.Red :: Color.Blue :: Nil)
        |> GqlCodec.describe("色") |> GqlCodec.describeValue(Color.Red, "赤") |> GqlCodec.deprecateValue(Color.Blue, Deprecation.NoReason);
    let schema = Schema.make(objectType("Query", () -> field0("c", Out.scalar(color), (_context, _root) -> Ok(Color.Red)) :: Nil) |> ObjectType.withDescription("root"), None, Runner.io());
    Assert.assertEq(expected = Ok("schema {\n  query: Query\n}\n\n\"root\"\ntype Query {\n  c: Color!\n}\n\n\"色\"\nenum Color {\n  \"赤\"\n  RED\n  BLUE @deprecated\n}"),
        Schema.toSdl(schema))

/// 同じ名前で中身が違うオブジェクト型は Err。同じ中身なら 1 回だけ出る。
@Test
def testSchemaDuplicateTypeName(): Unit \ Assert =
    let item = objectType("Item", () -> field0("a", Out.int32(), (_context, n) -> Ok(n)) :: Nil);
    let other = objectType("Item", () -> field0("b", Out.int32(), (_context, n) -> Ok(n)) :: Nil);
    let same = Schema.make(objectType("Query", () ->
        field0("x", Out.obj(item), (_context, _root) -> Ok(1)) :: field0("y", Out.obj(item), (_context, _root) -> Ok(2)) :: Nil), None, Runner.io());
    let conflicting = Schema.make(objectType("Query", () ->
        field0("x", Out.obj(item), (_context, _root) -> Ok(1)) :: field0("y", Out.obj(other), (_context, _root) -> Ok(2)) :: Nil), None, Runner.io());
    Assert.assertEq(expected = (Ok(2), true),
        (Schema.collectTypes(same) |> Result.map(List.length), Schema.toSdl(conflicting) |> Result.isErr))

/// Arg.decode は無い引数を nullable なら None、non-null なら引数名と型を含む Err にする。
@Test
def testSchemaArgDecode(): Unit \ Assert =
    Assert.assertEq(expected = (Ok(None), Err("argument 'n' must be Int!: expected Int"), Ok(3)),
        (Arg.decode(arg("n", GqlCodec.option(GqlCodec.int32())), Map#{}),
         Arg.decode(arg("n", GqlCodec.int32()), Map#{}),
         Arg.decode(arg("n", GqlCodec.int32()), Map#{ "n" => Value.Int(3) })))

/// Out.option を二重に重ねても SDL の nullable は 1 段。
@Test
def testSchemaOptionCollapses(): Unit \ Assert =
    Assert.assertEq(expected = "Int",
        TypeRef.toSdl(Out.typeRef(Runner.io(), Out.option(Out.option(Out.int32())))))

/// src/generated/GeneratedSchema.flix は今の schema.graphql から、本体が期待する版の生成器で作った物（生成し忘れの検出）。
@Test
def testSchemaGeneratedIsUpToDate(): Unit \ {Assert, Fs.FileRead} =
    Assert.assertEq(expected = Ok(()),
        Fs.FileRead.read("schema.graphql") |> Result.mapErr(ToString.toString) |> Result.flatMap(sdl -> GeneratedCheck.check(
            { label = "test/sample/GeneratedSchema.flix", sdlPath = "schema.graphql", sdlText = Generated.sdlText(), generatorVersion = Generated.generatorVersion() }, sdl)))

/// src/generated/GeneratedAdminSchema.flix も同じく admin.graphql と一致する。
@Test
def testAdminSchemaGeneratedIsUpToDate(): Unit \ {Assert, Fs.FileRead} =
    Assert.assertEq(expected = Ok(()),
        Fs.FileRead.read("admin.graphql") |> Result.mapErr(ToString.toString) |> Result.flatMap(sdl -> GeneratedCheck.check(GeneratedCheck.admin(), sdl)))
