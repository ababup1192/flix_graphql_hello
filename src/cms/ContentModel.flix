///
/// content type の定義。管理 API の type ContentType の source で、フィールドを抱えて 1 度に読む。
///
/// - id: content_types.id
/// - apiId: lowerCamel の識別子（"blogs"）。コンテンツ API のクエリ名の元
/// - kind: collection か singleton
/// - name: 管理画面に出す名前
/// - singular / plural: コンテンツ API の型名（"Blog"）と一覧クエリ名（"blogs"）
/// - previewUrl: 管理画面のプレビューが開く URL。無ければ None
/// - fields: position 順のフィールド
/// - createdAt / updatedAt: ISO 8601
///
pub type alias ContentType = {
    id = Id,
    apiId = String,
    kind = GeneratedAdmin.TypeKind,
    name = String,
    singular = String,
    plural = String,
    previewUrl = Option[String],
    fields = List[FieldDef],
    createdAt = String,
    updatedAt = String
}

///
/// フィールドの定義。管理 API の type FieldDef の source。
///
/// - id: content_fields.id
/// - typeId: 属する content type の id（content_types.id）
/// - apiId: 型の中で一意な lowerCamel の識別子
/// - kind: 種類
/// - many: 配列か
/// - required: 公開時に値が要るか
/// - unique: 型の中で値が一意か
/// - localized: 言語ごとに値を持つか
/// - config: kind ごとの設定
/// - position: 並び順（0 始まり）
///
pub type alias FieldDef = {
    id = Id,
    typeId = Int64,
    apiId = String,
    name = String,
    kind = GeneratedAdmin.FieldKind,
    many = Bool,
    required = Bool,
    unique = Bool,
    localized = Bool,
    config = FieldConfig,
    position = Int32
}

///
/// kind ごとの設定。使わない項目は None。管理 API の type FieldConfig の source で、input FieldConfigInput と同じ形。
///
/// - maxLength: TEXT / TEXT_AREA / SLUG の最大文字数
/// - sourceField: SLUG の元にするフィールドの apiId
/// - min / max: NUMBER の範囲
/// - integer: NUMBER を整数に限るか
///
pub type alias FieldConfig = { maxLength = Option[Int32], sourceField = Option[String], min = Option[Float64], max = Option[Float64], integer = Option[Bool] }

///
/// DB の行と GraphQL の値のあいだの変換。kind の文字列、config の JSON、id の文字列。
///
mod ContentModel {

    use GeneratedAdmin.TypeKind
    use GeneratedAdmin.FieldKind
    use Util.Json.Json

    ///
    /// 何も設定していない config。
    ///
    pub def emptyConfig(): FieldConfig = { maxLength = None, sourceField = None, min = None, max = None, integer = None }

    ///
    /// content_types.id を GraphQL の ID にする。
    ///
    pub def idOf(number: Int64): Id = Id.Id(Int64.toString(number))

    ///
    /// GraphQL の ID を DB の id に戻す。数字でなければ None。
    ///
    pub def parseId(id: Id): Option[Int64] =
        let Id.Id(text) = id;
        Int64.fromString(text)

    // ---- kind ----

    ///
    /// content_types.kind の値。CHECK 制約の文字列と揃える。
    ///
    pub def typeKindToDb(kind: TypeKind): String = match kind {
        case TypeKind.Collection => "collection"
        case TypeKind.Singleton  => "singleton"
    }

    ///
    /// content_types.kind の値から。知らない文字列は None（DDL の CHECK が守るので起きない）。
    ///
    pub def typeKindFromDb(text: String): Option[TypeKind] = match text {
        case "collection" => Some(TypeKind.Collection)
        case "singleton"  => Some(TypeKind.Singleton)
        case _            => None
    }

    ///
    /// content_fields.kind の値。
    ///
    pub def fieldKindToDb(kind: FieldKind): String = match kind {
        case FieldKind.Text     => "text"
        case FieldKind.TextArea => "textArea"
        case FieldKind.Slug     => "slug"
        case FieldKind.Number   => "number"
        case FieldKind.Boolean  => "boolean"
    }

    ///
    /// content_fields.kind の値から。知らない文字列は None。
    ///
    pub def fieldKindFromDb(text: String): Option[FieldKind] = match text {
        case "text"     => Some(FieldKind.Text)
        case "textArea" => Some(FieldKind.TextArea)
        case "slug"     => Some(FieldKind.Slug)
        case "number"   => Some(FieldKind.Number)
        case "boolean"  => Some(FieldKind.Boolean)
        case _          => None
    }

    // ---- config ----

    ///
    /// config を content_fields.config の JSON にする。None の項目はキー自体を出さない。
    ///
    /// WhyNot: NaN や無限大の min / max を落とすのは、JSON に書けないため。GraphQL の Float からは来ない。
    ///
    pub def configToJson(config: FieldConfig): Json =
        let entries =
            ("maxLength", config#maxLength |> Option.map(n -> Json.JNumber(Int32.toBigDecimal(n)))) ::
            ("sourceField", config#sourceField |> Option.map(Json.JString)) ::
            ("min", config#min |> Option.flatMap(Float64.tryToBigDecimal) |> Option.map(Json.JNumber)) ::
            ("max", config#max |> Option.flatMap(Float64.tryToBigDecimal) |> Option.map(Json.JNumber)) ::
            ("integer", config#integer |> Option.map(Json.JBool)) ::
            Nil;
        Json.JObject(entries |> List.filterMap(match (key, value) -> Option.map(json -> (key, json), value)) |> List.toMap)

    ///
    /// content_fields.config の JSON から。無いキーや型の違う値は None にする。
    ///
    pub def configFromJson(json: Json): FieldConfig =
        let fields = match json {
            case Json.JObject(map) => map
            case _                 => Map.empty()
        };
        {
            maxLength   = Map.get("maxLength", fields) |> Option.flatMap(asInt32),
            sourceField = Map.get("sourceField", fields) |> Option.flatMap(asString),
            min         = Map.get("min", fields) |> Option.flatMap(asFloat64),
            max         = Map.get("max", fields) |> Option.flatMap(asFloat64),
            integer     = Map.get("integer", fields) |> Option.flatMap(asBool)
        }

    ///
    /// GraphQL の FieldConfigInput から。省略なら空の config。
    ///
    pub def configOfInput(input: Option[GeneratedAdmin.FieldConfigInput]): FieldConfig = match input {
        case Some(given) => { maxLength = given#maxLength, sourceField = given#sourceField, min = given#min, max = given#max, integer = given#integer }
        case None        => emptyConfig()
    }

    def asInt32(json: Json): Option[Int32] = match json {
        case Json.JNumber(n) => BigDecimal.tryToInt32(n)
        case _               => None
    }

    def asFloat64(json: Json): Option[Float64] = match json {
        case Json.JNumber(n) => BigDecimal.tryToFloat64(n)
        case _               => None
    }

    def asString(json: Json): Option[String] = match json {
        case Json.JString(s) => Some(s)
        case _               => None
    }

    def asBool(json: Json): Option[Bool] = match json {
        case Json.JBool(b) => Some(b)
        case _             => None
    }

    // ---- 行 → 値 ----

    ///
    /// content_types の行とそのフィールドから ContentType を組む。kind の文字列が読めなければ Err（DDL の CHECK が守るので起きない）。
    ///
    pub def typeOfRow(row: { id = Int64, apiId = String, kind = String, name = String, singular = String, plural = String, previewUrl = String, createdAt = Timestamp.Timestamp, updatedAt = Timestamp.Timestamp | r }, fields: List[FieldDef]): Result[String, ContentType] =
        typeKindFromDb(row#kind) |> Option.toOk("content_types.kind が読めません: ${row#kind}") |> Result.map(kind -> {
            id         = idOf(row#id),
            apiId      = row#apiId,
            kind       = kind,
            name       = row#name,
            singular   = row#singular,
            plural     = row#plural,
            previewUrl = if (row#previewUrl == "") None else Some(row#previewUrl),
            fields     = fields |> List.sortBy(field -> field#position),
            createdAt  = Timestamp.toIso8601(row#createdAt),
            updatedAt  = Timestamp.toIso8601(row#updatedAt)
        })

    ///
    /// content_fields の行から FieldDef を組む。kind の文字列が読めなければ Err。
    ///
    pub def fieldOfRow(row: { id = Int64, typeId = Int64, apiId = String, name = String, kind = String, isMany = Bool, isRequired = Bool, isUnique = Bool, isLocalized = Bool, config = Json, position = Int32 | r }): Result[String, FieldDef] =
        fieldKindFromDb(row#kind) |> Option.toOk("content_fields.kind が読めません: ${row#kind}") |> Result.map(kind -> {
            id        = idOf(row#id),
            typeId    = row#typeId,
            apiId     = row#apiId,
            name      = row#name,
            kind      = kind,
            many      = row#isMany,
            required  = row#isRequired,
            unique    = row#isUnique,
            localized = row#isLocalized,
            config    = configFromJson(row#config),
            position  = row#position
        })

}
