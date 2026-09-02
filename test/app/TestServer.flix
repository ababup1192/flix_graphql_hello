///
/// Server: HTTP リクエストを Graphql effect に橋渡しするルーティング。
/// エンジンは使わず、GraphqlFake の偽ハンドラで確かめる。ボディは Value に読み戻して比べる。
///

///
/// POST /graphql に JSON ボディを載せたリクエスト。
///
def postGraphql(body: String): HttpRequest =
    { method = "POST", path = "/graphql", headers = Nil, body = body }

///
/// runWithEcho が data に入れて返す形。variables が無いリクエストは空の Obj、operationName が無ければ Null。
///
def echoed(queryText: String): Value =
    Value.Obj(Map#{ "query" => Value.Str(queryText), "variables" => Value.Obj(Map.empty()), "operationName" => Value.Null })

// ---- POST /graphql の正常系 ----

/// POST /graphql は JSON ボディの query を取り出して実行し、data を JSON で返す。
@Test
def testServerPostGraphql(): Unit \ Assert =
    let response = GraphqlFake.runWithEcho(() -> Server.handle(postGraphql("{\"query\": \"{ add(a: 1, b: 2) }\"}")));
    Assert.assertEq(
        expected = (200, Ok(Value.Obj(Map#{ "data" => echoed("{ add(a: 1, b: 2) }") }))),
        (response#status, JsonValue.parse(response#body)))

/// ボディの variables と operationName はそのまま Graphql effect に渡る。
@Test
def testServerVariablesAndOperationNamePassThrough(): Unit \ Assert =
    let expectedData = Value.Obj(Map#{
        "query"         => Value.Str("query Q($a: Int!) { add(a: $a, b: 2) }"),
        "variables"     => Value.Obj(Map#{ "a" => Value.Int(1), "tag" => Value.Str("x") }),
        "operationName" => Value.Str("Q") });
    Assert.assertEq(
        expected = Ok(Value.Obj(Map#{ "data" => expectedData })),
        GraphqlFake.runWithEcho(() -> Server.handle(postGraphql(
            "{\"query\": \"query Q($a: Int!) { add(a: $a, b: 2) }\", \"variables\": {\"a\": 1, \"tag\": \"x\"}, \"operationName\": \"Q\"}")))#body
            |> JsonValue.parse)

/// 実行結果に errors があれば errors としてそのまま返す。
@Test
def testServerErrors(): Unit \ Assert =
    let error = Value.Obj(Map#{ "message" => Value.Str("boom") });
    Assert.assertEq(
        expected = Ok(Value.Obj(Map#{ "data" => Value.Null, "errors" => Value.List(error :: Nil) })),
        GraphqlFake.runWithFixedResponse({ data = Value.Null, errors = error :: Nil },
            () -> Server.handle(postGraphql("{\"query\": \"{ x }\"}")))#body |> JsonValue.parse)

/// エラーオブジェクトの message 以外のフィールド（path など）も削らずにボディへ通す。
@Test
def testServerErrorPathPassesThrough(): Unit \ Assert =
    let error = Value.Obj(Map#{ "message" => Value.Str("boom"), "path" => Value.List(Value.Str("x") :: Nil) });
    Assert.assertEq(
        expected = Ok(Value.Obj(Map#{ "data" => Value.Null, "errors" => Value.List(error :: Nil) })),
        GraphqlFake.runWithFixedResponse({ data = Value.Null, errors = error :: Nil },
            () -> Server.handle(postGraphql("{\"query\": \"{ x }\"}")))#body |> JsonValue.parse)

/// errors が空なら errors キー自体を出さない。
@Test
def testServerNoErrorsKey(): Unit \ Assert =
    Assert.assertEq(
        expected = Ok(Value.Obj(Map#{ "data" => Value.Int(1) })),
        GraphqlFake.runWithFixedResponse({ data = Value.Int(1), errors = Nil },
            () -> Server.handle(postGraphql("{\"query\": \"{ x }\"}")))#body |> JsonValue.parse)

// ---- ボディの検証 ----

/// 壊れた JSON は 400。query が無いのも 400。
@Test
def testServerBadBody(): Unit \ Assert =
    Assert.assertEq(expected = (400, 400),
        GraphqlFake.runWithEcho(() -> (
            Server.handle(postGraphql("{"))#status,
            Server.handle(postGraphql("{\"q\": 1}"))#status)))

/// variables がオブジェクトでなければ 400。
@Test
def testServerVariablesNotObject(): Unit \ Assert =
    Assert.assertEq(expected = 400,
        GraphqlFake.runWithEcho(() -> Server.handle(postGraphql("{\"query\": \"{ x }\", \"variables\": [1]}"))#status))

// ---- ルーティング ----

/// /graphql への GET は 405、それ以外のパスは 404。
@Test
def testServerRouting(): Unit \ Assert =
    Assert.assertEq(expected = (405, 404),
        GraphqlFake.runWithEcho(() -> (
            Server.handle({ method = "GET", path = "/graphql", headers = Nil, body = "" })#status,
            Server.handle({ method = "POST", path = "/", headers = Nil, body = "" })#status)))

/// 405 のレスポンスは Allow: POST ヘッダを持つ。
@Test
def testServerMethodNotAllowedHasAllowHeader(): Unit \ Assert =
    Assert.assertEq(expected = ("Allow", "POST") :: Nil,
        GraphqlFake.runWithEcho(() -> Server.handle({ method = "GET", path = "/graphql", headers = Nil, body = "" }))#headers)

/// ルーティングのエラーも errors[].message の形の JSON ボディで返す。
@Test
def testServerErrorBodyShape(): Unit \ Assert =
    Assert.assertEq(
        expected = Ok(Value.Obj(Map#{ "data" => Value.Null, "errors" => Value.List(Value.Obj(Map#{ "message" => Value.Str("not found") }) :: Nil) })),
        GraphqlFake.runWithEcho(() -> Server.handle({ method = "POST", path = "/", headers = Nil, body = "" }))#body |> JsonValue.parse)
