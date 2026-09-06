use Schema.{arg, field0, field1, field2, objectType}
use GraphqlTestKit.{appSchema, executeOnce, executeQuery, executeRequest, queryOnly, queryOnlySchema}

///
/// Graphql（graphql-java 込み）: Schema の値からエンジンを組み立て、runWithEngine で本当にクエリを流す。
///

///
/// アプリのスキーマ（schema.graphql から生成した物 + AppSchema のリゾルバ）。カウンタはメモリ上。
///
def testSchema(): Schema \ IO = appSchema(0)

///
/// いつも Err("boom") を返す fail だけのスキーマ。
///
def failSchema(): Schema =
    queryOnlySchema(field0("fail", Out.option(Out.int32()), (_context, _root) -> Err("boom")) :: Nil)

// ---- クエリの実行 ----

/// add と fibonacci を 1 つのクエリで呼ぶと、data に両方の値が入り errors は空。
@Test
def testGraphqlJavaExecutesQuery(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "add" => Value.Int(3), "fibonacci" => Value.Int(55) }), None)),
        executeQuery(testSchema(), "{ add(a: 1, b: 2) fibonacci(n: 10) }"))

/// variables で渡した $a がリゾルバの引数 a に届く。
@Test
def testGraphqlJavaVariables(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "add" => Value.Int(3) }), None)),
        executeRequest(testSchema(), { queryText = "query($a: Int!) { add(a: $a, b: 2) }", variables = Map#{ "a" => Value.Int(1) }, operationName = None }))

/// 名前付きの操作が 2 つあるクエリでは、operationName で選んだ方だけが実行される。
@Test
def testGraphqlJavaOperationName(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "fibonacci" => Value.Int(55) }), None)),
        executeRequest(testSchema(), { queryText = "query First { add(a: 1, b: 2) } query Second { fibonacci(n: 10) }", variables = Map.empty(), operationName = Some("Second") }))

// ---- ネストしたオブジェクト型（source が型付きで子へ届く） ----

/// post(id) の戻りの Post レコードが source として Post.author に届き、さらに Author.posts まで辿れる。
///
///   post(p1) ─▶ author(a1) ─▶ posts: [p1, p2]
@Test
def testGraphqlJavaNestedSource(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "post" => Value.Obj(Map#{
            "title"  => Value.Str("Flix で GraphQL"),
            "author" => Value.Obj(Map#{
                "name"  => Value.Str("abab"),
                "posts" => Value.List(Value.Obj(Map#{ "id" => Value.Str("p1") }) :: Value.Obj(Map#{ "id" => Value.Str("p2") }) :: Nil) }) }) }), None)),
        executeQuery(testSchema(), "{ post(id: \"p1\") { title author { name posts { id } } } }"))

/// 見つからない ID では nullable の post が null になり、errors は無い。
@Test
def testGraphqlJavaNullableObject(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "post" => Value.Null }), None)),
        executeQuery(testSchema(), "{ post(id: \"nope\") { title } }"))

/// リストの各要素が source として子フィールドに届く。status を省略すると既定値 PUBLISHED で絞られる。
@Test
def testGraphqlJavaListOfObjects(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "posts" => Value.List(
            Value.Obj(Map#{ "id" => Value.Str("p1") }) :: Value.Obj(Map#{ "id" => Value.Str("p2") }) :: Value.Obj(Map#{ "id" => Value.Str("p3") }) :: Nil) }), None)),
        executeQuery(testSchema(), "{ posts { id } }"))

/// 生成された enum は引数にも戻り値にも使える。DRAFT で絞ると p4 だけで、status もそのまま返る。
@Test
def testGraphqlJavaGeneratedEnum(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "posts" => Value.List(
            Value.Obj(Map#{ "id" => Value.Str("p4"), "status" => Value.Str("DRAFT") }) :: Nil) }), None)),
        executeQuery(testSchema(), "{ posts(status: DRAFT) { id status } }"))

/// 子フィールドのリゾルバは、クエリで選ばれたときだけ走る。
/// Item.broken は Err を返すが、選ばなければエラーにならない。選べばエラーになる。
@Test
def testGraphqlJavaChildRunsOnlyWhenSelected(): Unit \ {Assert, IO} =
    let itemType = objectType("Item", () ->
        field0("ok", Out.int32(), (_context, item) -> Ok(item)) ::
        field0("broken", Out.option(Out.int32()), (_context, _item) -> Err("child boom")) ::
        Nil);
    let schema = queryOnlySchema(field0("item", Out.obj(itemType), (_context, _root) -> Ok(7)) :: Nil);
    Assert.assertEq(
        expected = (Ok((Value.Obj(Map#{ "item" => Value.Obj(Map#{ "ok" => Value.Int(7) }) }), None)),
                    Ok((Value.Obj(Map#{ "item" => Value.Obj(Map#{ "broken" => Value.Null }) }), Some("child boom")))),
        (executeQuery(schema, "{ item { ok } }"), executeQuery(schema, "{ item { broken } }")))

/// Context はルートから子フィールドまで同じ物が届く。
@Test
def testGraphqlJavaContextReachesChild(): Unit \ {Assert, IO} =
    let itemType = objectType("Item", () ->
        field0("user", Out.option(Out.string()), (context, _item) -> Ok(context#userId)) :: Nil);
    let schema = queryOnlySchema(field0("item", Out.obj(itemType), (_context, _root) -> Ok(())) :: Nil);
    Assert.assertEq(expected = Ok(Value.Obj(Map#{ "item" => Value.Obj(Map#{ "user" => Value.Str("u1") }) })),
        Graphql.buildEngine(schema)
            |> Result.map(engine -> Graphql.runWithEngine(engine, () -> Graphql.execute(queryOnly("{ item { user } }"), { userId = Some("u1") })))
            |> Result.map(response -> response#data))

// ---- エラーの報告 ----

/// スキーマに無いフィールドを問い合わせると、data は Null で、検証エラーが 1 つ返る。
@Test
def testGraphqlJavaUnknownFieldIsError(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Null, 1, Some("Validation error (FieldUndefined@[nope]) : Field 'nope' in type 'Query' is undefined"))),
        executeOnce(testSchema(), queryOnly("{ nope }"))
            |> Result.map(response -> (response#data, List.length(response#errors), GraphqlTestKit.firstMessage(response))))

/// リゾルバが Err を返すと、そのフィールドは null になり、Err のメッセージがそのまま message になったエラーが 1 つ返る。
/// path はそのフィールドの位置。
@Test
def testGraphqlJavaResolverErrIsReported(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "fail" => Value.Null }), 1, Some("boom"), Value.List(Value.Str("fail") :: Nil))),
        executeOnce(failSchema(), queryOnly("{ fail }"))
            |> Result.map(response -> (response#data, List.length(response#errors), GraphqlTestKit.firstMessage(response),
                                       GraphqlTestKit.firstErrorField("path", response))))

/// 引数の型が合わないクエリは graphql-java の検証で落ち、リゾルバまで届かない。
@Test
def testGraphqlJavaBadArgumentIsValidationError(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Null, true)),
        executeQuery(testSchema(), "{ add(a: \"x\", b: 2) }")
            |> Result.map(match (data, message) -> (data, GraphqlTestKit.isValidationError(message))))

// ---- union / interface ----

/// union は __typename で枝が分かれ、inline fragment で枝ごとのフィールドが引ける。枝のリゾルバは通常のオブジェクト型と同じ経路。
@Test
def testGraphqlJavaUnion(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "search" => Value.List(
            Value.Obj(Map#{ "__typename" => Value.Str("Post"), "title" => Value.Str("Raspberry Pi で自宅サーバ"), "author" => Value.Obj(Map#{ "name" => Value.Str("guest") }) }) ::
            Value.Obj(Map#{ "__typename" => Value.Str("Author"), "name" => Value.Str("abab") }) :: Nil) }), None)),
        executeQuery(testSchema(), "{ search(text: \"b\") { __typename ... on Post { title author { name } } ... on Author { name } } }"))

/// interface は共通フィールドをそのまま選べ、実装型のフィールドは inline fragment で引ける。無ければ null。
@Test
def testGraphqlJavaInterface(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{
            "a" => Value.Obj(Map#{ "id" => Value.Str("p1"), "__typename" => Value.Str("Post"), "title" => Value.Str("Flix で GraphQL") }),
            "b" => Value.Obj(Map#{ "id" => Value.Str("a2"), "__typename" => Value.Str("Author") }),
            "c" => Value.Null }), None)),
        executeQuery(testSchema(), "{ a: node(id: \"p1\") { id __typename ... on Post { title } } b: node(id: \"a2\") { id __typename } c: node(id: \"zz\") { id } }"))

/// interface のリスト。要素ごとに TypeResolver が呼ばれ、枝ごとの inline fragment が効く（DSL を直接書く）。
@Test
def testGraphqlJavaInterfaceList(): Unit \ {Assert, IO} =
    let item = objectType("Item", () -> field0("id", Out.id(), (_context, n) -> Ok(Id.Id("i${n}"))) :: field0("n", Out.int32(), (_context, n) -> Ok(n)) :: Nil) |> ObjectType.implementing("Node" :: Nil);
    let node = Out.interface("Node", Schema.abstractField("id", Nil, Out.id()) :: Nil, Out.member(item) :: Nil, (context, n) -> Out.taggedObj(item, context, n));
    let schema = queryOnlySchema(field0("nodes", Out.list(node), (_context, _root) -> Ok(1 :: 2 :: Nil)) :: Nil);
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "nodes" => Value.List(
            Value.Obj(Map#{ "id" => Value.Str("i1"), "n" => Value.Int(1) }) :: Value.Obj(Map#{ "id" => Value.Str("i2"), "n" => Value.Int(2) }) :: Nil) }), None)),
        executeQuery(schema, "{ nodes { id ... on Item { n } } }"))

/// Out.union の encode で taggedObj を使わず型名のタグが無いと、graphql-java が具体型を決められずエラーになる。
@Test
def testGraphqlJavaUntaggedUnionValueIsError(): Unit \ {Assert, IO} =
    let item = objectType("Item", () -> field0("n", Out.int32(), (_context, n) -> Ok(n)) :: Nil);
    let bad = Out.union("U", Out.member(item) :: Nil, (context, n) -> Out.encode(Out.obj(item), context, n));
    let schema = queryOnlySchema(field0("u", bad, (_context, _root) -> Ok(1)) :: Nil);
    Assert.assertEq(expected = Ok(true),
        executeQuery(schema, "{ u { ... on Item { n } } }") |> Result.map(match (_, message) -> message |> Option.map(String.contains(substr = "Could not determine the exact type")) |> Option.getWithDefault(false)))

/// interface の枝に入れた型が implementing していないと、SDL を出す前に Err になる（手書きの DSL の書き忘れ）。
@Test
def testGraphqlJavaInterfaceMemberWithoutImplementsIsErr(): Unit \ Assert =
    let item: ObjectType[Int32, IO] = objectType("Item", () -> field0("id", Out.id(), (_context, _n) -> Ok(Id.Id("x"))) :: Nil);
    let node: Out[Int32, IO] = Out.interface("Node", Schema.abstractField("id", Nil, Out.id()) :: Nil, Out.member(item) :: Nil, (context, n) -> Out.taggedObj(item, context, n));
    let schema = queryOnlySchema(field0("node", node, (_context, _root) -> Ok(1)) :: Nil);
    Assert.assertEq(expected = Err("型 Item は interface Node の枝ですが implements していません"), Schema.toSdl(schema))

// ---- introspection ----

/// 型と enum 値の description は introspection でクライアントに見える。
@Test
def testGraphqlJavaIntrospectionDescriptions(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "__type" => Value.Obj(Map#{
            "description" => Value.Str("記事の公開状態"),
            "enumValues" => Value.List(
                Value.Obj(Map#{ "name" => Value.Str("DRAFT"), "description" => Value.Str("下書き。一覧には出ない") }) ::
                Value.Obj(Map#{ "name" => Value.Str("PUBLISHED"), "description" => Value.Null }) :: Nil) }) }), None)),
        executeQuery(testSchema(), "{ __type(name: \"PostStatus\") { description enumValues { name description } } }"))

// ---- input 型 ----

/// input は variables でも直書きでも Flix のレコードで届き、省いたフィールドは SDL の既定値になる。
@Test
def testGraphqlJavaInputObject(): Unit \ {Assert, IO} =
    let request = { queryText = "mutation ($p: PostInput!) { createPost(input: $p) { title status author { name } } }",
                    variables = Map#{ "p" => Value.Obj(Map#{ "title" => Value.Str("new post"), "authorId" => Value.Str("a1") }) },
                    operationName = None };
    Assert.assertEq(expected = Ok(Value.Obj(Map#{ "createPost" => Value.Obj(Map#{ "title" => Value.Str("new post"), "status" => Value.Str("DRAFT"), "author" => Value.Obj(Map#{ "name" => Value.Str("abab") }) }) })),
        executeOnce(testSchema(), request) |> Result.map(response -> response#data))

/// input のフィールドの型違いは graphql-java の validation で止まり、リゾルバは走らない。
@Test
def testGraphqlJavaInputObjectBadFieldIsValidationError(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Null, true)),
        executeQuery(testSchema(), "mutation { createPost(input: { title: 1, authorId: \"a1\" }) { title } }")
            |> Result.map(match (data, message) -> (data, GraphqlTestKit.isValidationError(message))))

// ---- リゾルバの効果 ----

/// 人が DSL で書くフィールドも `\ CounterStore` と純粋な物を同じ型に混ぜられ、Schema.make の runner がハンドラで IO に落とす。
@Test
def testGraphqlJavaResolverEffectRunsThroughRunner(): Unit \ {Assert, IO} =
    let root = objectType("Query", () ->
        field0("stored", Out.int32(), (_context, _root) -> CounterStore.load()) ::
        field0("pure", Out.int32(), (_context, _root) -> Ok(1)) :: Nil);
    let schema = Schema.make(root, None, f -> CounterFake.runWithMemory(41, f));
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "stored" => Value.Int(41), "pure" => Value.Int(1) }), None)),
        executeQuery(schema, "{ stored pure }"))

// ---- エンジンの組み立て ----

/// 同じ名前で中身の違うオブジェクト型が 2 つあると buildEngine が Err になる。
@Test
def testGraphqlJavaConflictingTypeIsErr(): Unit \ {Assert, IO} =
    let first = objectType("Item", () -> field0("a", Out.int32(), (_context, item) -> Ok(item)) :: Nil);
    let second = objectType("Item", () -> field0("b", Out.int32(), (_context, item) -> Ok(item)) :: Nil);
    let schema = queryOnlySchema(
        field0("x", Out.obj(first), (_context, _root) -> Ok(1)) ::
        field0("y", Out.obj(second), (_context, _root) -> Ok(2)) :: Nil);
    Assert.assertEq(expected = Err(true),
        Graphql.buildEngine(schema) |> Result.map(_ -> false) |> Result.mapErr(String.contains(substr = "Item")))

/// Mutation を持つスキーマでは mutation が実行できる。
@Test
def testGraphqlJavaMutation(): Unit \ {Assert, IO} =
    let schema = Schema.make(
        Schema.objectType("Query", () -> field0("ping", Out.string(), (_context, _root) -> Ok("pong")) :: Nil),
        Some(Schema.objectType("Mutation", () -> field1("echo", arg("text", GqlCodec.string()), Out.string(), (_context, _root, text) -> Ok(text)) :: Nil)),
        Runner.io());
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "echo" => Value.Str("hi") }), None)),
        executeQuery(schema, "mutation { echo(text: \"hi\") }"))
