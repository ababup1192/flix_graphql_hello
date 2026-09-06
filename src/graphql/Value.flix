///
/// GraphQL の値。JSON と同じ形で、リゾルバの引数と戻り値、レスポンスの data に使う。
/// Java のオブジェクトはここには出てこない。
///
pub enum Value with Eq, ToString {
    /// null
    case Null
    /// true / false
    case Bool(Bool)
    /// GraphQL の Int
    case Int(Int32)
    /// GraphQL の Float
    case Float(Float64)
    /// GraphQL の String / ID / enum
    case Str(String)
    /// 配列
    case List(List[Value])
    /// フィールド名 → 値のオブジェクト
    case Obj(Map[String, Value])
}

mod Value {

    ///
    /// オブジェクトの中のフィールドを取り出す。無ければ Null。
    ///
    pub def field(name: String, value: Value): Value = match value {
        case Value.Obj(fields) => Map.getWithDefault(name, Value.Null, fields)
        case _                 => Value.Null
    }

    ///
    /// 入れ子のフィールドを名前の並びで辿る。途中で無ければ Null。
    ///
    pub def path(names: List[String], value: Value): Value =
        List.foldLeft((found, name) -> field(name, found), value, names)

    ///
    /// Int として取り出す。Int でなければ None。
    ///
    pub def asInt(value: Value): Option[Int32] = match value {
        case Value.Int(n) => Some(n)
        case _            => None
    }

    ///
    /// String として取り出す。String でなければ None。
    ///
    pub def asStr(value: Value): Option[String] = match value {
        case Value.Str(s) => Some(s)
        case _            => None
    }

}
