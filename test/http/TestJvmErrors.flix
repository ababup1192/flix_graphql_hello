///
/// JvmErrors: どの Throwable を飲み込んでよいか（isFatal）と、ログの文言（describe）。
///
mod TestJvmErrors {

    import java.lang.OutOfMemoryError
    import java.lang.RuntimeException
    import java.lang.StackOverflowError
    import java.lang.Throwable
    import java.lang.VerifyError

    /// Exception も、VerifyError / StackOverflowError も飲み込んでよい。OutOfMemoryError だけ fatal。
    @Test
    def testIsFatalTable(): Unit \ {Assert, IO} =
        let table: List[(Throwable, Bool)] = List#{
            (checked_cast(new RuntimeException("x")), false),
            (checked_cast(new VerifyError("boom")),   false),
            (checked_cast(new StackOverflowError()),  false),
            (checked_cast(new OutOfMemoryError()),    true)
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (error, _) -> JvmErrors.isFatal(error)))

    /// message があればそれ、null ならクラス名。
    @Test
    def testDescribeTable(): Unit \ {Assert, IO} =
        let table: List[(Throwable, String)] = List#{
            (checked_cast(new RuntimeException("x")), "x"),
            (checked_cast(new VerifyError("boom")),   "boom"),
            (checked_cast(new VerifyError()),         "java.lang.VerifyError")
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (error, _) -> JvmErrors.describe(error)))

}
