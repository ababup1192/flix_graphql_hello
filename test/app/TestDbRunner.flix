///
/// DbRunner: 一時的な失敗の再試行と、再試行した回数の数え方、待ち（backoff）の上限と jitter の範囲、Tx の結果の ApplicationFailure への写し、
/// observe に積む db.* のキー。DB は要らない（TransientDbErr を投げる thunk と、接続を借りない Handle で回す）。
///
mod TestDbRunner {

    import java.lang.Integer
    import java.lang.NumberFormatException

    use CmsErr.CmsFailure
    use DbError.DbErrorKind
    use DbError.DbFailure
    use DbError.Failure
    use DbError.TransientKind

    // ---- 再試行の方針（retryPolicy）----

    /// 3 回、200 ms から、2 秒で頭打ち。attempts を増やすと DB が落ちている時の 1 リクエストが 7〜8 秒を超える。
    @Test
    def testRetryPolicy(): Unit \ Assert =
        Assert.assertEq(expected = (3, 200, 2000), (DbRunner.retryPolicy()#attempts, DbRunner.retryPolicy()#baseMs, DbRunner.retryPolicy()#maxMs))

    ///
    /// 失敗の回数ごとの待ちの上限（jitter = 1.0）: 200 → 400 → 800 → 1600 → 2000 で頭打ち。
    /// 実際に待つのは attempts = 3 なので 1 回目と 2 回目の失敗の後だけ（上限の合計 600 ms）。
    ///
    @Test
    def testBackoffCapTable(): Unit \ Assert =
        let cases = List#{ (1, 200), (2, 400), (3, 800), (4, 1600), (5, 2000), (6, 2000) };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (attempt, _) -> Retry.backoffMs(DbRunner.retryPolicy(), attempt, 1.0)))

    ///
    /// jitter は full jitter: 上限に 0.0〜1.0 を掛ける（0.0 なら待たない、0.5 なら半分）。範囲の外は 0.0〜1.0 に丸める。
    ///
    @Test
    def testBackoffJitterTable(): Unit \ Assert =
        let cases = List#{ (0.0, 0), (0.5, 200), (1.0, 400), (-1.0, 0), (2.0, 400) };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (jitter, _) -> Retry.backoffMs(DbRunner.retryPolicy(), 2, jitter)))

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
          openedAt = Ref.fresh(Static, None) }

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

    // ---- Tx の結果の写し（toApplicationResult。transactShared 越し）と observe に積む db.* のキー ----

    /// SQL を出さない thunk を 1 フィールドぶん走らせ、走った結果（Ran の中身）と observe に積まれた属性を返す。接続は借りない。
    def runField(thunk: Unit -> Int32 \ {CmsErr, DbErr}): (Result[ApplicationFailure, Int32], Log.Fields) \ IO =
        let observed = Ref.fresh(Static, Log.Fields.empty());
        let attempt = DbRunner.transactShared(idleHandle(), fields -> Ref.put(LogFields.mergeCounts(fields, Ref.get(observed)), observed), Actor.System, thunk);
        let outcome = match attempt {
            case RequestTx.Attempt.Ran(found) => found
            case RequestTx.Attempt.Skipped(_) => bug!("Idle の Handle は走る")
        };
        (outcome, Ref.get(observed))

    ///
    /// Tx の結果の 3 腕: DB の失敗（DbErr）は Infrastructure、業務エラー（CmsErr）は ROLLBACK の上で Domain、成功はそのまま。
    ///
    @Test
    def testToApplicationResultTable(): Unit \ {Assert, IO} =
        let cases: List[(Unit -> Int32 \ {CmsErr, DbErr}, Result[ApplicationFailure, Int32])] = List#{
            (() -> DbErr.raise(DbErrorKind.Other("boom")),      Err(ApplicationFailure.Infrastructure(Failure.Permanent(DbErrorKind.Other("boom"))))),
            (() -> CmsErr.notFound(Entity.Entry, "e1"),         Err(ApplicationFailure.Domain(CmsFailure.NotFound(Entity.Entry, "e1")))),
            (() -> 42,                                          Ok(42))
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (thunk, _) -> runField(thunk) |> fst))

    ///
    /// 1 フィールドが observe に積むのは db.statements の 1 キーだけ（Tx の数は閉じる時に 1 回）。SQL を出さなければ 0。
    /// 同じリクエストの 2 フィールドを LogFields.mergeCounts で合わせても、キーは増えず数は和になる。
    ///
    @Test
    def testTransactSharedObservesStatementsOnly(): Unit \ {Assert, IO} =
        let observed = Ref.fresh(Static, Log.Fields.empty());
        let observe = fields -> Ref.put(LogFields.mergeCounts(fields, Ref.get(observed)), observed);
        discard DbRunner.transactShared(idleHandle(), observe, Actor.System, () -> 1);
        discard DbRunner.transactShared(idleHandle(), observe, Actor.System, () -> 2);
        Assert.assertEq(expected = List#{ ("db.statements", Value.Int(0)) }, Map.toList(Ref.get(observed)))

    ///
    /// Infrastructure の失敗は Error の行の error.code が INTERNAL で、extensions.requestId にリクエストの id が付く（問い合わせとログを繋ぐ）。
    /// Domain と成功では行は出ない（3 腕の行の有無は TestGraphqlErrors.testToFieldResultLogsOnlyDbFailure）。
    ///
    @Test
    def testToFieldResultInternalCarriesRequestId(): Unit \ Assert =
        let outcome: Result[ApplicationFailure, Result[FieldError, Int32]] = Err(ApplicationFailure.Infrastructure(Failure.Permanent(DbErrorKind.Other("boom"))));
        let (result, lines) = Log.runWithList(() -> DbRunner.toFieldResult(Some("rid"), outcome));
        Assert.assertEq(
            expected = (Err(Map#{ "code" => Value.Str("INTERNAL"), "requestId" => Value.Str("rid") }), List#{ Some(Value.Str("INTERNAL")) }),
            (result |> Result.mapErr(FieldError.extensions), lines |> List.map(line -> Map.get("error.code", line#fields))))

}
