///
/// 管理 API の GraphQL の型（GeneratedAdmin）とドメインの型のあいだの写し。
/// ID の読み書き、enum の対応、入力レコードからドメインの Draft / Changes への変換。管理 API で境界を越えるのはここだけ。
///
/// WhyNot: ドメインが GeneratedAdmin の enum をそのまま使わないのは、コンテンツ API（別のスキーマ）も同じドメインを使うため。
/// SDL を変えてもここだけ直せばよい。
///
mod AdminMapping {

    // ---- ID ----

    ///
    /// GraphQL の ID を content type の id に読む。数字でなければ invalid（argument は引数名）。
    ///
    pub def typeId(argument: String, id: Id): TypeId \ CmsErr =
        TypeId.TypeId(number(argument, id))

    ///
    /// GraphQL の ID をフィールドの id に読む。
    ///
    pub def fieldId(argument: String, id: Id): FieldId \ CmsErr =
        FieldId.FieldId(number(argument, id))

    ///
    /// content type の id を GraphQL の ID にする。
    ///
    pub def idOfType(id: TypeId): Id = Id.Id("${id}")

    ///
    /// フィールドの id を GraphQL の ID にする。
    ///
    pub def idOfField(id: FieldId): Id = Id.Id("${id}")

    ///
    /// GraphQL の ID を entry の id に読む。規則に合わなければ invalid。
    ///
    pub def entryId(argument: String, id: Id): EntryId \ CmsErr =
        let Id.Id(text) = id;
        parsed(argument, EntryId.rule(), EntryId.parse, text)

    ///
    /// entry の id を GraphQL の ID にする。
    ///
    pub def idOfEntry(id: EntryId): Id = Id.Id(EntryId.text(id))

    def number(argument: String, id: Id): Int64 \ CmsErr =
        let Id.Id(text) = id;
        match Int64.fromString(text) {
            case Some(found) => found
            case None        => CmsErr.invalid(Violation.Violation(argument, "'${text}' は数字の ID ではありません") :: Nil)
        }

    // ---- enum ----

    pub def typeKindOf(kind: GeneratedAdmin.TypeKind): TypeKind = match kind {
        case GeneratedAdmin.TypeKind.Collection => TypeKind.Collection
        case GeneratedAdmin.TypeKind.Singleton  => TypeKind.Singleton
    }

    pub def typeKindToGql(kind: TypeKind): GeneratedAdmin.TypeKind = match kind {
        case TypeKind.Collection => GeneratedAdmin.TypeKind.Collection
        case TypeKind.Singleton  => GeneratedAdmin.TypeKind.Singleton
    }

    pub def fieldKindOf(kind: GeneratedAdmin.FieldKind): FieldKind = match kind {
        case GeneratedAdmin.FieldKind.Text     => FieldKind.Text
        case GeneratedAdmin.FieldKind.TextArea => FieldKind.TextArea
        case GeneratedAdmin.FieldKind.Slug     => FieldKind.Slug
        case GeneratedAdmin.FieldKind.Number   => FieldKind.Number
        case GeneratedAdmin.FieldKind.Boolean  => FieldKind.Boolean
        case GeneratedAdmin.FieldKind.Select   => FieldKind.Select
        case GeneratedAdmin.FieldKind.Reference => FieldKind.Reference
        case GeneratedAdmin.FieldKind.Object   => FieldKind.Object
        case GeneratedAdmin.FieldKind.Blocks   => FieldKind.Blocks
    }

    pub def fieldKindToGql(kind: FieldKind): GeneratedAdmin.FieldKind = match kind {
        case FieldKind.Text     => GeneratedAdmin.FieldKind.Text
        case FieldKind.TextArea => GeneratedAdmin.FieldKind.TextArea
        case FieldKind.Slug     => GeneratedAdmin.FieldKind.Slug
        case FieldKind.Number   => GeneratedAdmin.FieldKind.Number
        case FieldKind.Boolean  => GeneratedAdmin.FieldKind.Boolean
        case FieldKind.Select   => GeneratedAdmin.FieldKind.Select
        case FieldKind.Reference => GeneratedAdmin.FieldKind.Reference
        case FieldKind.Object   => GeneratedAdmin.FieldKind.Object
        case FieldKind.Blocks   => GeneratedAdmin.FieldKind.Blocks
    }

    ///
    /// 管理 API の EntryStage。公開後に下書きが進んでいれば CHANGED。
    ///
    pub def entryStageToGql(entry: Entry): GeneratedAdmin.EntryStage = match (entry#stage, entry#changedSincePublish) {
        case (Stage.Draft, _)         => GeneratedAdmin.EntryStage.Draft
        case (Stage.Published, false) => GeneratedAdmin.EntryStage.Published
        case (Stage.Published, true)  => GeneratedAdmin.EntryStage.Changed
    }

    pub def reasonToGql(reason: VersionReason): GeneratedAdmin.VersionReason = match reason {
        case VersionReason.Publish => GeneratedAdmin.VersionReason.Publish
        case VersionReason.Save    => GeneratedAdmin.VersionReason.Save
    }

    ///
    /// GraphQL の ID を版の id に読む。
    ///
    pub def versionId(argument: String, id: Id): VersionId \ CmsErr =
        VersionId.VersionId(number(argument, id))

    pub def idOfVersion(id: VersionId): Id = Id.Id("${id}")

    ///
    /// 版に残す作者名。認証が入るまでは Context の userId か "anonymous"。
    ///
    pub def authorOf(context: Context): String = context#userId |> Option.getWithDefault("anonymous")

    // ---- JSON ----

    ///
    /// createEntry / updateEntry の fields（JSON）をドメインの中身に。オブジェクトでない・キーが識別子でない物は invalid。
    ///
    pub def entryData(argument: String, value: Value): EntryData \ CmsErr = match value {
        case Value.Obj(fields) =>
            Map.foldLeftWithKey((acc, key, item) -> match ApiId.parse(key) {
                case Some(apiId) => Map.insert(apiId, JsonValue.toJson(item), acc)
                case None        => CmsErr.invalid(Violation.Violation("${argument}.${key}", "フィールドの apiId は ${ApiId.rule()}です") :: Nil)
            }, Map.empty(), fields)
        case _ => CmsErr.invalid(Violation.Violation(argument, "オブジェクト（apiId → 値）にしてください") :: Nil)
    }

    ///
    /// ドメインの中身を GraphQL の JSON に。
    ///
    pub def entryDataValue(data: EntryData): Value =
        Value.Obj(data |> Map.toList |> List.map(match (apiId, item) -> (ApiId.text(apiId), JsonValue.fromJson(item))) |> List.toMap)

    // ---- 入力 → ドメイン ----

    ///
    /// ContentTypeInput を Draft に。識別子の形に合わなければ invalid。
    ///
    pub def typeDraft(input: GeneratedAdmin.ContentTypeInput): ContentTypeDraft \ CmsErr =
        {
            apiId      = apiId("apiId", input#apiId),
            kind       = input#kind |> Option.map(typeKindOf) |> Option.getWithDefault(TypeKind.Collection),
            name       = input#name,
            singular   = input#singular |> Option.map(typeName("singular")),
            plural     = input#plural |> Option.map(apiId("plural")),
            previewUrl = input#previewUrl
        }

    ///
    /// ContentTypePatch を Changes に。
    ///
    pub def typeChanges(patch: GeneratedAdmin.ContentTypePatch): ContentTypeChanges \ CmsErr =
        {
            name       = patch#name,
            singular   = patch#singular |> Option.map(typeName("singular")),
            plural     = patch#plural |> Option.map(apiId("plural")),
            previewUrl = patch#previewUrl
        }

    ///
    /// FieldInput を Draft に。
    ///
    pub def fieldDraft(input: GeneratedAdmin.FieldInput): FieldDraft \ CmsErr =
        let kind = fieldKindOf(input#kind);
        {
            apiId     = apiId("apiId", input#apiId),
            name      = input#name,
            kind      = kind,
            many      = input#many |> Option.getWithDefault(false) or kind == FieldKind.Blocks,
            required  = input#required |> Option.getWithDefault(false),
            unique    = input#unique |> Option.getWithDefault(false),
            localized = input#localized |> Option.getWithDefault(false),
            target    = input#targetTypeId |> Option.map(typeId("targetTypeId")),
            parent    = input#parentFieldId |> Option.map(fieldId("parentFieldId")),
            config    = input#config |> Option.map(config) |> Option.getWithDefault(FieldConfig.empty())
        }

    ///
    /// FieldPatch を Changes に。
    ///
    pub def fieldChanges(patch: GeneratedAdmin.FieldPatch): FieldChanges \ CmsErr =
        {
            name      = patch#name,
            required  = patch#required,
            unique    = patch#unique,
            localized = patch#localized,
            config    = patch#config |> Option.map(config)
        }

    ///
    /// FieldConfigInput を FieldConfig に。sourceField は識別子の形を見る。
    ///
    pub def config(input: GeneratedAdmin.FieldConfigInput): FieldConfig \ CmsErr =
        {
            maxLength   = input#maxLength,
            sourceField = input#sourceField |> Option.map(apiId("config.sourceField")),
            min         = input#min,
            max         = input#max,
            integer     = input#integer,
            options     = input#options |> Option.getWithDefault(Nil)
        }

    def apiId(argument: String, text: String): ApiId \ CmsErr = parsed(argument, ApiId.rule(), ApiId.parse, text)

    def typeName(argument: String, text: String): TypeName \ CmsErr = parsed(argument, TypeName.rule(), TypeName.parse, text)

    ///
    /// 規則付きの識別子を読む。合わなければ invalid（argument は引数名、rule は規則の説明）。
    ///
    def parsed(argument: String, rule: String, parse: String -> Option[a], text: String): a \ CmsErr = match parse(text) {
        case Some(found) => found
        case None        => CmsErr.invalid(Violation.Violation(argument, "${rule}にしてください") :: Nil)
    }

}
