///
/// Mutation の例。Query.counter で値を読み、Mutation.increment で増やす。
/// 保存先は CounterStore effect の向こう側にあり、ここでは触らない。
///
/// WhyNot: Flix 側で状態を持たないのは、Web サーバはプロセスをまたいで値を残す必要があり、
/// 外部の DB に置く方が素直なため。並行アクセスの直列化も保存先に任せる。
///
mod Counter {

    ///
    /// Query.counter のリゾルバ。今の値を返す。
    ///
    pub def counterResolver(_args: Args): Result[String, Value] \ CounterStore =
        CounterStore.load() |> Result.map(Value.Int)

    ///
    /// Mutation.increment のリゾルバ。引数 by だけ増やし、増やした後の値を返す。
    ///
    pub def incrementResolver(args: Args): Result[String, Value] \ CounterStore =
        forM (
            by    <- CalcResolvers.intArg("by", args);
            value <- CounterStore.increment(by)
        ) yield Value.Int(value)

    ///
    /// カウンタのリゾルバ一覧。Query.counter と Mutation.increment。
    /// CounterStore は SQLite のハンドラで剥がして、Resolver の型（IO）に合わせる。
    ///
    /// WhyNot: ハンドラを main で噛ませないのは、リゾルバが graphql-java の Java コールバックの
    /// 中で呼ばれ、外側のハンドラへは戻れないため。リゾルバを登録する時点で
    /// 1 つずつハンドラで包み、effect の発行と処理をコールバックの内側で完結させる。
    ///
    pub def resolvers(database: SqliteCounter.Database): Map[(String, String), Resolver] =
        Map#{
            ("Query", "counter")      => args -> SqliteCounter.runWithSqlite(database, () -> counterResolver(args)),
            ("Mutation", "increment") => args -> SqliteCounter.runWithSqlite(database, () -> incrementResolver(args))
        }

}
