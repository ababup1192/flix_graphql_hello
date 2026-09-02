///
/// Counter: CounterStore effect だけに依存する Query / Mutation のリゾルバ。
/// SQLite は使わず、メモリ上の偽ハンドラを runStore として渡す。
///

/// counter は保存先の値を読む。
@Test
def testCounterQuery(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(5),
        Counter.counter(f -> CounterFake.runWithMemory(5, f), Context.anonymous()))

/// increment は by だけ増やした後の値を返す（初期値 5 に 3 を足して 8）。
@Test
def testCounterIncrement(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = Ok(8),
        Counter.increment(f -> CounterFake.runWithMemory(5, f), Context.anonymous(), 3))

/// 保存先の Err はそのままリゾルバの Err になる。
@Test
def testCounterStoreErrorPassesThrough(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = (Err("db down"), Err("db down")),
        (Counter.counter(f -> CounterFake.runWithBroken("db down", f), Context.anonymous()),
         Counter.increment(f -> CounterFake.runWithBroken("db down", f), Context.anonymous(), 1)))

/// アプリのスキーマ経由でも counter と increment が動き、保存先の Err は GraphQL のエラーになる。
@Test
def testCounterThroughSchema(): Unit \ {Assert, IO} =
    Assert.assertEq(expected = (Ok((Value.Obj(Map#{ "counter" => Value.Int(5) }), None)), Ok((Value.Obj(Map#{ "increment" => Value.Int(8) }), None))),
        (GraphqlTestKit.executeQuery(GraphqlTestKit.appSchema(5), "{ counter }"),
         GraphqlTestKit.executeQuery(GraphqlTestKit.appSchema(5), "mutation { increment(by: 3) }")))
