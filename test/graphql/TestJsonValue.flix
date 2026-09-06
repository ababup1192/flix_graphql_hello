///
/// JsonValue: Value と JSON 文字列の相互変換。
///

/// JSON 文字列を Value に読む。整数は Int、小数は Float。
@Test
def testJsonValueParse(): Unit \ Assert =
    Assert.assertEq(
        expected = Ok(Value.Obj(Map#{ "a" => Value.Int(1), "b" => Value.Float(1.5), "c" => Value.List(Value.Str("x") :: Value.Null :: Value.Bool(true) :: Nil) })),
        JsonValue.parse("{\"a\": 1, \"b\": 1.5, \"c\": [\"x\", null, true]}"))

/// Value を JSON 文字列にする。キーは並び替えられる。
@Test
def testJsonValueToJsonString(): Unit \ Assert =
    Assert.assertEq(expected = "{\"a\":1,\"b\":[true,null],\"c\":\"x\"}",
        JsonValue.toJsonString(Value.Obj(Map#{ "c" => Value.Str("x"), "a" => Value.Int(1), "b" => Value.List(Value.Bool(true) :: Value.Null :: Nil) })))

/// JSON 文字列にしてから読み戻すと元の Value に戻る。
@Test
def testJsonValueRoundTrip(): Unit \ Assert =
    let value = Value.Obj(Map#{ "n" => Value.Int(-3), "x" => Value.Float(2.5), "s" => Value.Str("日本"), "l" => Value.List(Value.Null :: Value.Bool(false) :: Nil), "o" => Value.Obj(Map#{}) });
    Assert.assertEq(expected = Ok(value), JsonValue.toJsonString(value) |> JsonValue.parse)

/// 壊れた JSON は Err。
@Test
def testJsonValueParseBroken(): Unit \ Assert =
    Assert.assertTrue(JsonValue.parse("{") |> Result.isErr)

/// 小数点付きの 10.0 は Float のまま往復し、10 は Int になる（scalar JSON は入れた物をそのまま返す）。
@Test
def testJsonValueKeepsFloatWithPoint(): Unit \ Assert =
    Assert.assertEq(expected = (Ok(Value.Float(10.0)), Ok(Value.Int(10))),
        (JsonValue.parse("10.0"), JsonValue.parse("10")))
