use Schema.{arg, field0, field1, field2, objectType}
use GraphqlTestKit.{executeOnce, executeQuery, executeRequest, queryOnly, queryOnlySchema}

///
/// Graphql（graphql-java 込み）: 引数と戻り値の値の変換。既定値、Float、リスト、null 混じり、enum。
///

///
/// テスト用の enum。
///
pub enum Color {
    case Red
    case Blue
}

///
/// Color の GqlCodec。
///
def colorCodec(): GqlCodec[Color] =
    GqlCodec.enumOf("Color", color -> match color { case Color.Red => "RED" case Color.Blue => "BLUE" }, Color.Red :: Color.Blue :: Nil)

///
/// 値の変換を試すフィールド一覧。
///
def valueFields(): List[Field[Unit, IO]] =
    field1("greet", arg("name", GqlCodec.string()) |> Arg.withDefault("world"), Out.string(), (_context, _root, name) -> Ok("hi ${name}")) ::
    field1("half", arg("x", GqlCodec.float64()), Out.float64(), (_context, _root, x) -> Ok(x / 2.0)) ::
    field1("count", arg("ids", GqlCodec.list(GqlCodec.id())), Out.int32(), (_context, _root, ids) -> Ok(List.length(ids))) ::
    field1("echoInts", arg("xs", GqlCodec.list(GqlCodec.option(GqlCodec.int32()))), Out.list(Out.option(Out.int32())), (_context, _root, xs) -> Ok(xs)) ::
    field0("holes", Out.list(Out.option(Out.int32())), (_context, _root) -> Ok(Some(1) :: None :: Nil)) ::
    field0("grid", Out.list(Out.list(Out.int32())), (_context, _root) -> Ok((1 :: 2 :: Nil) :: (3 :: Nil) :: Nil)) ::
    field1("opposite", arg("color", colorCodec()) |> Arg.withDefault(Color.Red), Out.scalar(colorCodec()),
        (_context, _root, color) -> Ok(match color { case Color.Red => Color.Blue case Color.Blue => Color.Red })) ::
    Nil

/// 省略した引数には withDefault の値が届く。
@Test
def testGraphqlJavaDefaultArgument(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "greet" => Value.Str("hi world") }), None)),
        executeQuery(queryOnlySchema(valueFields()), "{ greet }"))

/// Float の引数には Int のリテラルも variables の Int も渡せる。
@Test
def testGraphqlJavaFloatArgumentAcceptsInt(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = (Ok((Value.Obj(Map#{ "half" => Value.Float(1.5) }), None)), Ok((Value.Obj(Map#{ "half" => Value.Float(1.5) }), None))),
        (executeQuery(queryOnlySchema(valueFields()), "{ half(x: 3) }"),
         executeRequest(queryOnlySchema(valueFields()), { queryText = "query($x: Float!) { half(x: $x) }", variables = Map#{ "x" => Value.Int(3) }, operationName = None })))

/// リストの引数は要素ごとにデコードされ、null 混じりの [Int] も Option で届いてそのまま返せる。
@Test
def testGraphqlJavaListArguments(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "count" => Value.Int(2), "echoInts" => Value.List(Value.Int(1) :: Value.Null :: Value.Int(3) :: Nil) }), None)),
        executeQuery(queryOnlySchema(valueFields()), "{ count(ids: [\"a\", 1]) echoInts(xs: [1, null, 3]) }"))

/// 戻り値の None は null、2 段のリストは [[Int!]!]! で返る。
@Test
def testGraphqlJavaNestedListReturns(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{
            "holes" => Value.List(Value.Int(1) :: Value.Null :: Nil),
            "grid"  => Value.List(Value.List(Value.Int(1) :: Value.Int(2) :: Nil) :: Value.List(Value.Int(3) :: Nil) :: Nil) }), None)),
        executeQuery(queryOnlySchema(valueFields()), "{ holes grid }"))

/// enum は引数にも戻り値にも使え、既定値は引用符無しで SDL に出る。
@Test
def testGraphqlJavaEnum(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = (Ok((Value.Obj(Map#{ "opposite" => Value.Str("RED") }), None)), Ok((Value.Obj(Map#{ "opposite" => Value.Str("BLUE") }), None)), Ok(true), Ok(true)),
        (executeQuery(queryOnlySchema(valueFields()), "{ opposite(color: BLUE) }"),
         executeQuery(queryOnlySchema(valueFields()), "{ opposite }"),
         Schema.toSdl(queryOnlySchema(valueFields())) |> Result.map(String.contains(substr = "enum Color {\n  RED\n  BLUE\n}")),
         Schema.toSdl(queryOnlySchema(valueFields())) |> Result.map(String.contains(substr = "opposite(color: Color! = RED): Color!"))))

/// Int の範囲を超える値は graphql-java の検証で落ち、リゾルバに届かない。
@Test
def testGraphqlJavaIntOverflowIsValidationError(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Null, true)),
        executeQuery(GraphqlTestKit.appSchema(0), "{ add(a: 2147483648, b: 1) }")
            |> Result.map(match (data, message) -> (data, GraphqlTestKit.isValidationError(message))))

/// description に " や """ が入っても SDL ではエスケープされ、エンジンが組み立てられる。
@Test
def testGraphqlJavaDescriptionEscaping(): Unit \ {Assert, IO} =
    let schema = queryOnlySchema(
        (field0("ping", Out.string(), (_context, _root) -> Ok("pong")) |> Field.withDescription("say \"\"\"pong\"\"\"")) :: Nil);
    Assert.assertEq(expected = (Ok((Value.Obj(Map#{ "ping" => Value.Str("pong") }), None)), Ok(true)),
        (executeQuery(schema, "{ ping }"),
         Schema.toSdl(schema) |> Result.map(String.contains(substr = "  \"say \\\"\\\"\\\"pong\\\"\\\"\\\"\"\n  ping: String!"))))

// ---- エラーの位置 ----

/// 非 null のフィールドが Err を返すと、エラーは 1 件で、null は非 null を辿って data 全体まで上がる。
/// locations にはクエリ内の行と列が付く。
@Test
def testGraphqlJavaNonNullErrBubbles(): Unit \ {Assert, IO} =
    let schema = queryOnlySchema(field0("strict", Out.int32(), (_context, _root) -> Err("boom")) :: Nil);
    Assert.assertEq(expected = Ok((Value.Null, 1, Some("boom"), Value.List(Value.Obj(Map#{ "line" => Value.Int(1), "column" => Value.Int(3) }) :: Nil))),
        executeOnce(schema, queryOnly("{ strict }"))
            |> Result.map(response -> (response#data, List.length(response#errors), GraphqlTestKit.firstMessage(response),
                                       GraphqlTestKit.firstErrorField("locations", response))))

/// リストの要素の子フィールドが Err を返すと、path に要素の添字が入り、他の要素はそのまま返る。
@Test
def testGraphqlJavaListChildErrPath(): Unit \ {Assert, IO} =
    let itemType = objectType("Item", () ->
        field0("v", Out.option(Out.int32()), (_context, n) -> if (n == 2) Err("bad item") else Ok(Some(n))) :: Nil);
    let schema = queryOnlySchema(field0("items", Out.list(Out.obj(itemType)), (_context, _root) -> Ok(1 :: 2 :: 3 :: Nil)) :: Nil);
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "items" => Value.List(
                Value.Obj(Map#{ "v" => Value.Int(1) }) :: Value.Obj(Map#{ "v" => Value.Null }) :: Value.Obj(Map#{ "v" => Value.Int(3) }) :: Nil) }),
            Value.List(Value.Str("items") :: Value.Int(1) :: Value.Str("v") :: Nil))),
        executeOnce(schema, queryOnly("{ items { v } }"))
            |> Result.map(response -> (response#data, GraphqlTestKit.firstErrorField("path", response))))
