///
/// Calc の計算を GraphQL のリゾルバに包む。graphql-java には依存しない。
///
mod CalcResolvers {

    ///
    /// Query.add のリゾルバ。引数 a, b が無いか Int でなければ Err。
    ///
    pub def addResolver(args: Args): Result[String, Value] =
        forM (
            a <- intArg("a", args);
            b <- intArg("b", args)
        ) yield Value.Int(Calc.add(a, b))

    ///
    /// Query.fibonacci のリゾルバ。引数 n が無いか Int でなければ Err。
    ///
    pub def fibonacciResolver(args: Args): Result[String, Value] =
        intArg("n", args) |> Result.map(n -> Value.Int(Calc.fibonacci(n)))

    ///
    /// Query 型のリゾルバ一覧。
    ///
    /// WhyNot: 関数をそのまま並べないのは、Flix では純粋な関数値を effect 付きの
    /// 関数型（Resolver）へ暗黙に広げられないため。checked_ecast で明示的に広げる。
    ///
    pub def resolvers(): Map[(String, String), Resolver] =
        Map#{
            ("Query", "add")       => args -> checked_ecast(addResolver(args)),
            ("Query", "fibonacci") => args -> checked_ecast(fibonacciResolver(args))
        }

    ///
    /// Int の引数を取り出す。無いか Int でなければ Err。
    ///
    pub def intArg(name: String, args: Args): Result[String, Int32] =
        Map.get(name, args) |> Option.flatMap(Value.asInt) |> Option.toOk("argument '${name}' must be Int")

}
