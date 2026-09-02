use Schema.{arg, field0, field1, field2, objectType}

///
/// Schema: DSL の値から SDL を出す。graphql-java は使わない。
///

///
/// Post ⇄ Author の相互参照を含むサンプル（アプリのスキーマそのもの）。
///
def sampleSchema(): Schema = GraphqlTestKit.appSchema(0)

/// Query から到達できる型が深さ優先で Query → Post → PostStatus → Author → Mutation の順に、重複なく 1 回ずつ出る。
/// Option は nullable、それ以外は !、List は [T!]!。
@Test
def testSchemaToSdl(): Unit \ Assert =
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
        "}" ::
        "" ::
        "type Post {" ::
        "  id: ID!" ::
        "  title: String!" ::
        "  status: PostStatus!" ::
        "  author: Author!" ::
        "}" ::
        "" ::
        "enum PostStatus {" ::
        "  DRAFT" ::
        "  PUBLISHED" ::
        "}" ::
        "" ::
        "type Author {" ::
        "  id: ID!" ::
        "  name: String!" ::
        "  posts: [Post!]!" ::
        "}" ::
        "" ::
        "type Mutation {" ::
        "  increment(by: Int!): Int!" ::
        "}" :: Nil)),
        Schema.toSdl(sampleSchema()))

/// description は前の行の文字列リテラル、deprecated は @deprecated（reason 無しなら引数無し）、引数の default は = で出る。
@Test
def testSchemaToSdlDecorations(): Unit \ Assert =
    let schema = Schema.make(objectType("Query", () ->
        (field1("greet", arg("name", GqlCodec.string()) |> Arg.withDefault("world"), Out.string(), (_context, _root, name) -> Ok(name))
            |> Field.withDescription("挨拶") |> Field.withDeprecation("use hello")) ::
        (field0("old", Out.int32(), (_context, _root) -> Ok(1)) |> Field.deprecate) :: Nil), None);
    Assert.assertEq(expected = Ok("schema {\n  query: Query\n}\n\ntype Query {\n  \"挨拶\"\n  greet(name: String! = \"world\"): String! @deprecated(reason: \"use hello\")\n  old: Int! @deprecated\n}"),
        Schema.toSdl(schema))

/// 同じ名前で中身が違うオブジェクト型は Err。同じ中身なら 1 回だけ出る。
@Test
def testSchemaDuplicateTypeName(): Unit \ Assert =
    let item = objectType("Item", () -> field0("a", Out.int32(), (_context, n) -> Ok(n)) :: Nil);
    let other = objectType("Item", () -> field0("b", Out.int32(), (_context, n) -> Ok(n)) :: Nil);
    let same = Schema.make(objectType("Query", () ->
        field0("x", Out.obj(item), (_context, _root) -> Ok(1)) :: field0("y", Out.obj(item), (_context, _root) -> Ok(2)) :: Nil), None);
    let conflicting = Schema.make(objectType("Query", () ->
        field0("x", Out.obj(item), (_context, _root) -> Ok(1)) :: field0("y", Out.obj(other), (_context, _root) -> Ok(2)) :: Nil), None);
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
        TypeRef.toSdl(Out.typeRef(Out.option(Out.option(Out.int32())))))

/// src/generated/GeneratedSchema.flix は今の schema.graphql から、本体が期待する版の生成器で作った物（生成し忘れの検出）。
@Test
def testSchemaGeneratedIsUpToDate(): Unit \ {Assert, Fs.FileRead} =
    Assert.assertEq(expected = Ok(()),
        Fs.FileRead.read("schema.graphql") |> Result.mapErr(ToString.toString) |> Result.flatMap(GeneratedCheck.check))
