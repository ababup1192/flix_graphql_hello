///
/// Value と標準ライブラリの Util.Json.Json の相互変換。HTTP のボディ、SDL の文字列リテラル、`scalar JSON` の値（管理 API の entry の中身）で使う。
///
mod JsonValue {
    use Util.Json.Json
    use Util.Json.JsonError
    use Util.Json.Json.{JArray, JBool, JNull, JNumber, JObject, JString}

    /// Float64 を Json の数に。
    ///
    /// WhyNot: `Float64.tryToBigDecimal` を使わない。2 進の展開そのままになり、0.8 が
    /// 0.80000000000000004440892098500626… の 50 桁で応答に出る（実機で出た）。
    /// 10 進の文字列を経由すれば書いた桁で収まる。同じ理由で Asset の見せ方も
    /// `Asset.number` が同じ形にしている。
    ///
    /// 表せない値（NaN / 無限）は JSON の数に無いので null。
    ///
    def floatJson(x: Float64): Json =
        if (Float64.isNan(x) or Float64.isInfinite(x)) JNull
        else BigDecimal.fromString(ToString.toString(x)) |> Option.map(JNumber) |> Option.getWithDefault(JNull)

    ///
    /// Value を Json へ変換する。
    ///
    pub def toJson(value: Value): Json = match value {
        case Value.Null        => JNull
        case Value.Bool(b)     => JBool(b)
        case Value.Int(n)      => JNumber(Int32.toBigDecimal(n))
        case Value.Float(x)    => floatJson(x)
        case Value.Str(s)      => JString(s)
        case Value.List(items) => JArray(List.map(toJson, items) |> List.toVector)
        case Value.Obj(fields) => JObject(Map.map(toJson, fields))
    }

    ///
    /// Json を Value へ変換する。整数に収まる数は Int、それ以外は Float。
    ///
    pub def fromJson(json: Json): Value = match json {
        case JNull          => Value.Null
        case JBool(b)       => Value.Bool(b)
        case JNumber(n)     => fromNumber(n)
        case JString(s)     => Value.Str(s)
        case JArray(items)  => Value.List(Vector.toList(items) |> List.map(fromJson))
        case JObject(fields) => Value.Obj(Map.map(fromJson, fields))
    }

    ///
    /// 小数点の無い書き方（10）で Int32 に収まる数は Int、小数点付き（10.0）と収まらない数は Float にする。
    /// Float64 で表せない大きさの数（1e400 など）は Str にして、桁をそのまま残す。
    ///
    /// WhyNot: 10.0 を Int にしないのは、scalar JSON は入れた物をそのまま返すのが期待で、Float で入れた値が Int で戻ると往復が崩れるため。
    ///
    def fromNumber(n: BigDecimal): Value =
        match (BigDecimal.tryToInt32(n), BigDecimal.tryToFloat64(n)) {
            case (Some(i), Some(x)) if Int32.toFloat64(i) == x and BigDecimal.scale(n) <= 0 => Value.Int(i)
            case (_, Some(x))                                  => Value.Float(x)
            case (_, None)                                     => Value.Str(BigDecimal.toPlainString(n))
        }

    ///
    /// JSON 文字列を Value へ読む。壊れていれば Err にエラーメッセージ。
    ///
    pub def parse(text: String): Result[String, Value] =
        Util.Json.parse(text) |> Result.map(fromJson) |> Result.mapErr((error: JsonError) -> ToString.toString(error))

    ///
    /// Value を JSON 文字列にする。
    ///
    pub def toJsonString(value: Value): String =
        Util.Json.toCompactString(toJson(value))

}
