///
/// microCMS のスキーマをこの CMS の型に写し、ダミーの entry を作って公開する（器の確認用）。
/// 既存のユースケース（ContentTypes / ContentEntries / Assets）だけを通るので、検査も Webhook も通常と同じ。
///
mod MicrocmsImport {

    use Util.Json.Json
    use MicrocmsSchema.Api
    use MicrocmsSchema.Field
    use MicrocmsSchema.Kind
    use Net.HttpRequest
    use Net.HttpResponse

    /// 写した型。endpoint → TypeId。
    pub type alias Types = Map[String, TypeId]

    ///
    /// 全 API の型を作り、フィールドを足す。参照は全部の型を作った後に足す（相互参照と自己参照のため）。
    /// 写せないフィールドがあれば何もせず invalid（1 つずつ path に "schema"、文言に API 名.フィールド名: 種類）。
    ///
    pub def importSchema(apis: List[Api]): Types \ Db + CmsErr + IdGen + Tenant + Session =
        CmsErr.raiseIfAny(apis |> List.flatMap(MicrocmsSchema.unsupported) |> List.map(problem -> Violation.Violation("schema", "写せないフィールド ${problem}")));
        let types = apis |> List.map(api -> (api#endpoint, ContentTypes.create(Session.grant(), typeDraft(api))#id)) |> List.toMap;
        List.forEach(api -> addFields(types, api), apis);
        types

    ///
    /// 型の draft。microCMS のエンドポイント名は複数形とは限らない（"insidesales-feature"）ので、apiId から導いた singular が
    /// 一覧のクエリ名（apiId）と同じになる時は plural を `<apiId>List` にして衝突を避ける。
    ///
    def typeDraft(api: Api): ContentTypeDraft =
        let singular = Naming.deriveSingular(api#apiId);
        let singularQuery = String.toLowerCase(String.takeLeft(1, TypeName.text(singular))) + String.dropLeft(1, TypeName.text(singular));
        let plural = if (singularQuery == ApiId.text(api#apiId)) ApiId.parse("${ApiId.text(api#apiId)}List") else None;
        { apiId = api#apiId, kind = TypeKind.Collection, name = api#endpoint, singular = Some(singular), plural = plural, previewUrl = None, icon = None }

    def addFields(types: Types, api: Api): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let typeId = Map.get(api#endpoint, types) |> Option.getWithDefault(TypeId.TypeId(0i64));
        List.forEach(field -> match field#kind {
            case Kind.Repeater(variants) =>
                let blocks = ContentTypes.addField(Session.grant(), typeId, draftOf(field, FieldKind.Blocks, true, None, None));
                List.forEach(variantId -> match List.find(custom -> custom#fieldId == variantId, api#customFields) {
                    case None => ()
                    case Some(custom) =>
                        let variant = ContentTypes.addField(Session.grant(), typeId, { apiId = apiIdOf(custom#fieldId), name = custom#name, kind = FieldKind.Object, many = false, required = false, unique = false, localized = false, target = None, parent = Some(blocks#id), config = FieldConfig.empty() });
                        // microCMS は custom field と同名の子（serviceValuePoint の中の serviceValuePoint）を許すが、この CMS の apiId は型の中で一意なので、子に Value を付けて逃がす
                        List.forEach(child -> discard ContentTypes.addField(Session.grant(), typeId, leafDraft(types, childRenamed(custom#fieldId, child), Some(variant#id))), custom#fields)
                }, variants)
            case _ => discard ContentTypes.addField(Session.grant(), typeId, leafDraft(types, field, None))
        }, api#fields)

    /// variant と同名の子は `<名前>Value` に改名する。値を作る時も同じ名前にする。
    def childRenamed(variantId: String, child: Field): Field =
        if (child#fieldId == variantId) { fieldId = "${child#fieldId}Value" | child } else child

    /// 子を持たないフィールドの draft。
    def leafDraft(types: Types, field: Field, parent: Option[FieldId]): FieldDraft = match field#kind {
        case Kind.Text              => draftOf(field, FieldKind.Text, false, None, parent)
        case Kind.TextArea          => draftOf(field, FieldKind.TextArea, false, None, parent)
        case Kind.RichEditor        => draftOf(field, FieldKind.RichText, false, None, parent)
        case Kind.Media             => draftOf(field, FieldKind.Asset, false, None, parent)
        case Kind.Boolean           => draftOf(field, FieldKind.Boolean, false, None, parent)
        case Kind.Number            => draftOf(field, FieldKind.Number, false, None, parent)
        case Kind.Date              => draftOf(field, FieldKind.Date, false, None, parent)
        case Kind.Relation(target)     => draftOf(field, FieldKind.Reference, false, Map.get(target, types), parent)
        case Kind.RelationList(target) => draftOf(field, FieldKind.Reference, true, Map.get(target, types), parent)
        case _                      => draftOf(field, FieldKind.Text, false, None, parent)
    }

    /// 子フィールドは required を付けられない（最上位だけ）ので、親があれば落とす。
    def draftOf(field: Field, kind: FieldKind, many: Bool, target: Option[TypeId], parent: Option[FieldId]): FieldDraft =
        { apiId = apiIdOf(field#fieldId), name = field#name, kind = kind, many = many, required = field#required and Option.isEmpty(parent),
          unique = false, localized = false, target = target, parent = parent, config = FieldConfig.empty() }

    /// microCMS の fieldId は lowerCamel なのでそのまま。規則外なら英数字だけにして頭を小文字に。
    def apiIdOf(fieldId: String): ApiId = match ApiId.parse(fieldId) {
        case Some(found) => found
        case None => MicrocmsSchema.apiIdOf(fieldId) |> Option.getWithDefault(ApiId.ApiId("field"))
    }

    // ---- ダミーの entry ----

    ///
    /// 各 API に count 件のダミー entry を作り、参照を張って、全部公開する。ダミーの画像を 1 つ置いて全 media に使う。
    /// 戻りは endpoint → 作った entry の id。
    ///
    pub def seedDummy(apis: List[Api], types: Types, count: Int32): Map[String, List[EntryId]] \ Db + CmsErr + IdGen + Tenant + Session + ObjectStore + Net.Http.Http =
        let asset = placeDummyImage();
        let created = apis |> List.map(api -> {
            let typeId = Map.get(api#endpoint, types) |> Option.getWithDefault(TypeId.TypeId(0i64));
            (api#endpoint, List.range(1, count + 1) |> List.map(n -> ContentEntries.create(Session.grant(), typeId, None, valuesOf(api, asset, Map.empty(), n, false))#id))
        }) |> List.toMap;
        // 参照は全部の entry ができてから張る（相互参照・自己参照のため）
        List.forEach(api -> Map.get(api#endpoint, created) |> Option.getWithDefault(Nil) |> List.forEachWithIndex((index, id) -> {
            let entry = ContentEntries.get(Session.grant(), id);
            discard ContentEntries.update(Session.grant(), id, valuesOf(api, asset, created, index + 1, true), entry#version)
        }), apis);
        List.forEach(api -> Map.get(api#endpoint, created) |> Option.getWithDefault(Nil) |> List.forEach(id -> discard ContentEntries.publish(Session.grant(), id, "microcms-import", true)), apis);
        created

    /// フィールドの値。withReferences が false なら参照のフィールドを入れない（1 回目の作成用）。
    def valuesOf(api: Api, asset: AssetId, created: Map[String, List[EntryId]], n: Int32, withReferences: Bool): EntryData =
        api#fields
            |> List.filterMap(field -> valueOf(api, asset, created, n, withReferences, field) |> Option.map(value -> (apiIdOf(field#fieldId), value)))
            |> List.toMap

    def valueOf(api: Api, asset: AssetId, created: Map[String, List[EntryId]], n: Int32, withReferences: Bool, field: Field): Option[Json] = match field#kind {
        case Kind.Text       => Some(Json.JString("${field#name} ${n}"))
        case Kind.TextArea   => Some(Json.JString("${field#name} ${n} の 1 行目\n2 行目"))
        case Kind.RichEditor => Some(richTextDoc(field#name, n, asset))
        case Kind.Media      => Some(Json.JString(AssetId.text(asset)))
        case Kind.Boolean    => Some(Json.JBool(Int32.remainder(n, 2) == 0))
        case Kind.Number     => Some(Json.JNumber(Int32.toBigDecimal(n)))
        case Kind.Date       => Some(Json.JString("2026-09-${String.padLeft(2, '0', "${Int32.remainder(n - 1, 28) + 1}")}T00:00:00Z"))
        case Kind.Relation(target) =>
            if (withReferences) Map.get(target, created) |> Option.flatMap(List.head) |> Option.map(id -> Json.JString(EntryId.text(id))) else None
        case Kind.RelationList(target) =>
            if (withReferences) Map.get(target, created) |> Option.map(ids -> Json.JArray(ids |> List.take(2) |> List.map(id -> Json.JString(EntryId.text(id))) |> List.toVector)) else None
        case Kind.Repeater(variants) =>
            let blocks = variants |> List.filterMap(variantId -> List.find(custom -> custom#fieldId == variantId, api#customFields)) |> List.map(custom ->
                Json.JObject(Map.insert("blockType", Json.JString(ApiId.text(apiIdOf(custom#fieldId))),
                    custom#fields |> List.map(childRenamed(custom#fieldId)) |> List.filterMap(child -> valueOf(api, asset, created, n, withReferences, child) |> Option.map(value -> (ApiId.text(apiIdOf(child#fieldId)), value))) |> List.toMap)));
            Some(Json.JArray(List.toVector(blocks)))
        case Kind.Unsupported(_) => None
    }

    /// 見出し・段落（太字とリンク）・箇条書き・画像を持つ doc。
    def richTextDoc(name: String, n: Int32, asset: AssetId): Json =
        let text = (value, marks) -> Json.JObject(Map#{ "type" => Json.JString("text"), "text" => Json.JString(value), "marks" => Json.JArray(List.toVector(marks)) });
        let mark = (kind, attrs) -> Json.JObject(Map#{ "type" => Json.JString(kind), "attrs" => Json.JObject(attrs) });
        let node = (kind, attrs, content) -> Json.JObject(Map#{ "type" => Json.JString(kind), "attrs" => Json.JObject(attrs), "content" => Json.JArray(List.toVector(content)) });
        node("doc", Map.empty(), List#{
            node("heading", Map#{ "level" => Json.JNumber(Int32.toBigDecimal(2)) }, List#{ text("${name} ${n} の見出し", Nil) }),
            node("paragraph", Map.empty(), List#{
                text("本文の段落です。", Nil),
                text("太字", mark("bold", Map.empty()) :: Nil),
                text("とリンク", mark("link", Map#{ "href" => Json.JString("https://example.com/") }) :: Nil) }),
            node("bulletList", Map.empty(), List#{
                node("listItem", Map.empty(), List#{ node("paragraph", Map.empty(), List#{ text("一つ目", Nil) }) }),
                node("listItem", Map.empty(), List#{ node("paragraph", Map.empty(), List#{ text("二つ目", Nil) }) }) }),
            node("image", Map#{ "assetId" => Json.JString(AssetId.text(asset)), "alt" => Json.JString("ダミー画像") }, Nil)
        })

    /// ダミーの画像を 1 つ置いて READY にする。中身は PNG ではなく短い文字列（器の確認なので描画はしない）。
    def placeDummyImage(): AssetId \ Db + CmsErr + IdGen + Tenant + Session + ObjectStore + Net.Http.Http =
        let body = "dummy";
        let upload = Assets.createUpload(Session.grant(), { fileName = "dummy.png", mime = "image/png", size = Int32.toInt64(String.length(body)) });
        match Net.Http.send(HttpRequest.put(upload#uploadUrl, body) |> HttpRequest.withContentType("image/png")) {
            case Ok(response) if HttpResponse.isSuccess(response) => ()
            case Ok(response) => CmsErr.invalid(Violation.Violation("asset", "ダミー画像を置けません（HTTP ${HttpResponse.status(response)}）") :: Nil)
            case Err(error)   => CmsErr.invalid(Violation.Violation("asset", "ダミー画像を置けません: ${error}") :: Nil)
        };
        Assets.confirm(Session.grant(), upload#asset#id, { width = Some(1), height = Some(1), alt = Some("ダミー画像") })#id

}
