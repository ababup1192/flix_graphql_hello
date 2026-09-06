import java.lang.Long
import java.lang.Object
import java.util.UUID

///
/// JavaValue: Java のオブジェクトと Value の相互変換。graphql-java との境界。
///

/// Long は Int32 に収まれば Int、収まらなければ Float になる。
@Test
def testJavaValueFromLong(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = (Value.Int(7), Value.Float(4294967296.0)),
        (JavaValue.fromObject(JavaValue.asObject(Long.valueOf(7i64))), JavaValue.fromObject(JavaValue.asObject(Long.valueOf(4294967296i64)))))

/// 知らない型（UUID、素の Object）は toString した Str になる。
@Test
def testJavaValueFromUnknownTypeIsStr(): Unit \ {Assert, IO} =
    let plain = new Object();
    Assert.assertEq(expected = (Value.Str("123e4567-e89b-12d3-a456-426614174000"), Value.Str(plain.toString())),
        (JavaValue.fromObject(JavaValue.asObject(UUID.fromString("123e4567-e89b-12d3-a456-426614174000"))), JavaValue.fromObject(plain)))

/// 入れ子の Obj / List を Java の Map / List にしてから読み戻すと元の Value に戻る。
@Test
def testJavaValueRoundTrip(): Unit \ {Assert, IO} =
    let value = Value.Obj(Map#{
        "n" => Value.Int(1),
        "x" => Value.Float(2.5),
        "s" => Value.Str("日本"),
        "b" => Value.Bool(true),
        "z" => Value.Null,
        "l" => Value.List(Value.Int(1) :: Value.Obj(Map#{ "k" => Value.Str("v") }) :: Nil),
        "o" => Value.Obj(Map#{ "inner" => Value.List(Nil) }) });
    Assert.assertEq(expected = value, JavaValue.toObject(value) |> JavaValue.fromObject)
