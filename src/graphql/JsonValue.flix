///
/// Value と標準ライブラリの Util.Json.Json の相互変換。HTTP のボディ、SDL の文字列リテラル、`scalar JSON` の値（管理 API の entry の中身）で使う。
///
mod JsonValue {
    use Util.Json.Json
    use Util.Json.JsonError
    use Util.Json.Json.{JArray, JBool, JNull, JNumber, JObject, JString}

    ///
    /// Value を Json へ変換する。
    ///
    pub def toJson(value: Value): Json = match value {
        case Value.Null        => JNull
        case Value.Bool(b)     => JBool(b)
        case Value.Int(n)      => JNumber(Int32.toBigDecimal(n))
        case Value.Float(x)    => Float64.tryToBigDecimal(x) |> Option.map(JNumber) |> Option.getWithDefault(JNull)
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
    /// 小数点以下が無く Int32 に収まる数は Int、それ以外は Float にする。
    /// Float64 で表せない大きさの数（1e400 など）は Str にして、桁をそのまま残す。
    ///
    def fromNumber(n: BigDecimal): Value =
        match (BigDecimal.tryToInt32(n), BigDecimal.tryToFloat64(n)) {
            case (Some(i), Some(x)) if Int32.toFloat64(i) == x => Value.Int(i)
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
