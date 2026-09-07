///
/// microCMS の「API スキーマ」の export（JSON）を読み、この CMS の型に写す前の形にする。純粋。
/// 写し方: text → TEXT、textArea → TEXT_AREA、richEditor → RICH_TEXT、media → ASSET、boolean → BOOLEAN、number → NUMBER、
/// relation → REFERENCE、relationList → REFERENCE（配列）、repeater → BLOCKS（customFieldIds が variant、custom の fields が子）。
///
mod MicrocmsSchema {

    use Util.Json.Json

    ///
    /// microCMS のフィールドの種類。relation 系は参照先の API のエンドポイント、repeater は variant にする custom field の id。
    ///
    pub enum Kind with Eq, ToString {
        case Text
        case TextArea
        case RichEditor
        case Media
        case Boolean
        case Number
        case Relation(String)
        case RelationList(String)
        case Repeater(List[String])
        /// この CMS に写せない種類（select / date / file / iframe / custom 単体など）。名前を持って報告する
        case Unsupported(String)
    }

    /// フィールド 1 つ。fieldId は microCMS の識別子（この CMS の apiId にそのまま使う）。
    pub type alias Field = { fieldId = String, name = String, kind = Kind, required = Bool }

    /// custom field（repeater の variant になる）。
    pub type alias CustomField = { fieldId = String, name = String, fields = List[Field] }

    /// API 1 つ。endpoint は microCMS のエンドポイント名（"insidesales-category" など）。
    pub type alias Api = { endpoint = String, apiId = ApiId, fields = List[Field], customFields = List[CustomField] }

    ///
    /// export の JSON を読む。形が違えば Err。
    ///
    pub def parse(endpoint: String, text: String): Result[String, Api] =
        forM (
            json <- Util.Json.parse(text) |> Result.mapErr(error -> "${endpoint}: JSON が読めません: ${error}");
            apiId <- apiIdOf(endpoint) |> Option.toOk("${endpoint}: エンドポイント名を apiId にできません");
            root <- asObject(json) |> Option.toOk("${endpoint}: オブジェクトではありません");
            fields <- Map.get("apiFields", root) |> Option.flatMap(asArray) |> Option.toOk("${endpoint}: apiFields がありません") |> Result.flatMap(items -> Result.traverse(fieldOf(endpoint), items));
            customs <- Map.get("customFields", root) |> Option.flatMap(asArray) |> Option.getWithDefault(Nil) |> Result.traverse(customOf(endpoint))
        ) yield { endpoint = endpoint, apiId = apiId, fields = fields, customFields = customs }

    ///
    /// エンドポイント名を lowerCamel の apiId に。"insidesales-category-keywords" → "insidesalesCategoryKeywords"、"insidesale_services" → "insidesaleServices"。
    ///
    pub def apiIdOf(endpoint: String): Option[ApiId] =
        endpoint
            |> String.splitOn(substr = "-") |> List.flatMap(String.splitOn(substr = "_"))
            |> List.filter(part -> not String.isEmpty(part))
            |> List.mapWithIndex((index, part) -> if (index == 0) String.toLowerCase(part) else String.toUpperCase(String.takeLeft(1, part)) + String.toLowerCase(String.dropLeft(1, part)))
            |> List.join("")
            |> ApiId.parse

    def fieldOf(endpoint: String, json: Json): Result[String, Field] =
        forM (
            fields <- asObject(json) |> Option.toOk("${endpoint}: apiFields の要素がオブジェクトではありません");
            fieldId <- stringAt("fieldId", fields) |> Option.toOk("${endpoint}: fieldId がありません");
            kindText <- stringAt("kind", fields) |> Option.toOk("${endpoint}.${fieldId}: kind がありません")
        ) yield {
            fieldId = fieldId,
            name = stringAt("name", fields) |> Option.getWithDefault(fieldId),
            kind = kindOf(kindText, fields),
            required = Map.get("required", fields) |> Option.flatMap(asBool) |> Option.getWithDefault(false)
        }

    def customOf(endpoint: String, json: Json): Result[String, CustomField] =
        forM (
            fields <- asObject(json) |> Option.toOk("${endpoint}: customFields の要素がオブジェクトではありません");
            fieldId <- stringAt("fieldId", fields) |> Option.toOk("${endpoint}: custom field の fieldId がありません");
            children <- Map.get("fields", fields) |> Option.flatMap(asArray) |> Option.getWithDefault(Nil) |> Result.traverse(fieldOf("${endpoint}.${fieldId}"))
        ) yield { fieldId = fieldId, name = stringAt("name", fields) |> Option.getWithDefault(fieldId), fields = children }

    def kindOf(kindText: String, fields: Map[String, Json]): Kind = match kindText {
        case "text"         => Kind.Text
        case "textArea"     => Kind.TextArea
        case "richEditor"   => Kind.RichEditor
        case "richEditorV2" => Kind.RichEditor
        case "media"        => Kind.Media
        case "boolean"      => Kind.Boolean
        case "number"       => Kind.Number
        case "relation"     => stringAt("referencedApiEndpoint", fields) |> Option.map(Kind.Relation) |> Option.getWithDefault(Kind.Unsupported("relation（参照先なし）"))
        case "relationList" => stringAt("referencedApiEndpoint", fields) |> Option.map(Kind.RelationList) |> Option.getWithDefault(Kind.Unsupported("relationList（参照先なし）"))
        case "repeater"     => Map.get("customFieldIds", fields) |> Option.flatMap(asArray) |> Option.map(items -> items |> List.filterMap(asString)) |> Option.map(Kind.Repeater) |> Option.getWithDefault(Kind.Unsupported("repeater（variant なし）"))
        case other          => Kind.Unsupported(other)
    }

    ///
    /// 写せないフィールド（API 名.フィールド名: 種類）。空なら全部写せる。
    ///
    pub def unsupported(api: Api): List[String] =
        (api#fields |> List.filterMap(field -> match field#kind { case Kind.Unsupported(kind) => Some("${api#endpoint}.${field#fieldId}: ${kind}") case _ => None }))
            ::: (api#customFields |> List.flatMap(custom -> custom#fields |> List.filterMap(field -> match field#kind {
                case Kind.Unsupported(kind) => Some("${api#endpoint}.${custom#fieldId}.${field#fieldId}: ${kind}")
                case Kind.Repeater(_)       => Some("${api#endpoint}.${custom#fieldId}.${field#fieldId}: repeater の入れ子")
                case _ => None })))

    def asObject(json: Json): Option[Map[String, Json]] = match json { case Json.JObject(fields) => Some(fields) case _ => None }
    def asArray(json: Json): Option[List[Json]] = match json { case Json.JArray(items) => Some(Vector.toList(items)) case _ => None }
    def asString(json: Json): Option[String] = match json { case Json.JString(text) => Some(text) case _ => None }
    def asBool(json: Json): Option[Bool] = match json { case Json.JBool(value) => Some(value) case _ => None }
    def stringAt(name: String, fields: Map[String, Json]): Option[String] = Map.get(name, fields) |> Option.flatMap(asString)

}
