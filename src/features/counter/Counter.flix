///
/// Mutation の例。Query.counter で値を読み、Mutation.increment で増やす。
/// 保存先は CounterStore effect の向こう側にあり、ここでは触らない。
///
/// WhyNot: Flix 側で状態を持たないのは、Web サーバはプロセスをまたいで値を残す必要があり、
/// 外部の DB に置く方が素直なため。並行アクセスの直列化も保存先に任せる。
///
mod Counter {

    ///
    /// CounterStore を剥がして IO にする関数。本番は SqliteCounter.runWithSqlite、テストはメモリ上の偽ハンドラ。
    ///
    /// WhyNot: リゾルバの中でハンドラを直接呼ばずに外から受けるのは、リゾルバが graphql-java の
    /// Java コールバックの中で呼ばれて main のハンドラへ戻れないため、リゾルバを作る時点で
    /// 包む必要があり、その包み方をテストで差し替えたいため。
    ///
    pub type alias StoreRunner = (Unit -> Result[String, Int32] \ CounterStore) -> Result[String, Int32] \ IO

    ///
    /// Query.counter。今の値を返す。
    ///
    pub def counter(runStore: StoreRunner, _context: Context): Result[FieldError, Int32] \ IO =
        runStore(() -> CounterStore.load())

    ///
    /// Mutation.increment。引数 by だけ増やし、増やした後の値を返す。
    ///
    pub def increment(runStore: StoreRunner, _context: Context, by: Int32): Result[FieldError, Int32] \ IO =
        runStore(() -> CounterStore.increment(by))

}
