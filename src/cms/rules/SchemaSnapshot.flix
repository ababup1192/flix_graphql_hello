///
/// 変更前のスキーマを JSON にする／JSON から足し直す下書きに戻す。純粋。
///
/// 監査（`audit_events.detail`）に残すのはこの形で、消したフィールドや型を後から組み直すのに要る物が
/// 全部入る。`toDraft` が逆向きなので、残した物で本当に戻せるかを往復のテストで確かめられる。
///
/// WhyNot: 内部の連番（`content_fields.id` / `content_types.id`）を入れない。消した行の id は
/// 二度と使えないので戻すのに使えず、監査を読む人にも意味が無い。参照先は apiId で持つ。
///
/// WhyNot: kind の綴りを別に持たない。`ContentTypeRows` が DB に書く綴りと同じ物を使えば、
/// 監査の JSON と `content_fields.kind` の値が食い違わない。
///
mod SchemaSnapshot {

    use Util.Json.Json

    ///
    /// 変更前のフィールド 1 本。子も一緒に持つ（親を消すと子も消えるため）。
    ///
    pub def ofField(names: Map[TypeId, ApiId], field: FieldDef): Json =
        let base =
            ("apiId", Json.JString(ApiId.text(field#apiId))) ::
            ("name", Json.JString(field#name)) ::
            ("kind", Json.JString(ContentTypeRows.fieldKindToDb(field#kind))) ::
            ("many", Json.JBool(field#many)) ::
            ("required", Json.JBool(field#required)) ::
            ("unique", Json.JBool(field#unique)) ::
            ("localized", Json.JBool(field#localized)) ::
            ("config", FieldConfig.toJson(field#config)) ::
            Nil;
        let target = match field#target |> Option.flatMap(id -> Map.get(id, names)) {
            case Some(apiId) => ("target", Json.JString(ApiId.text(apiId))) :: Nil
            case None        => Nil
        };
        let children = match Children.toList(field#children) {
            case Nil  => Nil
            case kids => ("children", Json.JArray(kids |> List.map(kid -> ofField(names, kid)) |> List.toVector)) :: Nil
        };
        Json.JObject(List.toMap(base ::: target ::: children))

    ///
    /// 変更前の型の見出しだけ（フィールドは持たない）。名前や previewUrl を上書きした時に残す。
    ///
    pub def ofType(owner: ContentType): Json =
        let base =
            ("apiId", Json.JString(ApiId.text(owner#apiId))) ::
            ("kind", Json.JString(ContentTypeRows.typeKindToDb(owner#kind))) ::
            ("name", Json.JString(owner#name)) ::
            ("singular", Json.JString(TypeName.text(owner#singular))) ::
            ("plural", Json.JString(ApiId.text(owner#plural))) ::
            ("icon", Json.JString(owner#icon)) ::
            Nil;
        Json.JObject(List.toMap(base ::: optional("previewUrl", owner#previewUrl) ::: optional("linkPath", owner#linkPath)))

    ///
    /// 変更前の型とフィールド全部。型を消した時に残す。
    ///
    pub def ofTypeWithFields(names: Map[TypeId, ApiId], owner: ContentType): Json =
        let head = match ofType(owner) {
            case Json.JObject(map) => map
            case _                 => Map.empty()
        };
        let fields = Json.JArray(owner#fields |> List.map(field -> ofField(names, field)) |> List.toVector);
        Json.JObject(Map.insert("fields", fields, head))

    ///
    /// 変更前の最上位の並び。並べ替えを元に戻すのに要るのは apiId の列だけ。
    ///
    pub def ofOrder(fields: List[FieldDef]): Json =
        Json.JObject(Map#{ "fields" => Json.JArray(fields |> List.map(field -> Json.JString(ApiId.text(field#apiId))) |> List.toVector) })

    ///
    /// 残した JSON から、足し直す下書きに戻す。apiId と kind が読めなければ None。
    ///
    /// parent は持たない。入れ子を戻す時は、親を先に足してから子の `parent` を呼ぶ側が付ける。
    ///
    pub def toDraft(ids: Map[ApiId, TypeId], json: Json): Option[FieldDraft] =
        let fields = match json {
            case Json.JObject(map) => map
            case _                 => Map.empty()
        };
        let flag = (key, fallback) -> Map.get(key, fields) |> Option.flatMap(EntryValue.asBool) |> Option.getWithDefault(fallback);
        forM (
            apiId <- Map.get("apiId", fields) |> Option.flatMap(EntryValue.asString) |> Option.flatMap(ApiId.parse);
            kind  <- Map.get("kind", fields) |> Option.flatMap(EntryValue.asString) |> Option.flatMap(ContentTypeRows.fieldKindFromDb)
        ) yield {
            apiId     = apiId,
            name      = Map.get("name", fields) |> Option.flatMap(EntryValue.asString) |> Option.getWithDefault(ApiId.text(apiId)),
            kind      = kind,
            many      = flag("many", false),
            required  = flag("required", false),
            unique    = flag("unique", false),
            localized = flag("localized", false),
            target    = Map.get("target", fields) |> Option.flatMap(EntryValue.asString) |> Option.flatMap(ApiId.parse) |> Option.flatMap(apiId2 -> Map.get(apiId2, ids)),
            parent    = None,
            config    = Map.get("config", fields) |> Option.map(FieldConfig.fromJson) |> Option.getWithDefault(FieldConfig.empty())
        }

    ///
    /// 今あるフィールドを、足し直す下書きの形に落とす。往復の突き合わせに使う。
    ///
    pub def draftOf(field: FieldDef): FieldDraft =
        { apiId = field#apiId, name = field#name, kind = field#kind, many = field#many, required = field#required,
          unique = field#unique, localized = field#localized, target = field#target, parent = None, config = field#config }

    /// 無ければキーごと出さない項目。
    def optional(key: String, value: Option[String]): List[(String, Json)] = match value {
        case Some(text) => (key, Json.JString(text)) :: Nil
        case None       => Nil
    }

}
