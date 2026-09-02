///
/// Mutation の例。Query.counter で値を読み、Mutation.increment で増やす。
/// 保存先は CounterStore effect の向こう側にあり、ここでは触らない。
///
/// WhyNot: Flix 側で状態を持たないのは、Web サーバはプロセスをまたいで値を残す必要があり、
/// 外部の DB に置く方が素直なため。並行アクセスの直列化も保存先に任せる。
///
mod Counter {

    ///
    /// Query.counter。今の値を返す。
    ///
    pub def counter(_context: Context): Result[FieldError, Int32] \ CounterStore =
        CounterStore.load()

    ///
    /// Mutation.increment。引数 by だけ増やし、増やした後の値を返す。
    ///
    pub def increment(_context: Context, by: Int32): Result[FieldError, Int32] \ CounterStore =
        CounterStore.increment(by)

}
