///
/// content_types / content_fields の行と、ドメインの値のあいだの変換。kind の文字列、id の包み直し、
/// INSERT の引数と UPDATE の Changes。行の形は生成された ContentTypesQueries / ContentFieldsQueries の物で、ここだけが列名を知る。
///
mod ContentTypeRows {

    use Util.Json.Json

    ///
    /// content_types.kind の値。CHECK 制約の文字列と揃える。
    ///
    pub def typeKindToDb(kind: TypeKind): String = match kind {
        case TypeKind.Collection => "collection"
        case TypeKind.Singleton  => "singleton"
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
        case FieldKind.Select   => "select"
        case FieldKind.Reference => "reference"
        case FieldKind.Object   => "object"
        case FieldKind.Blocks   => "blocks"
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
    /// content_fields.kind の値から。知らない文字列は None。
    ///
    pub def fieldKindFromDb(text: String): Option[FieldKind] = match text {
        case "text"     => Some(FieldKind.Text)
        case "textArea" => Some(FieldKind.TextArea)
        case "slug"     => Some(FieldKind.Slug)
        case "number"   => Some(FieldKind.Number)
        case "boolean"  => Some(FieldKind.Boolean)
        case "select"   => Some(FieldKind.Select)
        case "reference" => Some(FieldKind.Reference)
        case "object"   => Some(FieldKind.Object)
        case "blocks"   => Some(FieldKind.Blocks)
        case _          => None
    }

    // ---- 行 → 値 ----

    ///
    /// content_types の行とそのフィールド（木）から ContentType を組む。
    /// kind や apiId が規則に合わない行（DDL と管理 API が守るので起きない）は DbErr にする。
    ///
    pub def toContentType(row: { id = Int64, apiId = String, kind = String, name = String, singular = String, plural = String, previewUrl = String, createdAt = Timestamp.Timestamp, updatedAt = Timestamp.Timestamp | r }, fields: List[FieldDef]): ContentType \ DbErr =
        {
            id         = TypeId.TypeId(row#id),
            apiId      = apiIdOrRaise("content_types.api_id", row#apiId),
            kind       = typeKindFromDb(row#kind) |> Rows.orRaise("content_types.kind", row#kind),
            name       = row#name,
            singular   = TypeName.parse(row#singular) |> Rows.orRaise("content_types.singular", row#singular),
            plural     = apiIdOrRaise("content_types.plural", row#plural),
            previewUrl = previewUrlFromDb(row#previewUrl),
            fields     = fields,
            createdAt  = row#createdAt,
            updatedAt  = row#updatedAt
        }

    ///
    /// content_types の行の id。
    ///
    pub def typeIdOf(row: { id = Int64 | r }): TypeId = TypeId.TypeId(row#id)

    ///
    /// content_fields の行から FieldDef を組む。children は空（木にするのは FieldTree.build）。
    ///
    pub def toFieldDef(row: { id = Int64, typeId = Int64, parentFieldId = Option[Int64], apiId = String, name = String, kind = String, isMany = Bool, isRequired = Bool, isUnique = Bool, isLocalized = Bool, targetTypeId = Option[Int64], config = Json, position = Int32 | r }): FieldDef \ DbErr =
        {
            id        = FieldId.FieldId(row#id),
            typeId    = TypeId.TypeId(row#typeId),
            apiId     = apiIdOrRaise("content_fields.api_id", row#apiId),
            name      = row#name,
            kind      = fieldKindFromDb(row#kind) |> Rows.orRaise("content_fields.kind", row#kind),
            many      = row#isMany,
            required  = row#isRequired,
            unique    = row#isUnique,
            localized = row#isLocalized,
            target    = row#targetTypeId |> Option.map(TypeId.TypeId),
            parent    = row#parentFieldId |> Option.map(FieldId.FieldId),
            children  = Children.none(),
            config    = FieldConfig.fromJson(row#config),
            position  = row#position
        }

    // ---- 値 → 行 ----

    ///
    /// insertContentType の引数。
    ///
    pub def typeInsert(names: Naming.TypeNames, draft: ContentTypeDraft): { apiId = String, kind = String, name = String, singular = String, plural = String, previewUrl = String } =
        {
            apiId      = ApiId.text(names#apiId),
            kind       = typeKindToDb(draft#kind),
            name       = draft#name,
            singular   = TypeName.text(names#singular),
            plural     = ApiId.text(names#plural),
            previewUrl = previewUrlToDb(draft#previewUrl)
        }

    ///
    /// updateContentType の Changes。None の項目は SET に出ない。
    ///
    pub def typeChanges(changes: ContentTypeChanges): Fragment.Changes[ContentTypesTable.ContentTypesTable] =
        Fragment.noChange()
            |> Fragment.setIfSome(ContentTypesTable.name(), changes#name)
            |> Fragment.setIfSome(ContentTypesTable.singular(), changes#singular |> Option.map(TypeName.text))
            |> Fragment.setIfSome(ContentTypesTable.plural(), changes#plural |> Option.map(ApiId.text))
            |> Fragment.setIfSome(ContentTypesTable.previewUrl(), changes#previewUrl)

    ///
    /// insertField の引数。target と parent は後追いの UPDATE（setFieldTarget / setFieldParent）で入れる。
    ///
    pub def fieldInsert(typeId: TypeId, position: Int32, draft: FieldDraft): { typeId = Int64, apiId = String, name = String, kind = String, isMany = Bool, isRequired = Bool, isUnique = Bool, isLocalized = Bool, config = Json, position = Int32 } =
        {
            typeId      = TypeId.toInt64(typeId),
            apiId       = ApiId.text(draft#apiId),
            name        = draft#name,
            kind        = fieldKindToDb(draft#kind),
            isMany      = draft#many,
            isRequired  = draft#required,
            isUnique    = draft#unique,
            isLocalized = draft#localized,
            config      = FieldConfig.toJson(draft#config),
            position    = position
        }

    ///
    /// updateField の Changes。config は丸ごと置き換える。
    ///
    pub def fieldChanges(changes: FieldChanges): Fragment.Changes[ContentFieldsTable.ContentFieldsTable] =
        Fragment.noChange()
            |> Fragment.setIfSome(ContentFieldsTable.name(), changes#name)
            |> Fragment.setIfSome(ContentFieldsTable.isRequired(), changes#required)
            |> Fragment.setIfSome(ContentFieldsTable.isUnique(), changes#unique)
            |> Fragment.setIfSome(ContentFieldsTable.isLocalized(), changes#localized)
            |> Fragment.setIfSome(ContentFieldsTable.config(), changes#config |> Option.map(FieldConfig.toJson))

    ///
    /// content_types.preview_url は NOT NULL で、無しは空文字。INSERT と読みで対にする（UPDATE は渡された文字列をそのまま置く。消すなら ""）。
    ///
    def previewUrlToDb(url: Option[String]): String = url |> Option.getWithDefault("")

    def previewUrlFromDb(text: String): Option[String] = if (text == "") None else Some(text)

    def apiIdOrRaise(column: String, text: String): ApiId \ DbErr =
        ApiId.parse(text) |> Rows.orRaise(column, text)

}
