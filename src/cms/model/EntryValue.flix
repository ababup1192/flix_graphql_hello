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

    pub def text(apiId: ApiId, data: EntryData): Option[String] =
        Map.get(apiId, data) |> Option.flatMap(asString)

    pub def texts(apiId: ApiId, data: EntryData): List[String] =
        Map.get(apiId, data) |> Option.map(items(asString)) |> Option.getWithDefault(Nil)

    pub def number(apiId: ApiId, data: EntryData): Option[Float64] =
        Map.get(apiId, data) |> Option.flatMap(asFloat64)

    pub def numbers(apiId: ApiId, data: EntryData): List[Float64] =
        Map.get(apiId, data) |> Option.map(items(asFloat64)) |> Option.getWithDefault(Nil)

    pub def bool(apiId: ApiId, data: EntryData): Option[Bool] =
        Map.get(apiId, data) |> Option.flatMap(asBool)

    pub def bools(apiId: ApiId, data: EntryData): List[Bool] =
        Map.get(apiId, data) |> Option.map(items(asBool)) |> Option.getWithDefault(Nil)

    ///
    /// Object の値（1 つ）。オブジェクトでなければ None。
    ///
    pub def object(apiId: ApiId, data: EntryData): Option[EntryData] =
        Map.get(apiId, data) |> Option.flatMap(asObject)

    ///
    /// Object の値（配列）。オブジェクトでない要素は捨てる。
    ///
    pub def objects(apiId: ApiId, data: EntryData): List[EntryData] =
        Map.get(apiId, data) |> Option.map(items(asObject)) |> Option.getWithDefault(Nil)

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

    pub def asObject(json: Json): Option[EntryData] = match json {
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
