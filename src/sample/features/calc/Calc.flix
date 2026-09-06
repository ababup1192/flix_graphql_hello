///
/// 計算そのもの。GraphQL にも graphql-java にも依存しない。
///
mod Calc {

    ///
    /// 2 つの整数を足す。
    ///
    pub def add(a: Int32, b: Int32): Int32 = a + b

    ///
    /// n 番目のフィボナッチ数を返す（0 番目は 0、1 番目は 1）。負の n は 0 とみなす。
    ///
    pub def fibonacci(n: Int32): Int32 =
        def loop(i, previous, current) =
            if (i <= 0) previous else loop(i - 1, current, previous + current);
        loop(n, 0, 1)

}
