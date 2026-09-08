///
/// DbRunner: 一時的な失敗の再試行と、再試行した回数の数え方。DB は要らない（TransientDbErr を投げる thunk で回す）。
///
mod TestDbRunner {

    use DbError.DbFailure

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
            (3, (Err(DbFailure.Permanent("retryExhausted timeout 0 after 3 attempts")), 2))
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (failures, _) -> runFailing(failures)))

}
