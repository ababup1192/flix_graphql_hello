///
/// Value と Java のオブジェクト（Integer / Long / Double / Boolean / String / Map / List）の相互変換。
/// graphql-java との境界でだけ使う。
///
mod JavaValue {
    import java.lang.Boolean
    import java.lang.Class
    import java.lang.Double
    import java.lang.Integer
    import java.lang.Long
    import java.lang.Object
    import java.util.{List => JList}
    import java.util.{Map => JMap}
    import java.util.Objects

    ///
    /// Value を graphql-java に返せる Java オブジェクトへ変換する。
    ///
    pub def toObject(value: Value): Object \ IO = match value {
        case Value.Null        => asObject(null)
        case Value.Bool(b)     => asObject(Boolean.valueOf(b))
        case Value.Int(n)      => asObject(Integer.valueOf(n))
        case Value.Float(x)    => asObject(Double.valueOf(x))
        case Value.Str(s)      => asObject(s)
        case Value.List(items) => asObject(Adaptor.toList(List.map(toObject, items)))
        case Value.Obj(fields) => asObject(Adaptor.toMap(Map.map(toObject, fields)))
    }

    ///
    /// Java の参照を Object として見る（アップキャスト）。
    ///
    /// WhyNot: checked_cast にしないのは、型変数 t が Object のサブタイプだと
    /// コンパイラに示せないため。渡すのは Java のオブジェクトだけなので実行時に失敗しない。
    ///
    def asObject(x: t): Object = unchecked_cast(x as Object)

    ///
    /// リゾルバに渡された引数 Map を Args へ変換する。
    ///
    pub def fromArguments(arguments: JMap[String, Object]): Args \ IO =
        Adaptor.fromMap(arguments) |> Map.map(fromObject)

    ///
    /// Java オブジェクトを Value へ変換する。
    /// Long は Int32 に収まれば Int、収まらなければ Float にする。
    ///
    /// WhyNot: 型ごとに instanceof で分けないのは、Flix から Java の instanceof を
    /// 直接書けないため。Class.isInstance で判定する。
    ///
    /// WhyNot: 知らない型でエラーにしないのは、graphql-java が返す値の型（enum や
    /// 独自スカラー）を全部は列挙できず、失敗にするとレスポンス全体が落ちるため。
    /// toString した文字列なら少なくとも中身は見える。
    ///
    pub def fromObject(obj: Object): Value \ IO =
        if (Objects.isNull(obj))
            Value.Null
        else if (isInstance("java.lang.Integer", obj))
            Value.Int((unchecked_cast(obj as Integer)).intValue())
        else if (isInstance("java.lang.Long", obj))
            fromLong((unchecked_cast(obj as Long)).longValue())
        else if (isInstance("java.lang.Double", obj))
            Value.Float((unchecked_cast(obj as Double)).doubleValue())
        else if (isInstance("java.lang.Boolean", obj))
            Value.Bool((unchecked_cast(obj as Boolean)).booleanValue())
        else if (isInstance("java.lang.String", obj))
            Value.Str(unchecked_cast(obj as String))
        else if (isInstance("java.util.Map", obj))
            Value.Obj(Adaptor.fromMap(unchecked_cast(obj as JMap[String, Object])) |> Map.map(item -> fromObject(item)))
        else if (isInstance("java.util.List", obj))
            Value.List(Adaptor.fromList(unchecked_cast(obj as JList[Object])) |> List.map(item -> fromObject(item)))
        else
            Value.Str(obj.toString())

    ///
    /// Int64 を Int32 に収まれば Int、収まらなければ Float にする。
    ///
    def fromLong(n: Int64): Value =
        Int64.tryToInt32(n) |> Option.map(Value.Int) |> Option.getWithDefault(Value.Float(Int64.toFloat64(n)))

    ///
    /// obj が className のインスタンスか。
    ///
    def isInstance(className: String, obj: Object): Bool \ IO =
        Class.forName(className).isInstance(obj)

}
