///
/// 並び順のキーの値 1 つ。cursor に入れる形で、SQL の比較（EntryFilterSql.afterClause）の右辺になる。
///
pub enum CursorValue with Eq, Order, ToString {
    /// 値が無い（JSONB に無いキー、未公開の publishedAt、kind と合わない古い値）。並びの末尾
    case Null
    case Text(String)
    case Number(Float64)
    case Bool(Bool)
    /// 時刻。epoch からのマイクロ秒
    case Micros(Int64)
    /// 日付。epoch からの日数
    case Day(Int32)
}

///
/// 一覧の位置。並び順のキーの値（並び順と同じ順）と、順序を安定させる id。
/// 並び順と対で意味を持つので、キーは (SortKey, Direction) も持ち、復号の時に orderBy と突き合わせる。
///
/// WhyNot: レコードにしないのは、PageStart（enum）の payload に置いて Eq を derive するため。
///
pub enum Cursor with Eq, ToString {
    case Cursor(List[(SortKey, Direction, CursorValue)], String)
}

mod Cursor {

    use Util.Json.Json

    ///
    /// 並び順のキーの値と id。
    ///
    pub def keys(cursor: Cursor): List[(SortKey, Direction, CursorValue)] =
        let Cursor.Cursor(found, _) = cursor;
        found

    ///
    /// 順序を安定させる id（entry / asset の id）。
    ///
    pub def id(cursor: Cursor): String =
        let Cursor.Cursor(_, found) = cursor;
        found

    // ---- 作る ----

    ///
    /// entry の位置。orderBy（空なら更新が新しい順）のキーごとに entry から値を取り出す。
    /// フィールドの値は kind で取り出し方が決まり（EntryFilterSql の式と同じ規則）、型に無い apiId は文字列として読む。
    ///
    pub def ofEntry(fields: List[FieldDef], orderBy: OrderBy, entry: Entry): Cursor =
        Cursor.Cursor(OrderBy.effective(orderBy) |> List.map(match (key, direction) -> (key, direction, valueOf(fields, key, entry))), EntryId.text(entry#id))

    ///
    /// asset の位置。並びは作成が新しい順で固定。
    ///
    pub def ofAsset(asset: Asset): Cursor =
        Cursor.Cursor((SortKey.ByCreatedAt, Direction.Desc, CursorValue.Micros(Timestamp.toEpochMicros(asset#createdAt))) :: Nil, AssetId.text(asset#id))

    /// asset の一覧の並び順（ofAsset と対）。
    pub def assetOrderBy(): OrderBy = (SortKey.ByCreatedAt, Direction.Desc) :: Nil

    ///
    /// asset の cursor の位置（作成時刻と id）。assetOrderBy で復号した物から取る。形が違えば None。
    ///
    pub def assetPosition(cursor: Cursor): Option[(Timestamp.Timestamp, AssetId)] = match keys(cursor) {
        case (SortKey.ByCreatedAt, Direction.Desc, CursorValue.Micros(micros)) :: Nil => AssetId.parse(id(cursor)) |> Option.map(assetId -> (Timestamp.fromEpochMicros(micros), assetId))
        case _ => None
    }

    /// 並び順のキー 1 つの値を entry から取り出す。
    def valueOf(fields: List[FieldDef], key: SortKey, entry: Entry): CursorValue = match key {
        case SortKey.ById           => CursorValue.Text(EntryId.text(entry#id))
        case SortKey.ByPublishedAt  => entry#publishedAt |> Option.map(at -> CursorValue.Micros(Timestamp.toEpochMicros(at))) |> Option.getWithDefault(CursorValue.Null)
        case SortKey.ByUpdatedAt    => CursorValue.Micros(Timestamp.toEpochMicros(entry#updatedAt))
        case SortKey.ByCreatedAt    => CursorValue.Micros(Timestamp.toEpochMicros(entry#createdAt))
        case SortKey.ByField(apiId) => match List.find(field -> field#apiId == apiId, fields) |> Option.map(field -> field#kind) {
            case Some(FieldKind.Number)  => EntryValue.number(apiId, entry#data) |> Option.map(CursorValue.Number) |> Option.getWithDefault(CursorValue.Null)
            case Some(FieldKind.Boolean) => EntryValue.bool(apiId, entry#data) |> Option.map(CursorValue.Bool) |> Option.getWithDefault(CursorValue.Null)
            case Some(FieldKind.Date)    => EntryValue.text(apiId, entry#data) |> Option.flatMap(DateValues.parse) |> Option.map(at -> CursorValue.Micros(Timestamp.toEpochMicros(at))) |> Option.getWithDefault(CursorValue.Null)
            case Some(FieldKind.DateOnly) => EntryValue.text(apiId, entry#data) |> Option.filter(DateOnlyValues.isCanonical) |> Option.flatMap(DateOnlyValues.parse) |> Option.map(on -> CursorValue.Day(Date.toEpochDay(on))) |> Option.getWithDefault(CursorValue.Null)
            case _                       => EntryValue.text(apiId, entry#data) |> Option.map(CursorValue.Text) |> Option.getWithDefault(CursorValue.Null)
        }
    }

    // ---- 文字列との往復 ----

    ///
    /// 不透明な文字列に。JSON を base64url にした物で、クライアントは中を読まず endCursor をそのまま after に渡す。
    ///
    pub def encode(cursor: Cursor): String =
        Base64Url.encode(String.toBytes(Util.Json.toCompactString(toJson(cursor))))

    ///
    /// 文字列から。壊れていれば Err。orderBy（実際の並び順。空なら更新が新しい順）と対でない cursor も Err（並び順を変えて古い cursor を渡した）。
    ///
    pub def decode(orderBy: OrderBy, text: String): Result[Violation, Cursor] =
        Base64Url.decode(text)
            |> Result.map(String.fromBytes)
            |> Result.flatMap(raw -> Util.Json.parse(raw) |> Result.mapErr(_ -> "JSON が壊れています"))
            |> Result.flatMap(fromJson)
            |> Result.mapErr(_ -> Violation.Violation("after", "cursor が壊れています"))
            |> Result.flatMap(cursor ->
                if (terms(cursor) == OrderBy.effective(orderBy)) Ok(cursor)
                else Err(Violation.Violation("after", "cursor が orderBy と合いません（並び順を変えたら先頭から読み直してください）")))

    ///
    /// skip で飛ばせる上限。これより後ろは after（cursor）で読む。
    ///
    /// WhyNot: もっと大きくしないのは、OFFSET は飛ばす行も全部読むため。entry 11 万件で OFFSET 10000 が 37ms、
    /// 50000 が 100ms で、同じ位置を cursor で引けば 9ms。管理画面の一覧は 1 ページ 50 件なので 200 ページ目まで届く。
    ///
    pub def maxSkip(): Int32 = 10000

    ///
    /// ページの始まり。after と skip（0 は指定なし）を同時に渡せば Err（どちらか 1 つ）。after は orderBy と対で復号する。
    /// skip が maxSkip を超えても Err（深い所は cursor で読む）。
    ///
    pub def pageStart(orderBy: OrderBy, skip: Int32, after: Option[String]): Result[Violation, PageStart] = match after {
        case None if skip > maxSkip() => Err(tooDeep())
        case None                     => Ok(PageStart.Offset(skip))
        case Some(_) if skip != 0     => Err(Violation.Violation("after", "after と skip は同時に指定できません（どちらか 1 つ）"))
        case Some(text)               => decode(orderBy, text) |> Result.map(PageStart.After)
    }

    /// skip が深すぎる時の違反。cursor（after）へ誘導する。
    def tooDeep(): Violation =
        Violation.Violation("skip", "skip は ${maxSkip()} まで指定できます（これより後ろは after に前のページの endCursor を指定してください）")

    /// cursor の並び順（値を除いた物）。
    def terms(cursor: Cursor): OrderBy = keys(cursor) |> List.map(match (key, direction, _) -> (key, direction))

    def toJson(cursor: Cursor): Json =
        Json.JObject(Map#{
            "k" => Json.JArray(keys(cursor) |> List.map(keyToJson) |> List.toVector),
            "id" => Json.JString(id(cursor))
        })

    /// キー 1 つ。{ "key": 名前, "dir": ASC / DESC, 値（s / n / b / t / d のどれか。無ければ null）}。
    def keyToJson(term: (SortKey, Direction, CursorValue)): Json =
        let (key, direction, value) = term;
        let base = Map#{ "key" => Json.JString(SortKey.toText(key)), "dir" => Json.JString(Direction.toText(direction)) };
        Json.JObject(match value {
            case CursorValue.Null           => base
            case CursorValue.Text(text)     => Map.insert("s", Json.JString(text), base)
            case CursorValue.Number(x)      => Map.insert("n", Float64.tryToBigDecimal(x) |> Option.map(Json.JNumber) |> Option.getWithDefault(Json.JNull), base)
            case CursorValue.Bool(b)        => Map.insert("b", Json.JBool(b), base)
            case CursorValue.Micros(micros) => Map.insert("t", Json.JNumber(Int64.toBigDecimal(micros)), base)
            case CursorValue.Day(days)      => Map.insert("d", Json.JNumber(Int32.toBigDecimal(days)), base)
        })

    def fromJson(json: Json): Result[String, Cursor] = match json {
        case Json.JObject(fields) =>
            forM (
                foundKeys <- Map.get("k", fields) |> Option.toOk("k が無い") |> Result.flatMap(keysFromJson);
                foundId   <- Map.get("id", fields) |> Option.flatMap(EntryValue.asString) |> Option.toOk("id が無い")
            ) yield Cursor.Cursor(foundKeys, foundId)
        case _ => Err("オブジェクトではない")
    }

    def keysFromJson(json: Json): Result[String, List[(SortKey, Direction, CursorValue)]] = match json {
        case Json.JArray(items) => Vector.toList(items) |> Result.traverse(keyFromJson)
        case _                  => Err("k が配列ではない")
    }

    def keyFromJson(json: Json): Result[String, (SortKey, Direction, CursorValue)] = match json {
        case Json.JObject(fields) =>
            forM (
                key       <- Map.get("key", fields) |> Option.flatMap(EntryValue.asString) |> Option.flatMap(SortKey.fromText) |> Option.toOk("key が読めない");
                direction <- Map.get("dir", fields) |> Option.flatMap(EntryValue.asString) |> Option.flatMap(Direction.fromText) |> Option.toOk("dir が読めない");
                value     <- valueFromJson(fields)
            ) yield (key, direction, value)
        case _ => Err("キーがオブジェクトではない")
    }

    /// s / n / b / t / d のどれか 1 つ。どれも無ければ Null。形が違えば Err。
    def valueFromJson(fields: Map[String, Json]): Result[String, CursorValue] =
        match (Map.get("s", fields), Map.get("n", fields), Map.get("b", fields), Map.get("t", fields), Map.get("d", fields)) {
            case (Some(s), None, None, None, None) => EntryValue.asString(s) |> Option.map(CursorValue.Text) |> Option.toOk("s が文字列ではない")
            case (None, Some(n), None, None, None) => EntryValue.asFloat64(n) |> Option.map(CursorValue.Number) |> Option.toOk("n が数ではない")
            case (None, None, Some(b), None, None) => EntryValue.asBool(b) |> Option.map(CursorValue.Bool) |> Option.toOk("b が真偽値ではない")
            case (None, None, None, Some(t), None) => asInt64(t) |> Option.map(CursorValue.Micros) |> Option.toOk("t が整数ではない")
            case (None, None, None, None, Some(d)) => asInt64(d) |> Option.flatMap(Int64.tryToInt32) |> Option.map(CursorValue.Day) |> Option.toOk("d が整数ではない")
            case (None, None, None, None, None)    => Ok(CursorValue.Null)
            case _                                 => Err("値が 2 つ以上ある")
        }

    def asInt64(json: Json): Option[Int64] = match json {
        case Json.JNumber(n) => BigDecimal.tryToInt64(n)
        case _               => None
    }

}
