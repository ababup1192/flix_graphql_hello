///
/// content_types / content_fields の行と、ドメインの値のあいだの変換。kind の文字列と id の包み直し。
/// 行の形は生成された ContentTypesQueries / ContentFieldsQueries の物で、ここだけが列名を知る。
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

    ///
    /// content_types の行とそのフィールドから ContentType を組む。
    /// kind や apiId が規則に合わない行（DDL と管理 API が守るので起きない）は DbErr にする。
    ///
    pub def toContentType(row: { id = Int64, apiId = String, kind = String, name = String, singular = String, plural = String, previewUrl = String, createdAt = Timestamp.Timestamp, updatedAt = Timestamp.Timestamp | r }, fields: List[FieldDef]): ContentType \ DbErr =
        {
            id         = TypeId.TypeId(row#id),
            apiId      = apiIdOrRaise("content_types.api_id", row#apiId),
            kind       = typeKindFromDb(row#kind) |> orRaise("content_types.kind", row#kind),
            name       = row#name,
            singular   = TypeName.parse(row#singular) |> orRaise("content_types.singular", row#singular),
            plural     = apiIdOrRaise("content_types.plural", row#plural),
            previewUrl = if (row#previewUrl == "") None else Some(row#previewUrl),
            fields     = fields |> List.sortBy(field -> field#position),
            createdAt  = row#createdAt,
            updatedAt  = row#updatedAt
        }

    ///
    /// content_fields の行から FieldDef を組む。
    ///
    pub def toFieldDef(row: { id = Int64, typeId = Int64, parentFieldId = Option[Int64], apiId = String, name = String, kind = String, isMany = Bool, isRequired = Bool, isUnique = Bool, isLocalized = Bool, targetTypeId = Option[Int64], config = Json, position = Int32 | r }): FieldDef \ DbErr =
        {
            id        = FieldId.FieldId(row#id),
            typeId    = TypeId.TypeId(row#typeId),
            apiId     = apiIdOrRaise("content_fields.api_id", row#apiId),
            name      = row#name,
            kind      = fieldKindFromDb(row#kind) |> orRaise("content_fields.kind", row#kind),
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

    ///
    /// 平らな行の並びを木にする。最上位（parent 無し）を position 順に並べ、子は再帰で付ける。
    ///
    pub def toTree(flat: List[FieldDef]): List[FieldDef] =
        childrenOf(flat, None)

    def childrenOf(flat: List[FieldDef], parent: Option[FieldId]): List[FieldDef] =
        flat |> List.filter(field -> field#parent == parent)
            |> List.sortBy(field -> field#position)
            |> List.map(field -> { children = Children.Children(childrenOf(flat, Some(field#id))) | field })

    ///
    /// 木の中から id で探す（深さ問わず）。
    ///
    pub def findInTree(id: FieldId, tree: List[FieldDef]): Option[FieldDef] =
        tree |> List.findMap(field -> if (field#id == id) Some(field) else findInTree(id, Children.toList(field#children)))

    ///
    /// 木を平らにする（深さ優先）。
    ///
    pub def flatten(tree: List[FieldDef]): List[FieldDef] =
        tree |> List.flatMap(field -> field :: flatten(Children.toList(field#children)))

    def apiIdOrRaise(column: String, text: String): ApiId \ DbErr =
        ApiId.parse(text) |> orRaise(column, text)

    ///
    /// 行の値が読めない。DB に規則外の値が入っている事なので DbErr。
    ///
    def orRaise(column: String, text: String, value: Option[a]): a \ DbErr = match value {
        case Some(found) => found
        case None        => DbErr.other("${column} の値が読めません: ${text}")
    }

}
