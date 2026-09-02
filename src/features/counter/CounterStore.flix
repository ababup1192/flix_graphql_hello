///
/// カウンタの保存先を表す effect。値をどこに置くか（SQLite・メモリなど）はハンドラが決める。
/// リゾルバはこの effect だけに依存し、JDBC を知らない。
///
pub eff CounterStore {
    ///
    /// 今の値を読む。
    ///
    def load(): Result[String, Int32]

    ///
    /// 値を by だけ増やし、増やした後の値を返す。
    ///
    def increment(by: Int32): Result[String, Int32]
}
