///
/// SDL から schemagen が生成したファイル。手で編集しない（`make generate` で作り直す）。
///
mod GeneratedAdmin {

    /// 生成元の SDL 本文（改行は LF）。GeneratedCheck が SDL ファイルと照合する
    pub def sdlText(): String = "\"\"\"任意の JSON 値。entry の中身（フィールドの apiId → 値）に使う\"\"\"\nscalar JSON\n\n\"\"\"管理 API。content type とフィールドの定義と、entry を読み書きする。形は固定で、コンテンツ API は定義から実行時に組む\"\"\"\ntype Query {\n  \"\"\"全 content type。apiId 順\"\"\"\n  contentTypes: [ContentType!]!\n  \"\"\"id か apiId で 1 つ。無ければ null\"\"\"\n  contentType(id: ID, apiId: String): ContentType\n  \"\"\"型の entry の一覧。更新が新しい順。search は下書きの中身に含む文字列\"\"\"\n  entries(typeId: ID!, search: String, first: Int = 50, skip: Int = 0): EntryPage!\n  \"\"\"entry 1 つ。無ければ null\"\"\"\n  entry(id: ID!): Entry\n}\n\ntype Mutation {\n  createContentType(input: ContentTypeInput!): ContentType!\n  updateContentType(id: ID!, input: ContentTypePatch!): ContentType!\n  \"\"\"フィールドごと消す\"\"\"\n  deleteContentType(id: ID!): ID!\n  \"\"\"末尾に足す\"\"\"\n  addField(typeId: ID!, input: FieldInput!): FieldDef!\n  updateField(id: ID!, input: FieldPatch!): FieldDef!\n  removeField(id: ID!): ID!\n  \"\"\"ids の順に並べ直す。型の全フィールドを過不足なく渡す\"\"\"\n  reorderFields(typeId: ID!, ids: [ID!]!): ContentType!\n\n  \"\"\"下書きを作る。id を渡せば（移行用）それを使い、無ければ振る。fields は apiId → 値\"\"\"\n  createEntry(typeId: ID!, fields: JSON!, id: ID): Entry!\n  \"\"\"下書きを直す。fields のキーだけ上書きし、null で消す。expectedVersion が今の version と違えば CONFLICT\"\"\"\n  updateEntry(id: ID!, fields: JSON!, expectedVersion: Int!): Entry!\n  \"\"\"ゴミ箱へ（soft delete）\"\"\"\n  deleteEntry(id: ID!): ID!\n}\n\n\"\"\"entry の状態\"\"\"\nenum EntryStage {\n  \"\"\"まだ公開していない\"\"\"\n  DRAFT\n  \"\"\"公開中\"\"\"\n  PUBLISHED\n}\n\n\"\"\"entry。fields は下書きの中身\"\"\"\ntype Entry {\n  id: ID!\n  typeId: ID!\n  \"\"\"楽観ロックの版。updateEntry に expectedVersion として渡す\"\"\"\n  version: Int!\n  stage: EntryStage!\n  fields: JSON!\n  publishedAt: String\n  createdAt: String!\n  updatedAt: String!\n}\n\n\"\"\"entry の一覧の 1 ページ\"\"\"\ntype EntryPage {\n  nodes: [Entry!]!\n  totalCount: Int!\n}\n\n\"\"\"content type の種別\"\"\"\nenum TypeKind {\n  \"\"\"entry を何件でも持つ\"\"\"\n  COLLECTION\n  \"\"\"entry を 1 件だけ持つ（サイト設定など）\"\"\"\n  SINGLETON\n}\n\n\"\"\"フィールドの種類\"\"\"\nenum FieldKind {\n  TEXT\n  TEXT_AREA\n  \"\"\"URL に使う識別子。sourceField から自動生成し、型の中で一意\"\"\"\n  SLUG\n  NUMBER\n  BOOLEAN\n}\n\n\"\"\"content type。apiId がコンテンツ API のクエリ名の元になる\"\"\"\ntype ContentType {\n  id: ID!\n  \"\"\"lowerCamel の識別子（\"blogs\"）\"\"\"\n  apiId: String!\n  kind: TypeKind!\n  \"\"\"管理画面に出す名前\"\"\"\n  name: String!\n  \"\"\"コンテンツ API の型名（\"Blog\"）\"\"\"\n  singular: String!\n  \"\"\"コンテンツ API の一覧クエリ名（\"blogs\"）\"\"\"\n  plural: String!\n  \"\"\"管理画面のプレビューが開く URL。{id} を entry の id に置き換える\"\"\"\n  previewUrl: String\n  \"\"\"position 順\"\"\"\n  fields: [FieldDef!]!\n  createdAt: String!\n  updatedAt: String!\n}\n\n\"\"\"フィールドの定義\"\"\"\ntype FieldDef {\n  id: ID!\n  apiId: String!\n  name: String!\n  kind: FieldKind!\n  \"\"\"配列か\"\"\"\n  many: Boolean!\n  \"\"\"公開時に値が要るか\"\"\"\n  required: Boolean!\n  \"\"\"型の中で値が一意か\"\"\"\n  unique: Boolean!\n  \"\"\"言語ごとに値を持つか\"\"\"\n  localized: Boolean!\n  config: FieldConfig!\n  position: Int!\n}\n\n\"\"\"kind ごとの設定。使わない項目は null\"\"\"\ntype FieldConfig {\n  \"\"\"TEXT / TEXT_AREA / SLUG の最大文字数\"\"\"\n  maxLength: Int\n  \"\"\"SLUG の元にするフィールドの apiId\"\"\"\n  sourceField: String\n  \"\"\"NUMBER の下限\"\"\"\n  min: Float\n  \"\"\"NUMBER の上限\"\"\"\n  max: Float\n  \"\"\"NUMBER を整数に限るか\"\"\"\n  integer: Boolean\n}\n\ninput ContentTypeInput {\n  apiId: String!\n  kind: TypeKind = COLLECTION\n  name: String!\n  \"\"\"省くと apiId から導く\"\"\"\n  singular: String\n  \"\"\"省くと apiId から導く\"\"\"\n  plural: String\n  previewUrl: String\n}\n\n\"\"\"触らない項目は省く\"\"\"\ninput ContentTypePatch {\n  name: String\n  singular: String\n  plural: String\n  previewUrl: String\n}\n\ninput FieldInput {\n  apiId: String!\n  name: String!\n  kind: FieldKind!\n  many: Boolean = false\n  required: Boolean = false\n  unique: Boolean = false\n  localized: Boolean = false\n  config: FieldConfigInput\n}\n\n\"\"\"触らない項目は省く。config は丸ごと置き換える\"\"\"\ninput FieldPatch {\n  name: String\n  required: Boolean\n  unique: Boolean\n  localized: Boolean\n  config: FieldConfigInput\n}\n\ninput FieldConfigInput {\n  maxLength: Int\n  sourceField: String\n  min: Float\n  max: Float\n  integer: Boolean\n}\n"

    /// 生成した schemagen のバージョン
    pub def generatorVersion(): String = "6"

    /// enum EntryStage。entry の状態
    pub enum EntryStage with Eq, Order, ToString {
        /// まだ公開していない
        case Draft
        /// 公開中
        case Published
    }

    /// EntryStage の Codec
    pub def entryStageCodec(): GqlCodec[EntryStage] =
        GqlCodec.enumOf("EntryStage", value -> match value { case EntryStage.Draft => "DRAFT" case EntryStage.Published => "PUBLISHED" }, EntryStage.Draft :: EntryStage.Published :: Nil) |> GqlCodec.describe("entry の状態") |> GqlCodec.describeValue(EntryStage.Draft, "まだ公開していない") |> GqlCodec.describeValue(EntryStage.Published, "公開中")

    /// enum TypeKind。content type の種別
    pub enum TypeKind with Eq, Order, ToString {
        /// entry を何件でも持つ
        case Collection
        /// entry を 1 件だけ持つ（サイト設定など）
        case Singleton
    }

    /// TypeKind の Codec
    pub def typeKindCodec(): GqlCodec[TypeKind] =
        GqlCodec.enumOf("TypeKind", value -> match value { case TypeKind.Collection => "COLLECTION" case TypeKind.Singleton => "SINGLETON" }, TypeKind.Collection :: TypeKind.Singleton :: Nil) |> GqlCodec.describe("content type の種別") |> GqlCodec.describeValue(TypeKind.Collection, "entry を何件でも持つ") |> GqlCodec.describeValue(TypeKind.Singleton, "entry を 1 件だけ持つ（サイト設定など）")

    /// enum FieldKind。フィールドの種類
    pub enum FieldKind with Eq, Order, ToString {
        /// TEXT
        case Text
        /// TEXT_AREA
        case TextArea
        /// URL に使う識別子。sourceField から自動生成し、型の中で一意
        case Slug
        /// NUMBER
        case Number
        /// BOOLEAN
        case Boolean
    }

    /// FieldKind の Codec
    pub def fieldKindCodec(): GqlCodec[FieldKind] =
        GqlCodec.enumOf("FieldKind", value -> match value { case FieldKind.Text => "TEXT" case FieldKind.TextArea => "TEXT_AREA" case FieldKind.Slug => "SLUG" case FieldKind.Number => "NUMBER" case FieldKind.Boolean => "BOOLEAN" }, FieldKind.Text :: FieldKind.TextArea :: FieldKind.Slug :: FieldKind.Number :: FieldKind.Boolean :: Nil) |> GqlCodec.describe("フィールドの種類") |> GqlCodec.describeValue(FieldKind.Slug, "URL に使う識別子。sourceField から自動生成し、型の中で一意")

    /// input ContentTypeInput
    pub type alias ContentTypeInput = { apiId = String, kind = Option[TypeKind], name = String, singular = Option[String], plural = Option[String], previewUrl = Option[String] }

    /// ContentTypeInput の Codec
    pub def contentTypeInputCodec(): GqlCodec[ContentTypeInput] =
        let f0 = Schema.arg("apiId", GqlCodec.string());
        let f1 = Schema.arg("kind", GqlCodec.option(typeKindCodec())) |> Arg.withDefaultValue(Value.Str("COLLECTION"));
        let f2 = Schema.arg("name", GqlCodec.string());
        let f3 = Schema.arg("singular", GqlCodec.option(GqlCodec.string())) |> Arg.withDescription("省くと apiId から導く");
        let f4 = Schema.arg("plural", GqlCodec.option(GqlCodec.string())) |> Arg.withDescription("省くと apiId から導く");
        let f5 = Schema.arg("previewUrl", GqlCodec.option(GqlCodec.string()));
        GqlCodec.inputObject("ContentTypeInput", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Arg.info(f4) :: Arg.info(f5) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields); v4 <- Arg.decodeField(f4, fields); v5 <- Arg.decodeField(f5, fields)) yield { apiId = v0, kind = v1, name = v2, singular = v3, plural = v4, previewUrl = v5 })

    /// input ContentTypePatch
    pub type alias ContentTypePatch = { name = Option[String], singular = Option[String], plural = Option[String], previewUrl = Option[String] }

    /// ContentTypePatch の Codec
    pub def contentTypePatchCodec(): GqlCodec[ContentTypePatch] =
        let f0 = Schema.arg("name", GqlCodec.option(GqlCodec.string()));
        let f1 = Schema.arg("singular", GqlCodec.option(GqlCodec.string()));
        let f2 = Schema.arg("plural", GqlCodec.option(GqlCodec.string()));
        let f3 = Schema.arg("previewUrl", GqlCodec.option(GqlCodec.string()));
        GqlCodec.inputObject("ContentTypePatch", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields)) yield { name = v0, singular = v1, plural = v2, previewUrl = v3 }) |> GqlCodec.describe("触らない項目は省く")

    /// input FieldInput
    pub type alias FieldInput = { apiId = String, name = String, kind = FieldKind, many = Option[Bool], required = Option[Bool], unique = Option[Bool], localized = Option[Bool], config = Option[FieldConfigInput] }

    /// FieldInput の Codec
    pub def fieldInputCodec(): GqlCodec[FieldInput] =
        let f0 = Schema.arg("apiId", GqlCodec.string());
        let f1 = Schema.arg("name", GqlCodec.string());
        let f2 = Schema.arg("kind", fieldKindCodec());
        let f3 = Schema.arg("many", GqlCodec.option(GqlCodec.bool())) |> Arg.withDefaultValue(Value.Bool(false));
        let f4 = Schema.arg("required", GqlCodec.option(GqlCodec.bool())) |> Arg.withDefaultValue(Value.Bool(false));
        let f5 = Schema.arg("unique", GqlCodec.option(GqlCodec.bool())) |> Arg.withDefaultValue(Value.Bool(false));
        let f6 = Schema.arg("localized", GqlCodec.option(GqlCodec.bool())) |> Arg.withDefaultValue(Value.Bool(false));
        let f7 = Schema.arg("config", GqlCodec.option(fieldConfigInputCodec()));
        GqlCodec.inputObject("FieldInput", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Arg.info(f4) :: Arg.info(f5) :: Arg.info(f6) :: Arg.info(f7) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields); v4 <- Arg.decodeField(f4, fields); v5 <- Arg.decodeField(f5, fields); v6 <- Arg.decodeField(f6, fields); v7 <- Arg.decodeField(f7, fields)) yield { apiId = v0, name = v1, kind = v2, many = v3, required = v4, unique = v5, localized = v6, config = v7 })

    /// input FieldPatch
    pub type alias FieldPatch = { name = Option[String], required = Option[Bool], unique = Option[Bool], localized = Option[Bool], config = Option[FieldConfigInput] }

    /// FieldPatch の Codec
    pub def fieldPatchCodec(): GqlCodec[FieldPatch] =
        let f0 = Schema.arg("name", GqlCodec.option(GqlCodec.string()));
        let f1 = Schema.arg("required", GqlCodec.option(GqlCodec.bool()));
        let f2 = Schema.arg("unique", GqlCodec.option(GqlCodec.bool()));
        let f3 = Schema.arg("localized", GqlCodec.option(GqlCodec.bool()));
        let f4 = Schema.arg("config", GqlCodec.option(fieldConfigInputCodec()));
        GqlCodec.inputObject("FieldPatch", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Arg.info(f4) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields); v4 <- Arg.decodeField(f4, fields)) yield { name = v0, required = v1, unique = v2, localized = v3, config = v4 }) |> GqlCodec.describe("触らない項目は省く。config は丸ごと置き換える")

    /// input FieldConfigInput
    pub type alias FieldConfigInput = { maxLength = Option[Int32], sourceField = Option[String], min = Option[Float64], max = Option[Float64], integer = Option[Bool] }

    /// FieldConfigInput の Codec
    pub def fieldConfigInputCodec(): GqlCodec[FieldConfigInput] =
        let f0 = Schema.arg("maxLength", GqlCodec.option(GqlCodec.int32()));
        let f1 = Schema.arg("sourceField", GqlCodec.option(GqlCodec.string()));
        let f2 = Schema.arg("min", GqlCodec.option(GqlCodec.float64()));
        let f3 = Schema.arg("max", GqlCodec.option(GqlCodec.float64()));
        let f4 = Schema.arg("integer", GqlCodec.option(GqlCodec.bool()));
        GqlCodec.inputObject("FieldConfigInput", Arg.info(f0) :: Arg.info(f1) :: Arg.info(f2) :: Arg.info(f3) :: Arg.info(f4) :: Nil, fields ->
            forM (v0 <- Arg.decodeField(f0, fields); v1 <- Arg.decodeField(f1, fields); v2 <- Arg.decodeField(f2, fields); v3 <- Arg.decodeField(f3, fields); v4 <- Arg.decodeField(f4, fields)) yield { maxLength = v0, sourceField = v1, min = v2, max = v3, integer = v4 })

    /// Query.contentTypes
    pub type alias QueryContentTypesResolver[ef: Eff] = Context -> Result[FieldError, List[ContentType]] \ ef
    /// Query.contentType
    pub type alias QueryContentTypeResolver[ef: Eff] = Context -> Option[Id] -> Option[String] -> Result[FieldError, Option[ContentType]] \ ef
    /// Query.entries
    pub type alias QueryEntriesResolver[ef: Eff] = Context -> Id -> Option[String] -> Option[Int32] -> Option[Int32] -> Result[FieldError, EntryPage] \ ef
    /// Query.entry
    pub type alias QueryEntryResolver[ef: Eff] = Context -> Id -> Result[FieldError, Option[Entry]] \ ef
    /// Mutation.createContentType
    pub type alias MutationCreateContentTypeResolver[ef: Eff] = Context -> ContentTypeInput -> Result[FieldError, ContentType] \ ef
    /// Mutation.updateContentType
    pub type alias MutationUpdateContentTypeResolver[ef: Eff] = Context -> Id -> ContentTypePatch -> Result[FieldError, ContentType] \ ef
    /// Mutation.deleteContentType
    pub type alias MutationDeleteContentTypeResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Mutation.addField
    pub type alias MutationAddFieldResolver[ef: Eff] = Context -> Id -> FieldInput -> Result[FieldError, FieldDef] \ ef
    /// Mutation.updateField
    pub type alias MutationUpdateFieldResolver[ef: Eff] = Context -> Id -> FieldPatch -> Result[FieldError, FieldDef] \ ef
    /// Mutation.removeField
    pub type alias MutationRemoveFieldResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Mutation.reorderFields
    pub type alias MutationReorderFieldsResolver[ef: Eff] = Context -> Id -> List[Id] -> Result[FieldError, ContentType] \ ef
    /// Mutation.createEntry
    pub type alias MutationCreateEntryResolver[ef: Eff] = Context -> Id -> Value -> Option[Id] -> Result[FieldError, Entry] \ ef
    /// Mutation.updateEntry
    pub type alias MutationUpdateEntryResolver[ef: Eff] = Context -> Id -> Value -> Int32 -> Result[FieldError, Entry] \ ef
    /// Mutation.deleteEntry
    pub type alias MutationDeleteEntryResolver[ef: Eff] = Context -> Id -> Result[FieldError, Id] \ ef
    /// Entry.id
    pub type alias EntryIdResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Id] \ ef
    /// Entry.typeId
    pub type alias EntryTypeIdResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Id] \ ef
    /// Entry.version
    pub type alias EntryVersionResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Int32] \ ef
    /// Entry.stage
    pub type alias EntryStageResolver[ef: Eff] = Context -> Entry -> Result[FieldError, EntryStage] \ ef
    /// Entry.fields
    pub type alias EntryFieldsResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Value] \ ef
    /// Entry.publishedAt
    pub type alias EntryPublishedAtResolver[ef: Eff] = Context -> Entry -> Result[FieldError, Option[String]] \ ef
    /// Entry.createdAt
    pub type alias EntryCreatedAtResolver[ef: Eff] = Context -> Entry -> Result[FieldError, String] \ ef
    /// Entry.updatedAt
    pub type alias EntryUpdatedAtResolver[ef: Eff] = Context -> Entry -> Result[FieldError, String] \ ef
    /// EntryPage.nodes
    pub type alias EntryPageNodesResolver[ef: Eff] = Context -> EntryPage -> Result[FieldError, List[Entry]] \ ef
    /// EntryPage.totalCount
    pub type alias EntryPageTotalCountResolver[ef: Eff] = Context -> EntryPage -> Result[FieldError, Int32] \ ef
    /// ContentType.id
    pub type alias ContentTypeIdResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, Id] \ ef
    /// ContentType.apiId
    pub type alias ContentTypeApiIdResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.kind
    pub type alias ContentTypeKindResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, TypeKind] \ ef
    /// ContentType.name
    pub type alias ContentTypeNameResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.singular
    pub type alias ContentTypeSingularResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.plural
    pub type alias ContentTypePluralResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.previewUrl
    pub type alias ContentTypePreviewUrlResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, Option[String]] \ ef
    /// ContentType.fields
    pub type alias ContentTypeFieldsResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, List[FieldDef]] \ ef
    /// ContentType.createdAt
    pub type alias ContentTypeCreatedAtResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// ContentType.updatedAt
    pub type alias ContentTypeUpdatedAtResolver[ef: Eff] = Context -> ContentType -> Result[FieldError, String] \ ef
    /// FieldDef.id
    pub type alias FieldDefIdResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Id] \ ef
    /// FieldDef.apiId
    pub type alias FieldDefApiIdResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, String] \ ef
    /// FieldDef.name
    pub type alias FieldDefNameResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, String] \ ef
    /// FieldDef.kind
    pub type alias FieldDefKindResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, FieldKind] \ ef
    /// FieldDef.many
    pub type alias FieldDefManyResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Bool] \ ef
    /// FieldDef.required
    pub type alias FieldDefRequiredResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Bool] \ ef
    /// FieldDef.unique
    pub type alias FieldDefUniqueResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Bool] \ ef
    /// FieldDef.localized
    pub type alias FieldDefLocalizedResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Bool] \ ef
    /// FieldDef.config
    pub type alias FieldDefConfigResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, FieldConfig] \ ef
    /// FieldDef.position
    pub type alias FieldDefPositionResolver[ef: Eff] = Context -> FieldDef -> Result[FieldError, Int32] \ ef
    /// FieldConfig.maxLength
    pub type alias FieldConfigMaxLengthResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[Int32]] \ ef
    /// FieldConfig.sourceField
    pub type alias FieldConfigSourceFieldResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[String]] \ ef
    /// FieldConfig.min
    pub type alias FieldConfigMinResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[Float64]] \ ef
    /// FieldConfig.max
    pub type alias FieldConfigMaxResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[Float64]] \ ef
    /// FieldConfig.integer
    pub type alias FieldConfigIntegerResolver[ef: Eff] = Context -> FieldConfig -> Result[FieldError, Option[Bool]] \ ef

    /// type Query のリゾルバ一式。ef はリゾルバの効果
    pub type alias QueryResolvers[ef: Eff] = {
        contentTypes = QueryContentTypesResolver[ef],
        contentType = QueryContentTypeResolver[ef],
        entries = QueryEntriesResolver[ef],
        entry = QueryEntryResolver[ef]
    }

    /// type Mutation のリゾルバ一式。ef はリゾルバの効果
    pub type alias MutationResolvers[ef: Eff] = {
        createContentType = MutationCreateContentTypeResolver[ef],
        updateContentType = MutationUpdateContentTypeResolver[ef],
        deleteContentType = MutationDeleteContentTypeResolver[ef],
        addField = MutationAddFieldResolver[ef],
        updateField = MutationUpdateFieldResolver[ef],
        removeField = MutationRemoveFieldResolver[ef],
        reorderFields = MutationReorderFieldsResolver[ef],
        createEntry = MutationCreateEntryResolver[ef],
        updateEntry = MutationUpdateEntryResolver[ef],
        deleteEntry = MutationDeleteEntryResolver[ef]
    }

    /// type Entry のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias EntryResolvers[ef: Eff] = {
        id = EntryIdResolver[ef],
        typeId = EntryTypeIdResolver[ef],
        version = EntryVersionResolver[ef],
        stage = EntryStageResolver[ef],
        fields = EntryFieldsResolver[ef],
        publishedAt = EntryPublishedAtResolver[ef],
        createdAt = EntryCreatedAtResolver[ef],
        updatedAt = EntryUpdatedAtResolver[ef]
    }

    /// type EntryPage のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias EntryPageResolvers[ef: Eff] = {
        nodes = EntryPageNodesResolver[ef],
        totalCount = EntryPageTotalCountResolver[ef]
    }

    /// type ContentType のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias ContentTypeResolvers[ef: Eff] = {
        id = ContentTypeIdResolver[ef],
        apiId = ContentTypeApiIdResolver[ef],
        kind = ContentTypeKindResolver[ef],
        name = ContentTypeNameResolver[ef],
        singular = ContentTypeSingularResolver[ef],
        plural = ContentTypePluralResolver[ef],
        previewUrl = ContentTypePreviewUrlResolver[ef],
        fields = ContentTypeFieldsResolver[ef],
        createdAt = ContentTypeCreatedAtResolver[ef],
        updatedAt = ContentTypeUpdatedAtResolver[ef]
    }

    /// type FieldDef のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias FieldDefResolvers[ef: Eff] = {
        id = FieldDefIdResolver[ef],
        apiId = FieldDefApiIdResolver[ef],
        name = FieldDefNameResolver[ef],
        kind = FieldDefKindResolver[ef],
        many = FieldDefManyResolver[ef],
        required = FieldDefRequiredResolver[ef],
        unique = FieldDefUniqueResolver[ef],
        localized = FieldDefLocalizedResolver[ef],
        config = FieldDefConfigResolver[ef],
        position = FieldDefPositionResolver[ef]
    }

    /// type FieldConfig のリゾルバ一式。第 2 引数が source。ef はリゾルバの効果
    pub type alias FieldConfigResolvers[ef: Eff] = {
        maxLength = FieldConfigMaxLengthResolver[ef],
        sourceField = FieldConfigSourceFieldResolver[ef],
        min = FieldConfigMinResolver[ef],
        max = FieldConfigMaxResolver[ef],
        integer = FieldConfigIntegerResolver[ef]
    }

    /// type Entry の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def entryDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        typeId = Context -> { typeId = Id | r1 } -> Result[FieldError, Id] \ ef,
        version = Context -> { version = Int32 | r2 } -> Result[FieldError, Int32] \ ef,
        stage = Context -> { stage = EntryStage | r3 } -> Result[FieldError, EntryStage] \ ef,
        fields = Context -> { fields = Value | r4 } -> Result[FieldError, Value] \ ef,
        publishedAt = Context -> { publishedAt = Option[String] | r5 } -> Result[FieldError, Option[String]] \ ef,
        createdAt = Context -> { createdAt = String | r6 } -> Result[FieldError, String] \ ef,
        updatedAt = Context -> { updatedAt = String | r7 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        typeId = (_context, src) -> Ok(src#typeId),
        version = (_context, src) -> Ok(src#version),
        stage = (_context, src) -> Ok(src#stage),
        fields = (_context, src) -> Ok(src#fields),
        publishedAt = (_context, src) -> Ok(src#publishedAt),
        createdAt = (_context, src) -> Ok(src#createdAt),
        updatedAt = (_context, src) -> Ok(src#updatedAt)
    }

    /// type EntryPage の既定リゾルバ。source の同名ラベルをそのまま返す。nodes は含まない（オブジェクト型を返すか、引数を持つ）
    pub def entryPageDefaults(): {
        totalCount = Context -> { totalCount = Int32 | r0 } -> Result[FieldError, Int32] \ ef
    } = {
        totalCount = (_context, src) -> Ok(src#totalCount)
    }

    /// type ContentType の既定リゾルバ。source の同名ラベルをそのまま返す。fields は含まない（オブジェクト型を返すか、引数を持つ）
    pub def contentTypeDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        apiId = Context -> { apiId = String | r1 } -> Result[FieldError, String] \ ef,
        kind = Context -> { kind = TypeKind | r2 } -> Result[FieldError, TypeKind] \ ef,
        name = Context -> { name = String | r3 } -> Result[FieldError, String] \ ef,
        singular = Context -> { singular = String | r4 } -> Result[FieldError, String] \ ef,
        plural = Context -> { plural = String | r5 } -> Result[FieldError, String] \ ef,
        previewUrl = Context -> { previewUrl = Option[String] | r6 } -> Result[FieldError, Option[String]] \ ef,
        createdAt = Context -> { createdAt = String | r7 } -> Result[FieldError, String] \ ef,
        updatedAt = Context -> { updatedAt = String | r8 } -> Result[FieldError, String] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        apiId = (_context, src) -> Ok(src#apiId),
        kind = (_context, src) -> Ok(src#kind),
        name = (_context, src) -> Ok(src#name),
        singular = (_context, src) -> Ok(src#singular),
        plural = (_context, src) -> Ok(src#plural),
        previewUrl = (_context, src) -> Ok(src#previewUrl),
        createdAt = (_context, src) -> Ok(src#createdAt),
        updatedAt = (_context, src) -> Ok(src#updatedAt)
    }

    /// type FieldDef の既定リゾルバ。source の同名ラベルをそのまま返す。config は含まない（オブジェクト型を返すか、引数を持つ）
    pub def fieldDefDefaults(): {
        id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        apiId = Context -> { apiId = String | r1 } -> Result[FieldError, String] \ ef,
        name = Context -> { name = String | r2 } -> Result[FieldError, String] \ ef,
        kind = Context -> { kind = FieldKind | r3 } -> Result[FieldError, FieldKind] \ ef,
        many = Context -> { many = Bool | r4 } -> Result[FieldError, Bool] \ ef,
        required = Context -> { required = Bool | r5 } -> Result[FieldError, Bool] \ ef,
        unique = Context -> { unique = Bool | r6 } -> Result[FieldError, Bool] \ ef,
        localized = Context -> { localized = Bool | r7 } -> Result[FieldError, Bool] \ ef,
        position = Context -> { position = Int32 | r8 } -> Result[FieldError, Int32] \ ef
    } = {
        id = (_context, src) -> Ok(src#id),
        apiId = (_context, src) -> Ok(src#apiId),
        name = (_context, src) -> Ok(src#name),
        kind = (_context, src) -> Ok(src#kind),
        many = (_context, src) -> Ok(src#many),
        required = (_context, src) -> Ok(src#required),
        unique = (_context, src) -> Ok(src#unique),
        localized = (_context, src) -> Ok(src#localized),
        position = (_context, src) -> Ok(src#position)
    }

    /// type FieldConfig の既定リゾルバ。source の同名ラベルをそのまま返す
    pub def fieldConfigDefaults(): {
        maxLength = Context -> { maxLength = Option[Int32] | r0 } -> Result[FieldError, Option[Int32]] \ ef,
        sourceField = Context -> { sourceField = Option[String] | r1 } -> Result[FieldError, Option[String]] \ ef,
        min = Context -> { min = Option[Float64] | r2 } -> Result[FieldError, Option[Float64]] \ ef,
        max = Context -> { max = Option[Float64] | r3 } -> Result[FieldError, Option[Float64]] \ ef,
        integer = Context -> { integer = Option[Bool] | r4 } -> Result[FieldError, Option[Bool]] \ ef
    } = {
        maxLength = (_context, src) -> Ok(src#maxLength),
        sourceField = (_context, src) -> Ok(src#sourceField),
        min = (_context, src) -> Ok(src#min),
        max = (_context, src) -> Ok(src#max),
        integer = (_context, src) -> Ok(src#integer)
    }

    /// 全型のリゾルバ。1 つでも欠けるとコンパイルエラー。ef は全リゾルバで共有する 1 つの効果
    pub type alias Resolvers[ef: Eff] = {
        queryRoot = QueryResolvers[ef],
        mutationRoot = MutationResolvers[ef],
        entry = EntryResolvers[ef],
        entryPage = EntryPageResolvers[ef],
        contentType = ContentTypeResolvers[ef],
        fieldDef = FieldDefResolvers[ef],
        fieldConfig = FieldConfigResolvers[ef]
    }

    /// リゾルバ一式からスキーマを組み立てる。runner が ef を IO に落とす
    pub def schema(resolvers: Resolvers[ef], runner: Runner[ef]): Schema =
        Schema.make(queryType(resolvers), Some(mutationType(resolvers)), runner)

    /// type Query
    def queryType(resolvers: Resolvers[ef]): ObjectType[Unit, ef] =
        Schema.objectType("Query", () ->
            {
                Schema.fieldRaw("contentTypes", Nil, Out.list(Out.obj(contentTypeType(resolvers))), (context, _src, _args) ->
                    (resolvers#queryRoot#contentTypes)(context)) |> Field.withDescription("全 content type。apiId 順")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.option(GqlCodec.id()));
                let arg1 = Schema.arg("apiId", GqlCodec.option(GqlCodec.string()));
                Schema.fieldRaw("contentType", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.option(Out.obj(contentTypeType(resolvers))), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#queryRoot#contentType)(context, v0, v1)) yield result) |> Field.withDescription("id か apiId で 1 つ。無ければ null")
            } ::
            {
                let arg0 = Schema.arg("typeId", GqlCodec.id());
                let arg1 = Schema.arg("search", GqlCodec.option(GqlCodec.string()));
                let arg2 = Schema.arg("first", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(50));
                let arg3 = Schema.arg("skip", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(0));
                Schema.fieldRaw("entries", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Arg.info(arg3) :: Nil, Out.obj(entryPageType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); v3 <- Arg.decode(arg3, args); result <- (resolvers#queryRoot#entries)(context, v0, v1, v2, v3)) yield result) |> Field.withDescription("型の entry の一覧。更新が新しい順。search は下書きの中身に含む文字列")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("entry", Arg.info(arg0) :: Nil, Out.option(Out.obj(entryType(resolvers))), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#queryRoot#entry)(context, v0)) yield result) |> Field.withDescription("entry 1 つ。無ければ null")
            } ::
            Nil) |> ObjectType.withDescription("管理 API。content type とフィールドの定義と、entry を読み書きする。形は固定で、コンテンツ API は定義から実行時に組む")

    /// type Mutation
    def mutationType(resolvers: Resolvers[ef]): ObjectType[Unit, ef] =
        Schema.objectType("Mutation", () ->
            {
                let arg0 = Schema.arg("input", contentTypeInputCodec());
                Schema.fieldRaw("createContentType", Arg.info(arg0) :: Nil, Out.obj(contentTypeType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#createContentType)(context, v0)) yield result)
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("input", contentTypePatchCodec());
                Schema.fieldRaw("updateContentType", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(contentTypeType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#updateContentType)(context, v0, v1)) yield result)
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("deleteContentType", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#deleteContentType)(context, v0)) yield result) |> Field.withDescription("フィールドごと消す")
            } ::
            {
                let arg0 = Schema.arg("typeId", GqlCodec.id());
                let arg1 = Schema.arg("input", fieldInputCodec());
                Schema.fieldRaw("addField", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(fieldDefType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#addField)(context, v0, v1)) yield result) |> Field.withDescription("末尾に足す")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("input", fieldPatchCodec());
                Schema.fieldRaw("updateField", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(fieldDefType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#updateField)(context, v0, v1)) yield result)
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("removeField", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#removeField)(context, v0)) yield result)
            } ::
            {
                let arg0 = Schema.arg("typeId", GqlCodec.id());
                let arg1 = Schema.arg("ids", GqlCodec.list(GqlCodec.id()));
                Schema.fieldRaw("reorderFields", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.obj(contentTypeType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); result <- (resolvers#mutationRoot#reorderFields)(context, v0, v1)) yield result) |> Field.withDescription("ids の順に並べ直す。型の全フィールドを過不足なく渡す")
            } ::
            {
                let arg0 = Schema.arg("typeId", GqlCodec.id());
                let arg1 = Schema.arg("fields", GqlCodec.json());
                let arg2 = Schema.arg("id", GqlCodec.option(GqlCodec.id()));
                Schema.fieldRaw("createEntry", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Nil, Out.obj(entryType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); result <- (resolvers#mutationRoot#createEntry)(context, v0, v1, v2)) yield result) |> Field.withDescription("下書きを作る。id を渡せば（移行用）それを使い、無ければ振る。fields は apiId → 値")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                let arg1 = Schema.arg("fields", GqlCodec.json());
                let arg2 = Schema.arg("expectedVersion", GqlCodec.int32());
                Schema.fieldRaw("updateEntry", Arg.info(arg0) :: Arg.info(arg1) :: Arg.info(arg2) :: Nil, Out.obj(entryType(resolvers)), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args); v2 <- Arg.decode(arg2, args); result <- (resolvers#mutationRoot#updateEntry)(context, v0, v1, v2)) yield result) |> Field.withDescription("下書きを直す。fields のキーだけ上書きし、null で消す。expectedVersion が今の version と違えば CONFLICT")
            } ::
            {
                let arg0 = Schema.arg("id", GqlCodec.id());
                Schema.fieldRaw("deleteEntry", Arg.info(arg0) :: Nil, Out.id(), (context, _src, args) ->
                    forM (v0 <- Arg.decode(arg0, args); result <- (resolvers#mutationRoot#deleteEntry)(context, v0)) yield result) |> Field.withDescription("ゴミ箱へ（soft delete）")
            } ::
            Nil)

    /// type Entry
    def entryType(resolvers: Resolvers[ef]): ObjectType[Entry, ef] =
        Schema.objectType("Entry", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#entry#id)(context, src))
            } ::
            {
                Schema.fieldRaw("typeId", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#entry#typeId)(context, src))
            } ::
            {
                Schema.fieldRaw("version", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#entry#version)(context, src)) |> Field.withDescription("楽観ロックの版。updateEntry に expectedVersion として渡す")
            } ::
            {
                Schema.fieldRaw("stage", Nil, Out.scalar(entryStageCodec()), (context, src, _args) ->
                    (resolvers#entry#stage)(context, src))
            } ::
            {
                Schema.fieldRaw("fields", Nil, Out.json(), (context, src, _args) ->
                    (resolvers#entry#fields)(context, src))
            } ::
            {
                Schema.fieldRaw("publishedAt", Nil, Out.option(Out.string()), (context, src, _args) ->
                    (resolvers#entry#publishedAt)(context, src))
            } ::
            {
                Schema.fieldRaw("createdAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#entry#createdAt)(context, src))
            } ::
            {
                Schema.fieldRaw("updatedAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#entry#updatedAt)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("entry。fields は下書きの中身")

    /// type EntryPage
    def entryPageType(resolvers: Resolvers[ef]): ObjectType[EntryPage, ef] =
        Schema.objectType("EntryPage", () ->
            {
                Schema.fieldRaw("nodes", Nil, Out.list(Out.obj(entryType(resolvers))), (context, src, _args) ->
                    (resolvers#entryPage#nodes)(context, src))
            } ::
            {
                Schema.fieldRaw("totalCount", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#entryPage#totalCount)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("entry の一覧の 1 ページ")

    /// type ContentType
    def contentTypeType(resolvers: Resolvers[ef]): ObjectType[ContentType, ef] =
        Schema.objectType("ContentType", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#contentType#id)(context, src))
            } ::
            {
                Schema.fieldRaw("apiId", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#apiId)(context, src)) |> Field.withDescription("lowerCamel の識別子（\"blogs\"）")
            } ::
            {
                Schema.fieldRaw("kind", Nil, Out.scalar(typeKindCodec()), (context, src, _args) ->
                    (resolvers#contentType#kind)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#name)(context, src)) |> Field.withDescription("管理画面に出す名前")
            } ::
            {
                Schema.fieldRaw("singular", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#singular)(context, src)) |> Field.withDescription("コンテンツ API の型名（\"Blog\"）")
            } ::
            {
                Schema.fieldRaw("plural", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#plural)(context, src)) |> Field.withDescription("コンテンツ API の一覧クエリ名（\"blogs\"）")
            } ::
            {
                Schema.fieldRaw("previewUrl", Nil, Out.option(Out.string()), (context, src, _args) ->
                    (resolvers#contentType#previewUrl)(context, src)) |> Field.withDescription("管理画面のプレビューが開く URL。{id} を entry の id に置き換える")
            } ::
            {
                Schema.fieldRaw("fields", Nil, Out.list(Out.obj(fieldDefType(resolvers))), (context, src, _args) ->
                    (resolvers#contentType#fields)(context, src)) |> Field.withDescription("position 順")
            } ::
            {
                Schema.fieldRaw("createdAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#createdAt)(context, src))
            } ::
            {
                Schema.fieldRaw("updatedAt", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#contentType#updatedAt)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("content type。apiId がコンテンツ API のクエリ名の元になる")

    /// type FieldDef
    def fieldDefType(resolvers: Resolvers[ef]): ObjectType[FieldDef, ef] =
        Schema.objectType("FieldDef", () ->
            {
                Schema.fieldRaw("id", Nil, Out.id(), (context, src, _args) ->
                    (resolvers#fieldDef#id)(context, src))
            } ::
            {
                Schema.fieldRaw("apiId", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#fieldDef#apiId)(context, src))
            } ::
            {
                Schema.fieldRaw("name", Nil, Out.string(), (context, src, _args) ->
                    (resolvers#fieldDef#name)(context, src))
            } ::
            {
                Schema.fieldRaw("kind", Nil, Out.scalar(fieldKindCodec()), (context, src, _args) ->
                    (resolvers#fieldDef#kind)(context, src))
            } ::
            {
                Schema.fieldRaw("many", Nil, Out.bool(), (context, src, _args) ->
                    (resolvers#fieldDef#many)(context, src)) |> Field.withDescription("配列か")
            } ::
            {
                Schema.fieldRaw("required", Nil, Out.bool(), (context, src, _args) ->
                    (resolvers#fieldDef#required)(context, src)) |> Field.withDescription("公開時に値が要るか")
            } ::
            {
                Schema.fieldRaw("unique", Nil, Out.bool(), (context, src, _args) ->
                    (resolvers#fieldDef#unique)(context, src)) |> Field.withDescription("型の中で値が一意か")
            } ::
            {
                Schema.fieldRaw("localized", Nil, Out.bool(), (context, src, _args) ->
                    (resolvers#fieldDef#localized)(context, src)) |> Field.withDescription("言語ごとに値を持つか")
            } ::
            {
                Schema.fieldRaw("config", Nil, Out.obj(fieldConfigType(resolvers)), (context, src, _args) ->
                    (resolvers#fieldDef#config)(context, src))
            } ::
            {
                Schema.fieldRaw("position", Nil, Out.int32(), (context, src, _args) ->
                    (resolvers#fieldDef#position)(context, src))
            } ::
            Nil) |> ObjectType.withDescription("フィールドの定義")

    /// type FieldConfig
    def fieldConfigType(resolvers: Resolvers[ef]): ObjectType[FieldConfig, ef] =
        Schema.objectType("FieldConfig", () ->
            {
                Schema.fieldRaw("maxLength", Nil, Out.option(Out.int32()), (context, src, _args) ->
                    (resolvers#fieldConfig#maxLength)(context, src)) |> Field.withDescription("TEXT / TEXT_AREA / SLUG の最大文字数")
            } ::
            {
                Schema.fieldRaw("sourceField", Nil, Out.option(Out.string()), (context, src, _args) ->
                    (resolvers#fieldConfig#sourceField)(context, src)) |> Field.withDescription("SLUG の元にするフィールドの apiId")
            } ::
            {
                Schema.fieldRaw("min", Nil, Out.option(Out.float64()), (context, src, _args) ->
                    (resolvers#fieldConfig#min)(context, src)) |> Field.withDescription("NUMBER の下限")
            } ::
            {
                Schema.fieldRaw("max", Nil, Out.option(Out.float64()), (context, src, _args) ->
                    (resolvers#fieldConfig#max)(context, src)) |> Field.withDescription("NUMBER の上限")
            } ::
            {
                Schema.fieldRaw("integer", Nil, Out.option(Out.bool()), (context, src, _args) ->
                    (resolvers#fieldConfig#integer)(context, src)) |> Field.withDescription("NUMBER を整数に限るか")
            } ::
            Nil) |> ObjectType.withDescription("kind ごとの設定。使わない項目は null")

}
