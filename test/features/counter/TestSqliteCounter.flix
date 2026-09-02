import java.io.File

///
/// SqliteCounter: CounterStore effect を SQLite で処理するハンドラ。
/// graphql-java は使わず、一時ファイルの SQLite で確かめる。
///

///
/// テスト用の空のデータベースの一時ファイルを作り、そのパスを返す。
///
def tempDatabasePath(): String \ IO =
    let file = File.createTempFile("counter-test", ".db");
    file.deleteOnExit();
    file.getAbsolutePath()

/// 開いた直後の値は 0。
@Test
def testSqliteCounterStartsAtZero(): Unit \ {IO, Assert} =
    Assert.assertEq(expected = Ok(Ok(0)),
        SqliteCounter.open(tempDatabasePath())
            |> Result.map(database -> SqliteCounter.runWithSqlite(database, () -> CounterStore.load())))

/// increment は増やした後の値を返し、load はその値を読む。0 → +2 → +3 で 2, 5, 5。
@Test
def testSqliteCounterIncrementThenLoad(): Unit \ {IO, Assert} =
    Assert.assertEq(expected = Ok((Ok(2), Ok(5), Ok(5))),
        SqliteCounter.open(tempDatabasePath())
            |> Result.map(database -> SqliteCounter.runWithSqlite(database, () ->
                (CounterStore.increment(2), CounterStore.increment(3), CounterStore.load()))))

/// 同じファイルを開き直しても値が残る。
@Test
def testSqliteCounterPersistsAcrossOpen(): Unit \ {IO, Assert} =
    let path = tempDatabasePath();
    let results = forM (
        first  <- SqliteCounter.open(path);
        _      <- SqliteCounter.runWithSqlite(first, () -> CounterStore.increment(4));
        second <- SqliteCounter.open(path);
        now    <- SqliteCounter.runWithSqlite(second, () -> CounterStore.load())
    ) yield now;
    Assert.assertEq(expected = Ok(4), results)

/// 存在しないディレクトリのパスは open が Err。
@Test
def testSqliteCounterOpenBadPathIsErr(): Unit \ {IO, Assert} =
    Assert.assertTrue(SqliteCounter.open("/nonexistent-dir-for-test/counter.db") |> Result.isErr)

/// resolvers は Query.counter と Mutation.increment の 2 つを登録している。
@Test
def testSqliteCounterResolverKeys(): Unit \ {IO, Assert} =
    Assert.assertEq(expected = Ok(("Mutation", "increment") :: ("Query", "counter") :: Nil),
        SqliteCounter.open(tempDatabasePath())
            |> Result.map(database -> Map.keysOf(Counter.resolvers(database)) |> Set.toList))
