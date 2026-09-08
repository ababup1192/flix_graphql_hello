///
/// Fields のビルダー。型付きの追加をパイプで繋ぐ（`Fields.empty() |> Fields.str("k", "v") |> Log.info("m")`）。
///
mod Log.Fields {

    /// 空。
    pub def empty(): Log.Fields = Map.empty()

    /// 文字列を足す。同じ key は後勝ち。
    pub def str(key: String, value: String, fields: Log.Fields): Log.Fields =
        Map.insert(key, Value.Str(value), fields)

    ///
    /// 整数を足す。Int32 に収まらない値は両端に丸める。
    ///
    /// WhyNot: Value.Float に写さないのは、JsonValue が Float を BigDecimal 経由で書くので 12 が 12.0 になり、ログ基盤が小数の型で取るため。
    /// 所要時間（ms）とバイト数は Int32 に収まる。
    ///
    pub def int(key: String, value: Int64, fields: Log.Fields): Log.Fields =
        Map.insert(key, Value.Int(Int64.clampToInt32(min = Int32.minValue(), max = Int32.maxValue(), value)), fields)

    /// 真偽を足す。
    pub def bool(key: String, value: Bool, fields: Log.Fields): Log.Fields =
        Map.insert(key, Value.Bool(value), fields)

    /// 文字列の一覧を足す（graphql.error_codes など）。
    pub def strs(key: String, values: List[String], fields: Log.Fields): Log.Fields =
        Map.insert(key, Value.List(List.map(Value.Str, values)), fields)

    /// あれば文字列を足す。None なら付けない。
    pub def opt(key: String, value: Option[String], fields: Log.Fields): Log.Fields =
        match value {
            case Some(text) => str(key, text, fields)
            case None       => fields
        }

    /// 2 つを合わせる。同じ key は other が勝つ。
    pub def merge(other: Log.Fields, fields: Log.Fields): Log.Fields =
        Map.union(other, fields)

}
