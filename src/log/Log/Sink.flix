///
/// Sink の合成。全部 def で作る。
///
/// WhyNot: lambda literal を let に置いて spawn の内外で使わないのは、effect の推論で落ちるため。
///
mod Log.Sink {
    use Log.Severity

    /// 1 行 JSON を out に渡す。時刻は clock で行ごとに取る。
    pub def json(clock: Unit -> Int64 \ IO, out: String -> Unit \ IO): Log.Sink =
        record -> out(Log.toJsonLine(clock(), record))

    /// min より軽い行を捨てる（min は残す）。
    pub def minSeverity(min: Severity, next: Log.Sink): Log.Sink =
        record -> if (Order.greaterEqual(record#severity, min)) next(record) else ()

    /// 全行に fields を足す（service / version）。行と span の fields が勝つ。
    pub def enrich(fields: Log.Fields, next: Log.Sink): Log.Sink =
        record -> next({ severity = record#severity, message = record#message, fields = Map.union(record#fields, fields) })

    /// 何も出さない。テストの Deps など、出力先の要らない所に。
    pub def silent(): Log.Sink =
        _ -> ()

    /// テスト用。行を Ref に積む（新しい物が先頭）。spawn の中から使える。
    pub def collect(sink: Ref[List[Log.Record], Static]): Log.Sink =
        record -> Ref.put(record :: Ref.get(sink), sink)

}
