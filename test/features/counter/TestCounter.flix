///
/// Counter: CounterStore effect だけに依存する Query / Mutation リゾルバ。
/// SQLite は使わず、メモリ上の偽ハンドラで確かめる。
///

/// increment は増やした後の値を返し、counter はその値を読む。
/// 0 → +2 → +3 の順で 2, 5 が返り、最後の読み取りも 5。
@Test
def testCounterIncrementThenLoad(): Unit \ Assert =
    Assert.assertEq(expected = (Ok(Value.Int(2)), Ok(Value.Int(5)), Ok(Value.Int(5))),
        CounterFake.runWithMemory(0, () -> (
            Counter.incrementResolver(Map#{ "by" => Value.Int(2) }),
            Counter.incrementResolver(Map#{ "by" => Value.Int(3) }),
            Counter.counterResolver(Map#{}))))

/// by が無いか Int でなければ Err で、保存先には触らないので値は変わらない。
@Test
def testCounterIncrementBadArg(): Unit \ Assert =
    Assert.assertEq(expected = (Err("argument 'by' must be Int"), Ok(Value.Int(7))),
        CounterFake.runWithMemory(7, () -> (
            Counter.incrementResolver(Map#{ "by" => Value.Str("x") }),
            Counter.counterResolver(Map#{}))))

/// 保存先の Err はそのままリゾルバの Err になる。
@Test
def testCounterStoreErrorPassesThrough(): Unit \ Assert =
    Assert.assertEq(expected = (Err("db down"), Err("db down")),
        CounterFake.runWithBroken("db down", () -> (
            Counter.counterResolver(Map#{}),
            Counter.incrementResolver(Map#{ "by" => Value.Int(1) }))))
