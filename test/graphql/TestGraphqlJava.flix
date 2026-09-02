use Schema.{arg, field0, field1, field2, objectType}
use GraphqlTestKit.{appSchema, executeOnce, executeQuery, queryOnly, queryOnlySchema}

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
        executeOnce(testSchema(), { queryText = "query($a: Int!) { add(a: $a, b: 2) }", variables = Map#{ "a" => Value.Int(1) }, operationName = None })
            |> Result.map(response -> (response#data, GraphqlTestKit.firstMessage(response))))

/// 名前付きの操作が 2 つあるクエリでは、operationName で選んだ方だけが実行される。
@Test
def testGraphqlJavaOperationName(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "fibonacci" => Value.Int(55) }), None)),
        executeOnce(testSchema(), { queryText = "query First { add(a: 1, b: 2) } query Second { fibonacci(n: 10) }", variables = Map.empty(), operationName = Some("Second") })
            |> Result.map(response -> (response#data, GraphqlTestKit.firstMessage(response))))

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
                                       List.head(response#errors) |> Option.map(Value.field("path")) |> Option.getWithDefault(Value.Null))))

/// 引数の型が合わないクエリは graphql-java の検証で落ち、リゾルバまで届かない。
@Test
def testGraphqlJavaBadArgumentIsValidationError(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Null, true)),
        executeQuery(testSchema(), "{ add(a: \"x\", b: 2) }")
            |> Result.map(match (data, message) -> (data, message |> Option.map(String.startsWith(prefix = "Validation error")) |> Option.getWithDefault(false))))

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
