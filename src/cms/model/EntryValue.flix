///
/// entry の中身（JSON）の読み方。kind ごとの値の取り出しと、Object / Blocks の入れ子の読み方。全部純粋。
/// 形が違う値は無い物として扱う（下書きの検証が守るので普段は起きない）。検証・参照の取り出し・コンテンツ API が同じ読み方を使う。
///
mod EntryValue {

    use Util.Json.Json

    ///
    /// Blocks の要素で variant を選ぶキー。
    ///
    pub def blockTypeKey(): String = "blockType"

    // ---- フィールドの値 ----

    pub def text(apiId: ApiId, data: EntryData): Option[String] = one(asString, apiId, data)

    pub def texts(apiId: ApiId, data: EntryData): List[String] = many(asString, apiId, data)

    pub def number(apiId: ApiId, data: EntryData): Option[Float64] = one(asFloat64, apiId, data)

    pub def numbers(apiId: ApiId, data: EntryData): List[Float64] = many(asFloat64, apiId, data)

    pub def bool(apiId: ApiId, data: EntryData): Option[Bool] = one(asBool, apiId, data)

    pub def bools(apiId: ApiId, data: EntryData): List[Bool] = many(asBool, apiId, data)

    ///
    /// Object の値（1 つ）。オブジェクトでなければ None。
    ///
    pub def object(apiId: ApiId, data: EntryData): Option[EntryData] = one(asObject, apiId, data)

    ///
    /// Object の値（配列）。オブジェクトでない要素は捨てる。
    ///
    pub def objects(apiId: ApiId, data: EntryData): List[EntryData] = many(asObject, apiId, data)

    ///
    /// 単数のフィールドを pick で読む。無い・形が違うなら None。
    ///
    def one(pick: Json -> Option[a], apiId: ApiId, data: EntryData): Option[a] =
        Map.get(apiId, data) |> Option.flatMap(pick)

    ///
    /// 配列のフィールドの要素を pick で読む。無い・配列でないなら空、読めない要素は捨てる。
    ///
    def many(pick: Json -> Option[a], apiId: ApiId, data: EntryData): List[a] =
        Map.get(apiId, data) |> Option.map(items(pick)) |> Option.getWithDefault(Nil)

    ///
    /// Blocks の値。(variant, 中身) の並び。blockType が variant に無い要素は捨てる。
    ///
    pub def blocks(field: FieldDef, data: EntryData): List[(FieldDef, EntryData)] =
        Map.get(field#apiId, data)
            |> Option.map(items(readBlock(Children.toList(field#children))))
            |> Option.getWithDefault(Nil)

    // ---- 入れ子 ----

    ///
    /// Blocks の値の 1 つを (variant, 中身) に読む。blockType が variant の apiId でなければ None。
    ///
    pub def readBlock(variants: List[FieldDef], value: Json): Option[(FieldDef, EntryData)] = match value {
        case Json.JObject(fields) =>
            Map.get(blockTypeKey(), fields) |> Option.flatMap(asString)
                |> Option.flatMap(name -> variants |> List.find(variant -> ApiId.text(variant#apiId) == name))
                |> Option.map(variant -> (variant, objectData(Map.remove(blockTypeKey(), fields))))
        case _ => None
    }

    ///
    /// JSON のオブジェクトを中身に。apiId の規則に合わないキーは捨てる（検証は規則に合うキーだけ「この型にありません」と言えれば足りる）。
    ///
    pub def objectData(fields: Map[String, Json]): EntryData =
        fields |> Map.toList |> List.filterMap(match (key, value) -> ApiId.parse(key) |> Option.map(apiId -> (apiId, value))) |> List.toMap

    def asObject(json: Json): Option[EntryData] = match json {
        case Json.JObject(fields) => Some(objectData(fields))
        case _                    => None
    }

    // ---- JSON の 1 値 ----

    ///
    /// 配列の要素を pick で読む。配列でなければ空、読めない要素は捨てる。
    ///
    pub def items(pick: Json -> Option[a], json: Json): List[a] = match json {
        case Json.JArray(values) => values |> Vector.toList |> List.filterMap(pick)
        case _                   => Nil
    }

    ///
    /// 配列の要素を位置付きで読む。位置は配列の中の元の番号（読めない要素を飛ばしても詰めない）。
    ///
    pub def itemsWithIndex(pick: Json -> Option[a], json: Json): List[(Int32, a)] = match json {
        case Json.JArray(values) => values |> Vector.toList |> List.zipWithIndex |> List.filterMap(match (index, item) -> pick(item) |> Option.map(found -> (index, found)))
        case _                   => Nil
    }

    pub def asString(json: Json): Option[String] = match json {
        case Json.JString(s) => Some(s)
        case _               => None
    }

    pub def asStrings(json: Json): List[String] = items(asString, json)

    pub def asFloat64(json: Json): Option[Float64] = match json {
        case Json.JNumber(n) => BigDecimal.tryToFloat64(n)
        case _               => None
    }

    pub def asInt32(json: Json): Option[Int32] = match json {
        case Json.JNumber(n) => BigDecimal.tryToInt32(n)
        case _               => None
    }

    pub def asBool(json: Json): Option[Bool] = match json {
        case Json.JBool(b) => Some(b)
        case _             => None
    }

}
