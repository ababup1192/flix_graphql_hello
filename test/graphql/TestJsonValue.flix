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

/// 小数は書いた桁で出る。2 進の展開（0.8 → 0.800000000000000044…）を JSON に出さない。
@Test
def testJsonValueFloatKeepsDecimalDigits(): Unit \ Assert =
    let table = List#{ (0.8, "0.8"), (0.1, "0.1"), (0.3, "0.3"), (0.72, "0.72"), (1.0, "1.0"), (0.0, "0.0"), (-0.25, "-0.25") };
    Assert.assertEq(
        expected = table |> List.map(snd),
        table |> List.map(match (x, _) -> JsonValue.toJsonString(Value.Float(x))))

/// NaN と無限は JSON の数に無いので null。
@Test
def testJsonValueFloatWithoutJsonNumber(): Unit \ Assert =
    let table = List#{ Float64.nan(), Float64.positiveInfinity(), Float64.negativeInfinity() };
    Assert.assertEq(
        expected = table |> List.map(_ -> "null"),
        table |> List.map(x -> JsonValue.toJsonString(Value.Float(x))))

/// 壊れた JSON は Err。
@Test
def testJsonValueParseBroken(): Unit \ Assert =
    Assert.assertTrue(JsonValue.parse("{") |> Result.isErr)

/// 小数点付きの 10.0 は Float のまま往復し、10 は Int になる（scalar JSON は入れた物をそのまま返す）。
@Test
def testJsonValueKeepsFloatWithPoint(): Unit \ Assert =
    Assert.assertEq(expected = (Ok(Value.Float(10.0)), Ok(Value.Int(10))),
        (JsonValue.parse("10.0"), JsonValue.parse("10")))
