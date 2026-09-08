///
/// DbRunner: 一時的な失敗の再試行と、再試行した回数の数え方。DB は要らない（TransientDbErr を投げる thunk で回す）。
///
mod TestDbRunner {

    import java.lang.Integer
    import java.lang.NumberFormatException

    use DbError.DbErrorKind
    use DbError.DbFailure
    use DbError.Failure
    use DbError.TransientKind

    ///
    /// 最初の failures 回だけ TransientDbErr.timeout を投げ、その後は Ok を返す thunk を回して、
    /// 結果と再試行した回数（= 待った回数）を返す。
    ///
    def runFailing(failures: Int32): (Result[DbFailure, Int32], Int32) \ IO =
        let attempts = Ref.fresh(Static, 0);
        let counter = Ref.fresh(Static, 0);
        let outcome = DbRunner.retryWith(counter, () -> {
            Ref.put(Ref.get(attempts) + 1, attempts);
            if (Ref.get(attempts) <= failures) TransientDbErr.timeout(0) else Ref.get(attempts)
        });
        (outcome, Ref.get(counter))

    /// 失敗の回数ごとの、何回目で成功したかと再試行した回数。3 回目も失敗したら retryExhausted で、待つのは 2 回。
    @Test
    def testRetryCountTable(): Unit \ {Assert, IO} =
        let cases = List#{
            (0, (Ok(1), 0)),
            (1, (Ok(2), 1)),
            (2, (Ok(3), 2)),
            (3, (Err(Failure.Permanent(DbErrorKind.RetryExhausted(TransientKind.Timeout(0), 3))), 2))
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (failures, _) -> runFailing(failures)))

    // ---- リクエストの Tx（withRequestTx）の閉じる道 ----

    /// 接続を借りない（呼ばれたらテストの前提が壊れている）Handle。
    def idleHandle(): RequestTx.Handle \ IO =
        { openConnection = () -> bug!("接続を借りない"),
          state = Ref.fresh(Static, RequestTx.State.Idle),
          openedAt = Ref.fresh(Static, None),
          lastClosedAt = Ref.fresh(Static, None) }

    ///
    /// body が JVM の例外で抜けても閉じる道は通る: observe に db.transactions（0。借りていない）と db.tx.outcome（none）が戻り、
    /// 例外はそのまま呼ぶ側に届く。Log の行は無い（COMMIT していない）。
    ///
    @Test
    def testWithRequestTxClosesAfterThrow(): Unit \ {Assert, IO} =
        let observed = Ref.fresh(Static, Log.Fields.empty());
        let (thrown, records) = Log.runWithList(() -> {
            try {
                "no exception: ${DbRunner.withRequestTxHandle(idleHandle(), fields -> Ref.put(LogFields.mergeCounts(fields, Ref.get(observed)), observed), _ -> Integer.parseInt("boom"))}"
            } catch {
                case error: NumberFormatException => "caught ${error.getMessage()}"
            }
        });
        Assert.assertEq(
            expected = ("caught For input string: \"boom\"", Some(Value.Int(0)), Some(Value.Str("none")), 0),
            (thrown, Map.get("db.transactions", Ref.get(observed)), Map.get("db.tx.outcome", Ref.get(observed)), List.length(records)))

    /// Broken の後のフィールドは走らせず（openConnection を呼ばず）、最初の失敗を Skipped で返す。
    @Test
    def testTransactSharedSkipsAfterBroken(): Unit \ {Assert, IO} =
        let failure = Failure.Transient(TransientKind.ConnectionLost("gone"));
        let handle = { state = Ref.fresh(Static, RequestTx.State.Broken(None, failure)) | idleHandle() };
        let attempt = RawSql.runWithAllow(() -> DbRunner.transactShared(handle, _ -> (), Actor.System, () -> Sql.fetch("SELECT 1", Nil) |> List.length));
        Assert.assertEq(expected = Some(failure), match attempt { case RequestTx.Attempt.Skipped(found) => Some(found) case RequestTx.Attempt.Ran(_) => None })

}
