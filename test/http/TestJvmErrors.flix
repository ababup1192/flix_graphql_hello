///
/// JvmErrors: どの Throwable を飲み込んでよいか（isFatal）と、ログの文言（describe）。
///
mod TestJvmErrors {

    import java.lang.OutOfMemoryError
    import java.lang.RuntimeException
    import java.lang.StackOverflowError
    import java.lang.Throwable
    import java.lang.VerifyError
    import java.util.concurrent.CompletionException
    import java.util.concurrent.ExecutionException

    /// OutOfMemoryError を cause に持つ物。
    def wrapping(cause: Throwable): Throwable \ IO =
        checked_cast(new CompletionException(cause))

    ///
    /// Exception も、VerifyError / StackOverflowError も飲み込んでよい。OutOfMemoryError だけ fatal。
    /// graphql-java が包む CompletionException のように cause の連鎖の中にあっても fatal（2 段でも）。包みの中が StackOverflowError なら fatal ではない。
    ///
    @Test
    def testIsFatalTable(): Unit \ {Assert, IO} =
        let oom: Throwable = checked_cast(new OutOfMemoryError("unable to create native thread"));
        let table: List[(Throwable, Bool)] = List#{
            (checked_cast(new RuntimeException("x")),                          false),
            (checked_cast(new VerifyError("boom")),                            false),
            (checked_cast(new StackOverflowError()),                           false),
            (oom,                                                              true),
            (wrapping(oom),                                                    true),
            (wrapping(wrapping(oom)),                                          true),
            (wrapping(checked_cast(new RuntimeException("x"))),                false),
            (wrapping(checked_cast(new StackOverflowError())),                 false)
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (error, _) -> JvmErrors.isFatal(error)))

    /// message があればそれ、null ならクラス名。CompletionException の包みは剥がして中の例外の message。
    @Test
    def testDescribeTable(): Unit \ {Assert, IO} =
        let table: List[(Throwable, String)] = List#{
            (checked_cast(new RuntimeException("x")), "x"),
            (checked_cast(new VerifyError("boom")),   "boom"),
            (checked_cast(new VerifyError()),         "java.lang.VerifyError"),
            (wrapping(checked_cast(new VerifyError("boom"))), "boom")
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (error, _) -> JvmErrors.describe(error)))

    ///
    /// 包みを剥がす: CompletionException / ExecutionException は cause（2 段でも）、それ以外はそのまま。
    ///
    @Test
    def testUnwrapTable(): Unit \ {Assert, IO} =
        let plain: Throwable = checked_cast(new RuntimeException("x"));
        let table: List[(Throwable, String)] = List#{
            (plain,                                                                  "java.lang.RuntimeException"),
            (wrapping(plain),                                                        "java.lang.RuntimeException"),
            (wrapping(wrapping(plain)),                                              "java.lang.RuntimeException"),
            (checked_cast(new ExecutionException(plain)),                            "java.lang.RuntimeException"),
            (wrapping(checked_cast(new OutOfMemoryError("unable to create native thread"))), "java.lang.OutOfMemoryError")
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (error, _) -> className(JvmErrors.unwrap(error))))

    /// クラス名。
    def className(error: Throwable): String \ IO =
        error.getClass().getName()

}
