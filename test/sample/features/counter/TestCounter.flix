///
/// Counter: CounterStore effect だけに依存する Query / Mutation のリゾルバ。
/// SQLite は使わず、メモリ上の偽ハンドラで動かす。
///

/// counter は保存先の値を読む。
@Test
def testCounterQuery(): Unit \ Assert =
    Assert.assertEq(expected = Ok(5),
        CounterFake.runWithMemory(5, () -> Counter.counter(Context.anonymous())))

/// increment は by だけ増やした後の値を返す（初期値 5 に 3 を足して 8）。
@Test
def testCounterIncrement(): Unit \ Assert =
    Assert.assertEq(expected = Ok(8),
        CounterFake.runWithMemory(5, () -> Counter.increment(Context.anonymous(), 3)))

/// 保存先の Err はそのままリゾルバの Err になる。
@Test
def testCounterStoreErrorPassesThrough(): Unit \ Assert =
    Assert.assertEq(expected = (Err(FieldError.internal("db down")), Err(FieldError.internal("db down"))),
        (CounterFake.runWithBroken("db down", () -> Counter.counter(Context.anonymous())),
         CounterFake.runWithBroken("db down", () -> Counter.increment(Context.anonymous(), 1))))

/// 1 つのクエリの中で increment を 2 回呼ぶと、2 回目は 1 回目の結果の上に積まれる（fetch ごとに保存先が分かれない）。
@Test
def testCounterSharedWithinQuery(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok((Value.Obj(Map#{ "a" => Value.Int(6), "b" => Value.Int(7) }), None)),
        GraphqlTestKit.executeQuery(GraphqlTestKit.appSchema(5), "mutation { a: increment(by: 1) b: increment(by: 1) }"))

/// アプリのスキーマ経由でも counter と increment が動き、保存先の Err は GraphQL のエラーになる。
@Test
def testCounterThroughSchema(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = (Ok((Value.Obj(Map#{ "counter" => Value.Int(5) }), None)), Ok((Value.Obj(Map#{ "increment" => Value.Int(8) }), None))),
        (GraphqlTestKit.executeQuery(GraphqlTestKit.appSchema(5), "{ counter }"),
         GraphqlTestKit.executeQuery(GraphqlTestKit.appSchema(5), "mutation { increment(by: 3) }")))
