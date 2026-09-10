///
/// 管理 API の type Query のリゾルバ。ID を読んでユースケースを呼ぶだけ。
///
mod AdminQueryResolvers {

    /// Query.contentTypes
    pub def contentTypes(): GeneratedAdmin.QueryContentTypesResolver[AdminEff] =
        _context -> Ok(listTypes())

    def listTypes(): List[ContentType] \ DbRead + CmsErr + Tenant + Session = ContentTypes.list(Session.grant())

    /// Query.contentType。id か apiId のどちらかで引く。両方無ければエラー
    pub def contentType(): GeneratedAdmin.QueryContentTypeResolver[AdminEff] =
        (_context, id, apiId) -> match (id, apiId) {
            case (Some(_), Some(_)) => Err(GraphqlErrors.invalid("apiId", "id か apiId のどちらか一方にしてください"))
            case (Some(given), _)   => Ok(findType(given))
            case (None, Some(text)) => Ok(findTypeByApiId(text))
            case (None, None)       => Err(GraphqlErrors.invalid("id", "id か apiId を指定してください"))
        }

    def findType(id: Id): Option[ContentType] \ DbRead + CmsErr + Tenant + Session = ContentTypes.find(Session.grant(), AdminMapping.typeId("id", id))

    def findTypeByApiId(text: String): Option[ContentType] \ DbRead + CmsErr + Tenant + Session =
        ApiId.parse(text) |> Option.flatMap(apiId -> ContentTypes.findByApiId(Session.grant(), apiId))

    /// Query.entries。first は 0 〜 200 に丸める
    pub def entries(): GeneratedAdmin.QueryEntriesResolver[AdminEff] =
        (_context, typeId, search, conditions, orderBy, first, skip, after) ->
            Ok(listEntries(typeId, search |> Option.getWithDefault(""), conditions, orderBy, EntryPage.clamp(50, first, skip), after))

    ///
    /// where / orderBy を写して一覧を引く。フィールドで絞る・並べる時だけ型の定義を引く（kind で式が決まる。それ以外は SQL を増やさない）。
    /// after は orderBy と対で復号し、skip との同時指定は invalid。
    ///
    def listEntries(typeId: Id, search: String, conditions: Option[GeneratedAdmin.EntryWhere], orderBy: Option[List[GeneratedAdmin.EntryOrderBy]], page: (Int32, Int32), after: Option[String]): EntryPage \ DbRead + CmsErr + Tenant + Session + Preloaded =
        let id = AdminMapping.typeId("typeId", typeId);
        let order = AdminMapping.entryOrderBy(orderBy);
        let fields = if (OrderBy.hasField(order) or AdminMapping.whereNeedsFields(conditions)) ContentTypes.get(Session.grant(), id)#fields else Nil;
        let (first, skip) = page;
        listKeepingIds(id, fields, {
            search = search, filter = AdminMapping.entryWhere(fields, conditions), orderBy = order, first = first,
            start = Cursor.pageStart(order, skip, after) |> CmsErr.okOrInvalid
        })

    /// 一覧を引き、ページの entry id を先読みの写しに覚える（行の versions / diff がまとめて引くため。SQL は増えない）。
    def listKeepingIds(typeId: TypeId, fields: List[FieldDef], entryQuery: EntryQuery): EntryPage \ DbRead + CmsErr + Tenant + Session + Preloaded =
        let page = ContentEntries.list(Session.grant(), typeId, fields, entryQuery);
        Preloaded.keepEntryIds(page#entries |> List.map(entry -> entry#id));
        page

    /// Query.entry
    pub def entry(): GeneratedAdmin.QueryEntryResolver[AdminEff] =
        (_context, id) -> Ok(findEntry(id))

    def findEntry(id: Id): Option[Entry] \ DbRead + CmsErr + Tenant + Session = ContentEntries.find(Session.grant(), AdminMapping.entryId("id", id))

    /// Query.assets。first は 0 〜 200 に丸める
    pub def assets(): GeneratedAdmin.QueryAssetsResolver[AdminEff] =
        (_context, first, skip, after) -> Ok(listAssets(EntryPage.clamp(50, first, skip), after))

    /// after は作成が新しい順の cursor として復号し、skip との同時指定は invalid。
    def listAssets(page: (Int32, Int32), after: Option[String]): AssetPage \ DbRead + CmsErr + Tenant + Session =
        let (first, skip) = page;
        Assets.list(Session.grant(), first, Cursor.pageStart(Cursor.assetOrderBy(), skip, after) |> CmsErr.okOrInvalid)

    /// Query.asset
    pub def asset(): GeneratedAdmin.QueryAssetResolver[AdminEff] =
        (_context, id) -> Ok(findAsset(id))

    def findAsset(id: Id): Option[Asset] \ DbRead + CmsErr + Tenant + Session = Assets.find(Session.grant(), AdminMapping.assetId("id", id))

    /// Query.publishCheck（dry-run）
    pub def publishCheck(): GeneratedAdmin.QueryPublishCheckResolver[AdminEff] =
        (_context, id) -> Ok(publishReportOf(id))

    def publishReportOf(id: Id): PublishReport \ DbRead + CmsErr + Tenant + Session = ContentEntries.publishReport(Session.grant(), AdminMapping.entryId("id", id))

    /// Query.impact
    pub def impact(): GeneratedAdmin.QueryImpactResolver[AdminEff] =
        (_context, id, action) -> Ok(impactOf(id, action))

    def impactOf(id: Id, action: GeneratedAdmin.ImpactAction): Impact \ DbRead + CmsErr + Tenant + Session =
        ContentEntries.impact(Session.grant(), AdminMapping.entryId("id", id), AdminMapping.impactActionOf(action))

    ///
    /// Query.fieldImpact（スキーマの dry-run）。書き込まない。
    ///
    pub def fieldImpact(): GeneratedAdmin.QueryFieldImpactResolver[AdminEff] =
        (_context, input) -> Ok(impactFor(input))

    /// 押した後の姿を組み立てて差を取り、当たる entry を数える。ラムダの中で effect を使わないための切り出し。
    def impactFor(input: GeneratedAdmin.SchemaChangeInput): SchemaImpact \ DbRead + CmsErr + Tenant + Session =
        let edit = AdminMapping.schemaEdit(input);
        let changes = SchemaPreview.changesFor(edit, ContentTypes.list(Session.grant()));
        let (fields, types) = SchemaCounts.forChanges(changes);
        let effects = FieldImpact.of(changes, fields, types);
        { safe = List.isEmpty(effects), effects = effects }

    /// Query.publishPlan（まとめて dry-run）。withDependencies の既定は true
    pub def publishPlan(): GeneratedAdmin.QueryPublishPlanResolver[AdminEff] =
        (_context, ids, withDependencies) -> Ok(planFor(ids, withDependencies))

    /// ids を読んで計画を作る。ラムダの中で effect を使わないための切り出し（VerifyError）。
    def planFor(ids: List[Id], withDependencies: Option[Bool]): PublishPlan \ DbRead + CmsErr + Tenant + Session =
        ContentEntries.publishPlan(Session.grant(), ids |> List.map(AdminMapping.entryId("ids")), withDependencies |> Option.getWithDefault(true))

    /// Query.viewer。今の主体をそのまま見せる（DB は引かない）
    pub def viewer(): GeneratedAdmin.QueryViewerResolver[AdminEff] =
        _context -> Ok(currentViewer())

    /// 今の主体の見え方。ラムダの中で effect を使わないための切り出し（VerifyError）。
    def currentViewer(): Viewer \ Session = Authz.viewerOf(Session.current())

    /// Query.me
    pub def me(): GeneratedAdmin.QueryMeResolver[AdminEff] =
        _context -> Ok(Accounts.me())

    /// Query.members
    pub def members(): GeneratedAdmin.QueryMembersResolver[AdminEff] =
        _context -> Ok(listMembers())

    def listMembers(): List[Member] \ DbRead + CmsErr + Tenant + Session = Members.list(Session.grant())

    /// Query.invitations
    pub def invitations(): GeneratedAdmin.QueryInvitationsResolver[AdminEff] =
        _context -> Ok(listInvitations())

    def listInvitations(): List[Invitation] \ DbRead + CmsErr + Tenant + Session = Members.invitations(Session.grant())

    /// Query.webhooks
    pub def webhooks(): GeneratedAdmin.QueryWebhooksResolver[AdminEff] =
        _context -> Ok(listWebhooks())

    def listWebhooks(): List[Webhook] \ DbRead + CmsErr + Tenant + Session = Webhooks.list(Session.grant())

    /// Query.webhookDeliveries
    pub def webhookDeliveries(): GeneratedAdmin.QueryWebhookDeliveriesResolver[AdminEff] =
        (_context, webhookId, first, after) -> Ok(listDeliveries(webhookId, first, after))

    /// after は配信の id（ULID）そのもの。
    def listDeliveries(webhookId: Id, first: Option[Int32], after: Option[Id]): List[WebhookDelivery] \ DbRead + CmsErr + Tenant + Session =
        Webhooks.deliveries(Session.grant(), AdminMapping.publicIdOf(webhookId), EntryPage.clamp(20, first, None) |> fst, after |> Option.map(AdminMapping.publicIdOf))

    /// Query.auditEvents
    pub def auditEvents(): GeneratedAdmin.QueryAuditEventsResolver[AdminEff] =
        (_context, first, after) -> Ok(listAuditEvents(first, after))

    /// 監査の記録。新しい順。after は前のページの最後の id。
    def listAuditEvents(first: Option[Int32], after: Option[Id]): List[AuditEvent] \ DbRead + CmsErr + Tenant + Session =
        Audit.recent(Session.grant(), EntryPage.clamp(50, first, None) |> fst |> Int32.toInt64, after |> Option.map(AdminMapping.publicIdOf))

    /// Query.schedules
    pub def schedules(): GeneratedAdmin.QuerySchedulesResolver[AdminEff] =
        (_context, entryId, first, after) -> Ok(listSchedules(entryId, first, after))

    /// after は予約の id（ULID）そのもの。
    def listSchedules(entryId: Option[Id], first: Option[Int32], after: Option[Id]): List[Schedule] \ DbRead + CmsErr + Tenant + Session =
        Schedules.list(Session.grant(), entryId |> Option.map(AdminMapping.entryId("entryId")), EntryPage.clamp(50, first, None) |> fst, after |> Option.map(AdminMapping.publicIdOf))

    /// Query.apiKeys
    pub def apiKeys(): GeneratedAdmin.QueryApiKeysResolver[AdminEff] =
        _context -> Ok(listApiKeys())

    def listApiKeys(): List[ApiKey] \ DbRead + CmsErr + Tenant + Session = ApiKeys.list(Session.grant())

    /// type Query のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.QueryResolvers[AdminEff] =
        { contentTypes = contentTypes(), contentType = contentType(), entries = entries(), entry = entry(), assets = assets(), asset = asset(),
          publishCheck = publishCheck(), impact = impact(), fieldImpact = fieldImpact(), publishPlan = publishPlan(), viewer = viewer(), me = me(), members = members(), invitations = invitations(), apiKeys = apiKeys(), webhooks = webhooks(), webhookDeliveries = webhookDeliveries(), schedules = schedules(), auditEvents = auditEvents() }

}
