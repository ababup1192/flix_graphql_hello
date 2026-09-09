///
/// JobLog: バックグラウンドの仕事 1 件の行に付ける属性。再試行の回数と、次に試すまでの秒数。
///
mod TestJobLog {

    use Log.Fields

    ///
    /// 再試行する仕事の属性。何回目か（job.attempts）は必ず、次に試すまでの秒数（job.retry_delay_seconds）は
    /// まだ試すときだけ。諦めた（もう試さない）ときは秒数を付けない。
    ///
    @Test
    def testRetryFieldsTable(): Unit \ Assert =
        let cases = List#{
            // 1 回目の失敗。次は 60 秒後
            ({ attempts = 1, delaySeconds = Some(60i64) },
             List#{("job.attempts", Value.Int(1)), ("job.retry_delay_seconds", Value.Int(60))}),
            // 4 回目の失敗。次は 2 時間後
            ({ attempts = 4, delaySeconds = Some(7200i64) },
             List#{("job.attempts", Value.Int(4)), ("job.retry_delay_seconds", Value.Int(7200))}),
            // 5 回目で諦める。秒数は付かない
            ({ attempts = 5, delaySeconds = None },
             List#{("job.attempts", Value.Int(5))})
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (retry, _) -> Fields.empty() |> JobLog.retryFields(retry) |> Map.toList))

}
