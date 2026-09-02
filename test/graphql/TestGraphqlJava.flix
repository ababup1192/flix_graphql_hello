///
/// Graphql（graphql-java 込み）: buildEngine でエンジンを組み立て、runWithEngine で本当にクエリを流す。
///

///
/// テスト用の SDL。CalcResolvers.resolvers() の 2 フィールドに、Err を返すリゾルバ用の fail を足している。
///
def testSdl(): String =
    "type Query { add(a: Int!, b: Int!): Int!  fibonacci(n: Int!): Int!  fail: Int }"

///
/// テスト用のリゾルバ。Query.fail はいつも Err("boom") を返す。
///
def testResolvers(): Map[(String, String), Resolver] =
    Map.insert(("Query", "fail"), _ -> checked_ecast(Err("boom")), CalcResolvers.resolvers())

///
/// テスト用のスキーマ（testSdl + testResolvers）。
///
def testSchema(): Schema =
    { sdl = testSdl(), resolvers = testResolvers() }

///
/// variables も operationName も無い、クエリ文字列だけのリクエスト。
///
def queryOnly(queryText: String): GraphqlRequest =
    { queryText = queryText, variables = Map.empty(), operationName = None }

///
/// エンジンを組み立ててリクエストを 1 つ流し、GraphqlResponse を返す。組み立てに失敗すれば Err。
///
def executeOnce(schema: Schema, request: GraphqlRequest): Result[String, GraphqlResponse] \ IO =
    Graphql.buildEngine(schema)
        |> Result.map(engine -> Graphql.runWithEngine(engine, () -> Graphql.execute(request)))

///
/// errors の先頭の "message" を文字列で取り出す。errors が空か message が文字列でなければ None。
///
def firstMessage(response: GraphqlResponse): Option[String] =
    List.head(response#errors) |> Option.map(Value.field("message")) |> Option.flatMap(Value.asStr)

// ---- クエリの実行 ----

/// add と fibonacci を 1 つのクエリで呼ぶと、data に両方の値が入り errors は空。
@Test
def testGraphqlJavaExecutesQuery(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "add" => Value.Int(3), "fibonacci" => Value.Int(55) }), None)),
        executeOnce(testSchema(), queryOnly("{ add(a: 1, b: 2) fibonacci(n: 10) }"))
            |> Result.map(response -> (response#data, firstMessage(response))))

/// variables で渡した $a がリゾルバの引数 a に届く。
@Test
def testGraphqlJavaVariables(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "add" => Value.Int(3) }), None)),
        executeOnce(testSchema(), { queryText = "query($a: Int!) { add(a: $a, b: 2) }", variables = Map#{ "a" => Value.Int(1) }, operationName = None })
            |> Result.map(response -> (response#data, firstMessage(response))))

/// 名前付きの操作が 2 つあるクエリでは、operationName で選んだ方だけが実行される。
@Test
def testGraphqlJavaOperationName(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "fibonacci" => Value.Int(55) }), None)),
        executeOnce(testSchema(), { queryText = "query First { add(a: 1, b: 2) } query Second { fibonacci(n: 10) }", variables = Map.empty(), operationName = Some("Second") })
            |> Result.map(response -> (response#data, firstMessage(response))))

// ---- エラーの報告 ----

/// スキーマに無いフィールドを問い合わせると、data は Null で、検証エラーが 1 つ返る。
@Test
def testGraphqlJavaUnknownFieldIsError(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Null, 1, Some("Validation error (FieldUndefined@[nope]) : Field 'nope' in type 'Query' is undefined"))),
        executeOnce(testSchema(), queryOnly("{ nope }"))
            |> Result.map(response -> (response#data, List.length(response#errors), firstMessage(response))))

/// リゾルバが Err を返すと、そのフィールドは null になり、Err のメッセージを含むエラーが 1 つ返る。
@Test
def testGraphqlJavaResolverErrIsReported(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "fail" => Value.Null }), 1, Some("Exception while fetching data (/fail) : boom"))),
        executeOnce(testSchema(), queryOnly("{ fail }"))
            |> Result.map(response -> (response#data, List.length(response#errors), firstMessage(response))))

// ---- エンジンの組み立て ----

/// 壊れた SDL では buildEngine が Err になる。
@Test
def testGraphqlJavaBrokenSdlIsErr(): Unit \ {Assert, IO} =
    Assert.assertTrue(Result.isErr(Graphql.buildEngine({ sdl = "type Query { add(a: Int!", resolvers = testResolvers() })))

/// スキーマに無いフィールドへリゾルバを登録すると、そのフィールド名を含む Err になる。
@Test
def testGraphqlJavaUnknownResolverIsErr(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Err(true),
        Graphql.buildEngine({ sdl = testSdl(), resolvers = Map.insert(("Query", "nope"), _ -> checked_ecast(Ok(Value.Null)), testResolvers()) })
            |> Result.map(_ -> false)
            |> Result.mapErr(String.contains(substr = "Query.nope")))

/// Query のフィールドにリゾルバが無いと、そのフィールド名を含む Err になる。
@Test
def testGraphqlJavaMissingResolverIsErr(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Err(true),
        Graphql.buildEngine({ sdl = testSdl(), resolvers = CalcResolvers.resolvers() })
            |> Result.map(_ -> false)
            |> Result.mapErr(String.contains(substr = "Query.fail")))

// ---- リゾルバのマージ ----

/// キーが重ならない一覧同士は、全部を合わせた Map になる。
@Test
def testGraphqlMergeResolversDisjoint(): Unit \ Assert =
    Assert.assertEq(expected = Ok(("Query", "add") :: ("Query", "fail") :: ("Query", "fibonacci") :: Nil),
        Graphql.mergeResolvers(CalcResolvers.resolvers() :: Map#{ ("Query", "fail") => _ -> checked_ecast(Err("boom")) } :: Nil)
            |> Result.map(merged -> Map.keysOf(merged) |> Set.toList))

/// 同じキーが 2 つの一覧にあると、そのキー名（Query.add）を含む Err になる。
@Test
def testGraphqlMergeResolversDuplicateIsErr(): Unit \ Assert =
    Assert.assertEq(expected = Err(true),
        Graphql.mergeResolvers(CalcResolvers.resolvers() :: CalcResolvers.resolvers() :: Nil)
            |> Result.map(_ -> false)
            |> Result.mapErr(String.contains(substr = "Query.add")))
