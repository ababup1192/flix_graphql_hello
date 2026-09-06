///
/// Value: 入れ子の辿り方。
///
mod TestValue {

    /// path は名前の並びで辿る。無いキー、Obj でない途中、空の並びはそれぞれ Null / Null / 自分。
    @Test
    def testValuePath(): Unit \ Assert =
        let value = Value.Obj(Map#{ "a" => Value.Obj(Map#{ "b" => Value.Int(1) }), "s" => Value.Str("x") });
        Assert.assertEq(expected = (Value.Int(1), Value.Null, Value.Null, value),
            (Value.path(List#{"a", "b"}, value), Value.path(List#{"a", "z"}, value), Value.path(List#{"s", "b"}, value), Value.path(Nil, value)))

}
