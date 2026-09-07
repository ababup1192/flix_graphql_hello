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
    pub def idOfType(id: TypeId): Id = Id.Id(Int64.toString(TypeId.toInt64(id)))

    ///
    /// フィールドの id を GraphQL の ID にする。
    ///
    pub def idOfField(id: FieldId): Id = Id.Id(Int64.toString(FieldId.toInt64(id)))

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

    ///
    /// GraphQL の ID を asset の id に読む。規則（entry と同じ）に合わなければ invalid。
    ///
    pub def assetId(argument: String, id: Id): AssetId \ CmsErr =
        let Id.Id(text) = id;
        parsed(argument, EntryId.rule(), AssetId.parse, text)

    ///
    /// asset の id を GraphQL の ID にする。
    ///
    pub def idOfAsset(id: AssetId): Id = Id.Id(AssetId.text(id))

    ///
    /// ユーザー・組織・プロジェクトの id と GraphQL の ID。
    ///
    /// 外向きの id（public_id）をそのまま ID に。内部の連番は出さない。
    pub def idOfPublic(publicId: String): Id = Id.Id(publicId)

    /// ID（public_id）から内部の UserId。無ければ notFound。
    pub def userId(argument: String, id: Id): UserId \ DbRead + CmsErr =
        let Id.Id(publicId) = id;
        Accounts.findByPublicId(publicId) |> Option.map(user -> user#id) |> CmsErr.orNotFound(Entity.Member, "${argument}=${publicId}")

    /// ID（public_id）の中の文字列。
    pub def publicIdOf(id: Id): String =
        let Id.Id(text) = id;
        text

    ///
    /// 役割・範囲・公開範囲の enum の写し。
    ///
    pub def roleOf(role: GeneratedAdmin.Role): Role = match role {
        case GeneratedAdmin.Role.Viewer => Role.Viewer
        case GeneratedAdmin.Role.Writer => Role.Writer
        case GeneratedAdmin.Role.Editor => Role.Editor
        case GeneratedAdmin.Role.Owner  => Role.Owner
    }

    pub def roleToGql(role: Role): GeneratedAdmin.Role = match role {
        case Role.Viewer => GeneratedAdmin.Role.Viewer
        case Role.Writer => GeneratedAdmin.Role.Writer
        case Role.Editor => GeneratedAdmin.Role.Editor
        case Role.Owner  => GeneratedAdmin.Role.Owner
    }

    pub def orgRoleToGql(role: OrgRole): GeneratedAdmin.OrgRole = match role {
        case OrgRole.Member => GeneratedAdmin.OrgRole.Member
        case OrgRole.Owner  => GeneratedAdmin.OrgRole.Owner
    }

    pub def apiKeyScopeOf(scope: GeneratedAdmin.ApiKeyScope): ApiKeyScope = match scope {
        case GeneratedAdmin.ApiKeyScope.Read      => ApiKeyScope.Read
        case GeneratedAdmin.ApiKeyScope.ReadDraft => ApiKeyScope.ReadDraft
    }

    pub def apiKeyScopeToGql(scope: ApiKeyScope): GeneratedAdmin.ApiKeyScope = match scope {
        case ApiKeyScope.Read      => GeneratedAdmin.ApiKeyScope.Read
        case ApiKeyScope.ReadDraft => GeneratedAdmin.ApiKeyScope.ReadDraft
    }

    pub def visibilityOf(visibility: GeneratedAdmin.Visibility): Visibility = match visibility {
        case GeneratedAdmin.Visibility.Public  => Visibility.Public
        case GeneratedAdmin.Visibility.Private => Visibility.Private
    }

    pub def webhookEventOf(event: GeneratedAdmin.WebhookEvent): WebhookEvent = match event {
        case GeneratedAdmin.WebhookEvent.EntryPublished   => WebhookEvent.EntryPublished
        case GeneratedAdmin.WebhookEvent.EntryUnpublished => WebhookEvent.EntryUnpublished
        case GeneratedAdmin.WebhookEvent.EntryDeleted     => WebhookEvent.EntryDeleted
        case GeneratedAdmin.WebhookEvent.SchemaChanged    => WebhookEvent.SchemaChanged
    }

    pub def webhookEventToGql(event: WebhookEvent): GeneratedAdmin.WebhookEvent = match event {
        case WebhookEvent.EntryPublished   => GeneratedAdmin.WebhookEvent.EntryPublished
        case WebhookEvent.EntryUnpublished => GeneratedAdmin.WebhookEvent.EntryUnpublished
        case WebhookEvent.EntryDeleted     => GeneratedAdmin.WebhookEvent.EntryDeleted
        case WebhookEvent.SchemaChanged    => GeneratedAdmin.WebhookEvent.SchemaChanged
    }

    pub def deliveryStatusToGql(status: DeliveryStatus): GeneratedAdmin.DeliveryStatus = match status {
        case DeliveryStatus.Pending   => GeneratedAdmin.DeliveryStatus.Pending
        case DeliveryStatus.Sending   => GeneratedAdmin.DeliveryStatus.Sending
        case DeliveryStatus.Delivered => GeneratedAdmin.DeliveryStatus.Delivered
        case DeliveryStatus.Failed    => GeneratedAdmin.DeliveryStatus.Failed
    }

    /// WebhookInput → ドメインの入力。active を省けば true。
    pub def webhookDraftOf(input: GeneratedAdmin.WebhookInput): WebhookDraft =
        { name = input#name, url = input#url, events = input#events |> List.map(webhookEventOf), active = input#active |> Option.getWithDefault(true) }

    pub def visibilityToGql(visibility: Visibility): GeneratedAdmin.Visibility = match visibility {
        case Visibility.Public  => GeneratedAdmin.Visibility.Public
        case Visibility.Private => GeneratedAdmin.Visibility.Private
    }

    ///
    /// Violation の path と message。
    ///
    pub def violationPath(violation: Violation): String = { let Violation.Violation(path, _) = violation; path }

    pub def violationMessage(violation: Violation): String = { let Violation.Violation(_, message) = violation; message }

    ///
    /// GraphQL の ImpactAction をドメインに。
    ///
    pub def impactActionOf(action: GeneratedAdmin.ImpactAction): ImpactAction = match action {
        case GeneratedAdmin.ImpactAction.Publish   => ImpactAction.Publish
        case GeneratedAdmin.ImpactAction.Unpublish => ImpactAction.Unpublish
        case GeneratedAdmin.ImpactAction.Delete    => ImpactAction.Delete
    }

    ///
    /// 中身の段階（draft / published の行）を GraphQL の enum に。
    ///
    pub def contentStageToGql(stage: Stage): GeneratedAdmin.ContentStage = match stage {
        case Stage.Draft     => GeneratedAdmin.ContentStage.Draft
        case Stage.Published => GeneratedAdmin.ContentStage.Published
    }

    ///
    /// asset の状態を GraphQL の enum に。
    ///
    pub def assetStatusToGql(status: AssetStatus): GeneratedAdmin.AssetStatus = match status {
        case AssetStatus.Pending => GeneratedAdmin.AssetStatus.Pending
        case AssetStatus.Ready   => GeneratedAdmin.AssetStatus.Ready
    }

    ///
    /// バイト数や件数を GraphQL の Int に収める。上限（20 MB、一覧の件数）は Int32 に十分入る。
    ///
    pub def sizeToGql(value: Int64): Int32 = Int64.clampToInt32(min = 0, max = Int32.maxValue(), value)

    ///
    /// UploadInput をドメインの申し込みに。
    ///
    pub def uploadRequest(input: GeneratedAdmin.UploadInput): UploadRequest =
        { fileName = input#fileName, mime = input#mime, size = Int32.toInt64(input#size) }

    ///
    /// AssetConfirmInput をドメインの confirm に。省かれていれば全部 None。
    ///
    pub def assetConfirm(input: Option[GeneratedAdmin.AssetConfirmInput]): AssetConfirm = match input {
        case Some(found) => { width = found#width, height = found#height, alt = found#alt }
        case None        => { width = None, height = None, alt = None }
    }

    pub def number(argument: String, id: Id): Int64 \ CmsErr =
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
        case GeneratedAdmin.FieldKind.Asset    => FieldKind.Asset
        case GeneratedAdmin.FieldKind.RichText => FieldKind.RichText
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
        case FieldKind.Asset    => GeneratedAdmin.FieldKind.Asset
        case FieldKind.RichText => GeneratedAdmin.FieldKind.RichText
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

    pub def idOfVersion(id: VersionId): Id = Id.Id(Int64.toString(VersionId.toInt64(id)))

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
