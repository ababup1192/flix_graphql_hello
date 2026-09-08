///
/// DbConfig: JDBC の URL に DB 側の時間の上限（pgjdbc の options）を付ける所と、CMS_DB_TIMEOUT_SECONDS の読み方。
///
mod TestDbConfig {

    /// 30 秒の 3 つの上限を options に並べた形。
    def options30(): String =
        "options=-c%20idle_in_transaction_session_timeout=30s%20-c%20statement_timeout=30s%20-c%20lock_timeout=30s"

    /// `?` が無ければ `?options=`、既に `?` があれば `&options=`。0 以下なら付けず、DSN に options があればそのまま。
    @Test
    def testWithTimeoutsTable(): Unit \ Assert =
        let table = List#{
            ((30, "jdbc:postgresql://h:5432/cms"),                       "jdbc:postgresql://h:5432/cms?${options30()}"),
            ((30, "jdbc:postgresql://h/cms?ssl=true"),                   "jdbc:postgresql://h/cms?ssl=true&${options30()}"),
            ((0,  "jdbc:postgresql://h/cms"),                            "jdbc:postgresql://h/cms"),
            ((-1, "jdbc:postgresql://h/cms"),                            "jdbc:postgresql://h/cms"),
            ((5,  "jdbc:postgresql://h/cms?options=-c%20foo=bar"),       "jdbc:postgresql://h/cms?options=-c%20foo=bar")
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match ((seconds, url), _) -> DbConfig.withTimeouts(seconds, url)))

    /// 無い・数字でない・負なら既定の 30。0 は 0（無効）。
    @Test
    def testTimeoutSecondsTable(): Unit \ Assert =
        let table = List#{ (None, 30), (Some("10"), 10), (Some("abc"), 30), (Some("-3"), 30), (Some("0"), 0) };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (raw, _) -> DbConfig.timeoutSeconds(raw)))

    /// 無い・数字でない・負なら 0（漏れの検出は無効）。
    @Test
    def testLeakDetectionSecondsTable(): Unit \ Assert =
        let table = List#{ (None, 0), (Some("60"), 60), (Some("abc"), 0), (Some("-3"), 0), (Some("0"), 0) };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (raw, _) -> DbConfig.leakDetectionSeconds(raw)))

    /// 無い・数字でない・1 未満なら sqlfx の既定（ここでは 10）。
    @Test
    def testMaxConnectionsTable(): Unit \ Assert =
        let table = List#{ (None, 10), (Some("40"), 40), (Some("1"), 1), (Some("abc"), 10), (Some("0"), 10), (Some("-3"), 10) };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (raw, _) -> DbConfig.maxConnections(10, raw)))

    /// 無い・数字でない・1 未満なら既定の 2 秒。
    @Test
    def testBorrowTimeoutSecondsTable(): Unit \ Assert =
        let table = List#{ (None, 2), (Some("5"), 5), (Some("1"), 1), (Some("abc"), 2), (Some("0"), 2), (Some("-3"), 2) };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (raw, _) -> DbConfig.borrowTimeoutSeconds(raw)))

}
