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

    /// 時刻順の記録（配信・予約）の id（ULID）をそのまま ID に。
    pub def idOfUlid(ulid: String): Id = Id.Id(ulid)

    /// ID（public_id）から内部の UserId。無ければ notFound。
    pub def userId(argument: String, id: Id): UserId \ DbRead + CmsErr =
        let Id.Id(publicId) = id;
        Accounts.requireByPublicId(argument, publicId)

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

    pub def viewerKindToGql(kind: ViewerKind): GeneratedAdmin.ViewerKind = match kind {
        case ViewerKind.User          => GeneratedAdmin.ViewerKind.User
        case ViewerKind.PersonalToken => GeneratedAdmin.ViewerKind.PersonalToken
        case ViewerKind.ApiKey        => GeneratedAdmin.ViewerKind.ApiKey
        case ViewerKind.Preview       => GeneratedAdmin.ViewerKind.Preview
        case ViewerKind.Anonymous     => GeneratedAdmin.ViewerKind.Anonymous
        case ViewerKind.System        => GeneratedAdmin.ViewerKind.System
    }

    pub def orgRoleToGql(role: OrgRole): GeneratedAdmin.OrgRole = match role {
        case OrgRole.Member => GeneratedAdmin.OrgRole.Member
        case OrgRole.Owner  => GeneratedAdmin.OrgRole.Owner
    }

    ///
    /// scope と role の組から API キーの範囲。WRITE は role が必須、それ以外で role を渡すと invalid。
    ///
    pub def apiKeyScopeOf(scope: GeneratedAdmin.ApiKeyScope, role: Option[GeneratedAdmin.Role]): ApiKeyScope \ CmsErr = match (scope, role) {
        case (GeneratedAdmin.ApiKeyScope.Read, None)       => ApiKeyScope.Read
        case (GeneratedAdmin.ApiKeyScope.ReadDraft, None)  => ApiKeyScope.ReadDraft
        case (GeneratedAdmin.ApiKeyScope.Write, Some(found)) => ApiKeyScope.Write(roleOf(found))
        case (GeneratedAdmin.ApiKeyScope.Write, None)      => CmsErr.invalid(Violation.Violation("role", "scope が WRITE の鍵には role が要ります（WRITER / EDITOR / OWNER）") :: Nil)
        case (_, Some(_))                                  => CmsErr.invalid(Violation.Violation("role", "role は scope が WRITE の鍵にだけ渡せます") :: Nil)
    }

    pub def apiKeyScopeToGql(scope: ApiKeyScope): GeneratedAdmin.ApiKeyScope = match scope {
        case ApiKeyScope.Read      => GeneratedAdmin.ApiKeyScope.Read
        case ApiKeyScope.ReadDraft => GeneratedAdmin.ApiKeyScope.ReadDraft
        case ApiKeyScope.Write(_)  => GeneratedAdmin.ApiKeyScope.Write
    }

    /// WRITE の鍵の役割。それ以外は None。
    pub def apiKeyRoleToGql(scope: ApiKeyScope): Option[GeneratedAdmin.Role] =
        ApiKeyScope.roleOf(scope) |> Option.map(roleToGql)

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

    pub def scheduleActionToGql(action: ScheduleAction): GeneratedAdmin.ScheduleAction = match action {
        case ScheduleAction.Publish   => GeneratedAdmin.ScheduleAction.Publish
        case ScheduleAction.Unpublish => GeneratedAdmin.ScheduleAction.Unpublish
    }

    pub def scheduleStatusToGql(status: ScheduleStatus): GeneratedAdmin.ScheduleStatus = match status {
        case ScheduleStatus.Pending   => GeneratedAdmin.ScheduleStatus.Pending
        case ScheduleStatus.Running   => GeneratedAdmin.ScheduleStatus.Running
        case ScheduleStatus.Done      => GeneratedAdmin.ScheduleStatus.Done
        case ScheduleStatus.Failed    => GeneratedAdmin.ScheduleStatus.Failed
        case ScheduleStatus.Cancelled => GeneratedAdmin.ScheduleStatus.Cancelled
    }

    /// ISO 8601 の文字列から時刻。形が違えば invalid。
    pub def timestampOf(argument: String, text: String): Timestamp.Timestamp \ CmsErr =
        Timestamp.fromIso8601(text) |> CmsErr.orInvalid(argument, "'${text}' は ISO 8601 の時刻ではありません（例: 2026-09-08T09:00:00Z）")

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
    /// 公開計画の理由 → GraphQL の enum
    pub def planReasonToGql(reason: PlanReason): GeneratedAdmin.PlanReason = match reason {
        case PlanReason.Requested  => GeneratedAdmin.PlanReason.Requested
        case PlanReason.Dependency => GeneratedAdmin.PlanReason.Dependency
    }

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
    pub def sizeToGql(value: Int64): Int32 = EntryPage.countToInt32(value)

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
        case GeneratedAdmin.FieldKind.Date     => FieldKind.Date
        case GeneratedAdmin.FieldKind.DateOnly => FieldKind.DateOnly
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
        case FieldKind.Date     => GeneratedAdmin.FieldKind.Date
        case FieldKind.DateOnly => GeneratedAdmin.FieldKind.DateOnly
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
    /// input VersionRef をドメインに。versionId と stage のどちらか 1 つ。両方や両方無しは invalid（argument は引数名）。
    ///
    pub def versionRefOf(argument: String, input: GeneratedAdmin.VersionRef): VersionRef \ CmsErr = match (input#versionId, input#stage) {
        case (Some(id), None)                                => VersionRef.Version(versionId(argument, id))
        case (None, Some(GeneratedAdmin.ContentStage.Draft))     => VersionRef.Draft
        case (None, Some(GeneratedAdmin.ContentStage.Published)) => VersionRef.Published
        case _                                               => CmsErr.invalid(Violation.Violation(argument, "versionId か stage のどちらか 1 つにしてください") :: Nil)
    }

    // ---- 差分 ----

    pub def changeKindToGql(change: Change): GeneratedAdmin.ChangeKind = match change {
        case Change.Added(_)      => GeneratedAdmin.ChangeKind.Added
        case Change.Removed(_)    => GeneratedAdmin.ChangeKind.Removed
        case Change.Changed(_, _) => GeneratedAdmin.ChangeKind.Changed
        case Change.Nested(_)     => GeneratedAdmin.ChangeKind.Nested
        case Change.Text(_)       => GeneratedAdmin.ChangeKind.Text
    }

    /// from 側の値。REMOVED と CHANGED だけ。
    pub def changeBefore(change: Change): Option[Value] = match change {
        case Change.Removed(before)    => Some(JsonValue.fromJson(before))
        case Change.Changed(before, _) => Some(JsonValue.fromJson(before))
        case _                         => None
    }

    /// to 側の値。ADDED と CHANGED だけ。
    pub def changeAfter(change: Change): Option[Value] = match change {
        case Change.Added(after)      => Some(JsonValue.fromJson(after))
        case Change.Changed(_, after) => Some(JsonValue.fromJson(after))
        case _                        => None
    }

    /// NESTED の中身。
    pub def changeChildren(change: Change): Option[List[FieldChange]] = match change {
        case Change.Nested(children) => Some(children)
        case _                       => None
    }

    /// TEXT の行。
    pub def changeLines(change: Change): Option[List[DiffLine]] = match change {
        case Change.Text(lines) => Some(lines)
        case _                  => None
    }

    pub def lineKindToGql(line: DiffLine): GeneratedAdmin.LineKind = match line {
        case DiffLine.Same(_) => GeneratedAdmin.LineKind.Same
        case DiffLine.Add(_)  => GeneratedAdmin.LineKind.Add
        case DiffLine.Del(_)  => GeneratedAdmin.LineKind.Del
    }

    pub def lineText(line: DiffLine): String = match line {
        case DiffLine.Same(text) => text
        case DiffLine.Add(text)  => text
        case DiffLine.Del(text)  => text
    }


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

    // ---- 一覧の絞り込みと並び順 ----

    ///
    /// orderBy の入力を並び順に。field は id / publishedAt / updatedAt / createdAt かフィールドの apiId。規則外なら invalid。
    ///
    pub def entryOrderBy(input: Option[List[GeneratedAdmin.EntryOrderBy]]): OrderBy \ CmsErr =
        input |> Option.getWithDefault(Nil) |> List.map(term ->
            (SortKey.fromText(term#field) |> CmsErr.orInvalid("orderBy.field", "'${term#field}' は id / publishedAt / updatedAt / createdAt かフィールドの apiId にしてください"),
             sortDirectionOf(term#direction)))

    pub def sortDirectionOf(direction: GeneratedAdmin.SortDirection): Direction = match direction {
        case GeneratedAdmin.SortDirection.Asc  => Direction.Asc
        case GeneratedAdmin.SortDirection.Desc => Direction.Desc
    }

    ///
    /// where の入力に、型の定義（フィールドの kind）が要るか。フィールドの条件があれば要る。
    ///
    pub def whereNeedsFields(input: Option[GeneratedAdmin.EntryWhere]): Bool =
        input |> Option.flatMap(given -> given#fields) |> Option.exists(conditions -> not List.isEmpty(conditions))

    ///
    /// where の入力を絞り込みに。stage は entries.stage、id_in は規則に合う id だけ、fields は op と kind で Condition に写す。
    /// createdAt / updatedAt / publishedAt は entries の列で比べる。
    /// 型に無い apiId、op と kind の組み合わせにない物、value の型が違う物は invalid。
    ///
    pub def entryWhere(fields: List[FieldDef], input: Option[GeneratedAdmin.EntryWhere]): Where \ CmsErr = match input {
        case None        => Nil
        case Some(given) =>
            let stage = given#stage |> Option.map(contentStageOf) |> Option.map(Condition.StageEq) |> Option.toList;
            let ids = given#id_in |> Option.map(idList -> Condition.IdIn(idList |> List.filterMap(id -> { let Id.Id(text) = id; EntryId.parse(text) }))) |> Option.toList;
            let conditions = given#fields |> Option.getWithDefault(Nil) |> List.map(fieldCondition(fields));
            stage ::: ids ::: conditions ::: systemDates(given)
    }

    ///
    /// システムの日時の絞り込み。書いた口だけが条件になる。読めない値は Never（何にも合わない）に倒す。
    ///
    def systemDates(given: GeneratedAdmin.EntryWhere): Where =
        List.flatMap(match (key, filter) -> systemDateConditions(key, filter),
            (SystemDate.CreatedAt, given#createdAt) :: (SystemDate.UpdatedAt, given#updatedAt) :: (SystemDate.PublishedAt, given#publishedAt) :: Nil)

    def systemDateConditions(key: SystemDate, filter: Option[GeneratedAdmin.DateTimeFilter]): Where = match filter {
        case None       => Nil
        case Some(given) =>
            ((RangeOp.Gt, given#gt) :: (RangeOp.Gte, given#gte) :: (RangeOp.Lt, given#lt) :: (RangeOp.Lte, given#lte) :: Nil)
                |> List.filterMap(match (op, text) -> Option.map(systemDateCondition(key, op), text))
    }

    def systemDateCondition(key: SystemDate, op: RangeOp, text: String): Condition =
        DateValues.parse(text) |> Option.map(at -> Condition.SystemDateCmp(key, op, at)) |> Option.getWithDefault(Condition.Never)

    pub def contentStageOf(stage: GeneratedAdmin.ContentStage): Stage = match stage {
        case GeneratedAdmin.ContentStage.Draft     => Stage.Draft
        case GeneratedAdmin.ContentStage.Published => Stage.Published
    }

    /// フィールド 1 つの条件。純粋な写し（fieldConditionOf）の Err を invalid にする。
    def fieldCondition(fields: List[FieldDef], input: GeneratedAdmin.EntryFieldCondition): Condition \ CmsErr =
        fieldConditionOf(fields, input) |> CmsErr.okOrInvalid

    ///
    /// フィールド 1 つの条件を Condition に。純粋。
    ///
    /// - EQ: kind の型の値（NUMBER は数、BOOLEAN は真偽値、DATE は日時の文字列、それ以外は文字列）
    /// - IN: 文字列の配列
    /// - CONTAINS / STARTS_WITH: 文字列（文字列の kind だけ）
    /// - GT / GTE / LT / LTE: NUMBER は数、DATE は日時の文字列
    /// - IS_NULL: 真偽値（省けば true）
    /// - ARRAY_CONTAINS: 文字列（配列のフィールドだけ）
    ///
    /// 読めない日時は Never（何にも合わない）に倒す（コンテンツ API と同じ）。
    ///
    pub def fieldConditionOf(fields: List[FieldDef], input: GeneratedAdmin.EntryFieldCondition): Result[Violation, Condition] =
        let path = "where.fields.${input#apiId}";
        let value = input#value |> Option.getWithDefault(Value.Null);
        let wrong = expected -> Err(Violation.Violation(path, "value は${expected}で渡してください"));
        let unsupported = () -> Err(Violation.Violation(path, "この op はこのフィールドの kind には使えません"));
        match ApiId.parse(input#apiId) |> Option.flatMap(apiId -> List.find(field -> field#apiId == apiId, fields)) {
            case None        => Err(Violation.Violation(path, "'${input#apiId}' はこの型にありません"))
            case Some(field) =>
                let apiId = field#apiId;
                let textual = not List.memberOf(field#kind, FieldKind.Number :: FieldKind.Boolean :: FieldKind.Date :: FieldKind.DateOnly :: FieldKind.Object :: FieldKind.Blocks :: FieldKind.RichText :: Nil);
                match input#op {
                    case GeneratedAdmin.FieldConditionOp.IsNull => match value {
                        case Value.Null    => Ok(Condition.IsNull(apiId, true))
                        case Value.Bool(b) => Ok(Condition.IsNull(apiId, b))
                        case _             => wrong("真偽値")
                    }
                    case GeneratedAdmin.FieldConditionOp.ArrayContains =>
                        if (not field#many) unsupported() else match value {
                            case Value.Str(text) => Ok(Condition.ArrayContains(apiId, text))
                            case _               => wrong("文字列")
                        }
                    case GeneratedAdmin.FieldConditionOp.In =>
                        if (not textual or field#many) unsupported() else match value {
                            case Value.List(items) => items |> List.map(Value.asStr) |> Option.sequence |> Option.map(texts -> Condition.TextIn(apiId, texts)) |> Option.toOk(Violation.Violation(path, "value は文字列の配列で渡してください"))
                            case _                 => wrong("文字列の配列")
                        }
                    case GeneratedAdmin.FieldConditionOp.Contains =>
                        if (not textual or field#many) unsupported() else textOnly(wrong, value, text -> Condition.TextContains(apiId, text))
                    case GeneratedAdmin.FieldConditionOp.StartsWith =>
                        if (not textual or field#many) unsupported() else textOnly(wrong, value, text -> Condition.TextStartsWith(apiId, text))
                    case GeneratedAdmin.FieldConditionOp.Eq =>
                        if (field#many) unsupported() else match field#kind {
                            case FieldKind.Number  => numberOnly(wrong, value, x -> Condition.NumberEq(apiId, x))
                            case FieldKind.Boolean => match value { case Value.Bool(b) => Ok(Condition.BoolEq(apiId, b)) case _ => wrong("真偽値") }
                            case FieldKind.Date    => dateOnly(wrong, value, at -> Condition.DateEq(apiId, at))
                            case FieldKind.DateOnly => dayOnly(wrong, value, on -> Condition.DateOnlyEq(apiId, on))
                            case _                 => if (textual) textOnly(wrong, value, text -> Condition.TextEq(apiId, text)) else unsupported()
                        }
                    case GeneratedAdmin.FieldConditionOp.Gt  => rangeOf(field, wrong, unsupported, value, x -> Condition.NumberGt(apiId, x), at -> Condition.DateGt(apiId, at), on -> Condition.DateOnlyCmp(apiId, RangeOp.Gt, on))
                    case GeneratedAdmin.FieldConditionOp.Gte => rangeOf(field, wrong, unsupported, value, x -> Condition.NumberGte(apiId, x), at -> Condition.DateGte(apiId, at), on -> Condition.DateOnlyCmp(apiId, RangeOp.Gte, on))
                    case GeneratedAdmin.FieldConditionOp.Lt  => rangeOf(field, wrong, unsupported, value, x -> Condition.NumberLt(apiId, x), at -> Condition.DateLt(apiId, at), on -> Condition.DateOnlyCmp(apiId, RangeOp.Lt, on))
                    case GeneratedAdmin.FieldConditionOp.Lte => rangeOf(field, wrong, unsupported, value, x -> Condition.NumberLte(apiId, x), at -> Condition.DateLte(apiId, at), on -> Condition.DateOnlyCmp(apiId, RangeOp.Lte, on))
                }
        }

    /// 範囲の比較。NUMBER は数、DATE は日時、DATE_ONLY は日付、それ以外は使えない。
    def rangeOf(field: FieldDef, wrong: String -> Result[Violation, Condition], unsupported: Unit -> Result[Violation, Condition], value: Value,
                number: Float64 -> Condition, date: Timestamp.Timestamp -> Condition, day: Date.Date -> Condition): Result[Violation, Condition] =
        if (field#many) unsupported() else match field#kind {
            case FieldKind.Number   => numberOnly(wrong, value, number)
            case FieldKind.Date     => dateOnly(wrong, value, date)
            case FieldKind.DateOnly => dayOnly(wrong, value, day)
            case _                  => unsupported()
        }

    def textOnly(wrong: String -> Result[Violation, Condition], value: Value, make: String -> Condition): Result[Violation, Condition] = match value {
        case Value.Str(text) => Ok(make(text))
        case _               => wrong("文字列")
    }

    def numberOnly(wrong: String -> Result[Violation, Condition], value: Value, make: Float64 -> Condition): Result[Violation, Condition] = match value {
        case Value.Float(x) => Ok(make(x))
        case Value.Int(n)   => Ok(make(Int32.toFloat64(n)))
        case _              => wrong("数")
    }

    /// 日時の文字列。読めなければ Never（何にも合わない）。
    def dateOnly(wrong: String -> Result[Violation, Condition], value: Value, make: Timestamp.Timestamp -> Condition): Result[Violation, Condition] = match value {
        case Value.Str(text) => Ok(DateValues.parse(text) |> Option.map(make) |> Option.getWithDefault(Condition.Never))
        case _               => wrong("日時の文字列")
    }

    /// 日付の文字列。読めなければ Never（何にも合わない）。
    def dayOnly(wrong: String -> Result[Violation, Condition], value: Value, make: Date.Date -> Condition): Result[Violation, Condition] = match value {
        case Value.Str(text) => Ok(DateOnlyValues.parse(text) |> Option.map(make) |> Option.getWithDefault(Condition.Never))
        case _               => wrong("日付の文字列")
    }

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
            previewUrl = input#previewUrl,
            linkPath   = input#linkPath,
            icon       = input#icon
        }

    ///
    /// ContentTypePatch を Changes に。
    ///
    pub def typeChanges(patch: GeneratedAdmin.ContentTypePatch): ContentTypeChanges \ CmsErr =
        {
            name       = patch#name,
            singular   = patch#singular |> Option.map(typeName("singular")),
            plural     = patch#plural |> Option.map(apiId("plural")),
            previewUrl = patch#previewUrl,
            linkPath   = patch#linkPath,
            icon       = patch#icon
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
