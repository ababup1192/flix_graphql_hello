///
/// Value と Java のオブジェクト（Integer / Long / Double / Boolean / String / Map / List）の相互変換。
/// graphql-java との境界でだけ使う。
///
mod JavaValue {
    import java.util.AbstractMap$SimpleImmutableEntry
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
    /// graphql-java に渡す不透明な Java オブジェクト。Flix の値（レコード・タプル・enum）を
    /// そのまま箱詰めして、フィールドの source として往復させる。
    ///
    pub enum Boxed {
        /// 中身は Flix の値か、Value から変換した Java の値
        case Boxed(Object)
    }

    ///
    /// Flix の値を箱詰めする。渡す物は Flix のレコード・タプル・enum（JVM 上でオブジェクトになる物）。
    /// Out.obj は (Context, 値) のタプルで包んでから渡すので、中身が Int32 でも問題ない。
    /// スカラー単体は toBoxed（Value 経由）で Integer 等にする。
    ///
    pub def box(x: a): Boxed = Boxed.Boxed(unchecked_cast(x as Object))

    ///
    /// 箱から Flix の値を取り出す。box した時と同じ型で受けること。
    ///
    pub def unbox(boxed: Boxed): a =
        let Boxed.Boxed(obj) = boxed;
        unchecked_cast(obj as a)

    ///
    /// 箱に型名のタグを付ける。union / interface の値を子フィールドの source にするときに使い、
    /// graphql-java の TypeResolver がタグを読んで具体型を決める。
    ///
    /// WhyNot: タグの入れ物に Flix の enum やタプルを使わないのは、Java 側から instanceof で見分けるのに
    /// Flix が生成する JVM クラス名が決まっていないため。SimpleImmutableEntry なら名前で判定できる。
    ///
    pub def tag(typeName: String, boxed: Boxed): Boxed \ IO =
        let Boxed.Boxed(obj) = boxed;
        let key: Object = checked_cast(typeName);
        Boxed.Boxed(checked_cast(new AbstractMap$SimpleImmutableEntry(key, obj)))

    ///
    /// タグ付きの箱なら (Some(型名), 中身)、そうでなければ (None, そのまま)。
    ///
    pub def untag(boxed: Boxed): (Option[String], Boxed) \ IO =
        let Boxed.Boxed(obj) = boxed;
        if (isInstance("java.util.AbstractMap$SimpleImmutableEntry", obj)) {
            let entry = unchecked_cast(obj as AbstractMap$SimpleImmutableEntry[Object, Object]);
            if (isInstance("java.lang.String", entry.getKey())) {
                let name: String = unchecked_cast(entry.getKey() as String);
                (Some(name), Boxed.Boxed(entry.getValue()))
            } else (None, boxed)
        } else (None, boxed)

    ///
    /// Value を Java の値にして箱詰めする。
    ///
    pub def toBoxed(value: Value): Boxed \ IO = Boxed.Boxed(toObject(value))

    ///
    /// null の箱。GraphQL の null になる。
    ///
    pub def boxedNull(): Boxed = Boxed.Boxed(asObject(null))

    ///
    /// 箱の一覧を Java の List にして箱詰めする。
    ///
    pub def boxedList(items: List[Boxed]): Boxed \ IO =
        Boxed.Boxed(asObject(Adaptor.toList(List.map(match Boxed.Boxed(obj) -> obj, items))))

    ///
    /// 箱の中身を Java オブジェクトとして取り出す。
    ///
    pub def toObjectOfBoxed(boxed: Boxed): Object =
        let Boxed.Boxed(obj) = boxed;
        obj

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
    pub def asObject(x: t): Object = unchecked_cast(x as Object)

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
        else if (isInstance("java.math.BigInteger", obj))
            fromBigInt(unchecked_cast(obj as BigInt))
        else if (isInstance("java.math.BigDecimal", obj))
            fromBigDecimal(unchecked_cast(obj as BigDecimal))
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
    /// BigInteger（scalar JSON のリテラルの整数）を Int32 に収まれば Int、収まらなければ Float にする。
    ///
    def fromBigInt(n: BigInt): Value = match (BigInt.tryToInt32(n), BigInt.tryToInt64(n)) {
        case (Some(small), _) => Value.Int(small)
        case (None, Some(big)) => Value.Float(Int64.toFloat64(big))
        case (None, None)      => Value.Str("${n}")
    }

    ///
    /// BigDecimal（scalar JSON のリテラルの小数）を Float にする。表せなければ Null。
    ///
    def fromBigDecimal(n: BigDecimal): Value =
        BigDecimal.tryToFloat64(n) |> Option.map(Value.Float) |> Option.getWithDefault(Value.Null)

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
