///
/// GraphQL の ID スカラー。String と型で区別して、ID と String の取り違えをコンパイルで落とす。
///
pub enum Id with Eq, Order, ToString {
    /// ID の文字列表現
    case Id(String)
}

///
/// GraphQL のスカラー型と Flix の型の対応。GraphQL の型参照と、Flix の値 <-> Value の相互変換を束ねる。
/// 引数のデコードとスカラー戻り値のエンコードに使う。オブジェクト型はこれではなく ObjectType で表す。
///
/// WhyNot: trait にしないのは、同じ Flix の型（String）を GraphQL の String にも ID にも
/// 対応させたい場面が trait では表せず、レコード型への instance も書けないため。
/// 名前に Gql を付けるのは、標準ライブラリの Util.Codec と衝突させないため。
///
pub enum GqlCodec[a] {
    /// typeRef は SDL に出す型、encode / decode は Value との相互変換
    case GqlCodec({ typeRef = TypeRef, encode = a -> Value, decode = Value -> Result[String, a] })
}

mod GqlCodec {

    ///
    /// GraphQL の Int。
    ///
    pub def int32(): GqlCodec[Int32] =
        scalar("Int", Value.Int, Value.asInt)

    ///
    /// GraphQL の Float。
    ///
    pub def float64(): GqlCodec[Float64] =
        scalar("Float", Value.Float, value -> match value {
            case Value.Float(x) => Some(x)
            case Value.Int(n)   => Some(Int32.toFloat64(n))
            case _              => None
        })

    ///
    /// GraphQL の String。
    ///
    pub def string(): GqlCodec[String] =
        scalar("String", Value.Str, Value.asStr)

    ///
    /// GraphQL の Boolean。
    ///
    pub def bool(): GqlCodec[Bool] =
        scalar("Boolean", Value.Bool, value -> match value {
            case Value.Bool(b) => Some(b)
            case _             => None
        })

    ///
    /// GraphQL の ID。Flix 側は Id で持つ。
    ///
    pub def id(): GqlCodec[Id] =
        scalar("ID", match Id.Id(text) -> Value.Str(text), value -> Value.asStr(value) |> Option.map(Id.Id))

    ///
    /// GraphQL の enum。values は全部の値（SDL にはこの順で出る）、toName は各値の SDL 上の名前。
    /// Flix 側は enum で持ち、toName を match で書けば網羅性がコンパイラで検査される。
    ///
    /// WhyNot: （名前, 値）のペアの一覧で受けないのは、値が漏れてもコンパイルで落ちず、
    /// encode が None になって graphql-java の分かりにくい null エラーになるため。
    ///
    pub def enumOf(typeName: String, toName: a -> String, values: List[a]): GqlCodec[a] =
        let byName = values |> List.map(value -> (toName(value), value)) |> List.toMap;
        GqlCodec.GqlCodec({
            typeRef = TypeRef.Enum(typeName, List.map(toName, values)),
            encode  = value -> Value.Str(toName(value)),
            decode  = value -> Value.asStr(value) |> Option.flatMap(name -> Map.get(name, byName)) |> Option.toOk("expected ${typeName}")
        })

    ///
    /// nullable にする。Flix の None が GraphQL の null。
    /// option を二重に重ねても nullable は 1 段のまま（GraphQL に二重の nullable は無い）。
    ///
    pub def option(codec: GqlCodec[a]): GqlCodec[Option[a]] =
        let GqlCodec.GqlCodec(inner) = codec;
        GqlCodec.GqlCodec({
            typeRef = TypeRef.nullable(inner#typeRef),
            encode  = maybe -> maybe |> Option.map(inner#encode) |> Option.getWithDefault(Value.Null),
            decode  = value -> match value {
                case Value.Null => Ok(None)
                case _          => (inner#decode)(value) |> Result.map(Some)
            }
        })

    ///
    /// リストにする。要素は codec で 1 つずつ変換する。
    ///
    pub def list(codec: GqlCodec[a]): GqlCodec[List[a]] =
        let GqlCodec.GqlCodec(inner) = codec;
        GqlCodec.GqlCodec({
            typeRef = TypeRef.ListOf(inner#typeRef),
            encode  = items -> Value.List(List.map(inner#encode, items)),
            decode  = value -> match value {
                case Value.List(items) => Result.traverse(inner#decode, items)
                case _                 => Err("expected a list")
            }
        })

    ///
    /// SDL に出す型参照。
    ///
    pub def typeRef(codec: GqlCodec[a]): TypeRef =
        let GqlCodec.GqlCodec(inner) = codec;
        inner#typeRef

    ///
    /// Flix の値を Value にする。
    ///
    pub def encode(codec: GqlCodec[a], x: a): Value =
        let GqlCodec.GqlCodec(inner) = codec;
        (inner#encode)(x)

    ///
    /// Value を Flix の値にする。型が合わなければ Err。
    ///
    pub def decode(codec: GqlCodec[a], value: Value): Result[String, a] =
        let GqlCodec.GqlCodec(inner) = codec;
        (inner#decode)(value)

    ///
    /// 名前付きスカラーを作る。read が None なら「その型ではない」Err にする。
    ///
    def scalar(typeName: String, write: a -> Value, read: Value -> Option[a]): GqlCodec[a] =
        GqlCodec.GqlCodec({
            typeRef = TypeRef.Scalar(typeName),
            encode  = write,
            decode  = value -> read(value) |> Option.toOk("expected ${typeName}")
        })

}
