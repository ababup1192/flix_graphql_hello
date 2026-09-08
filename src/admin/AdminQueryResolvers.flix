///
/// 管理 API の type Query のリゾルバ。ID を読んでユースケースを呼ぶだけ。
///
mod AdminQueryResolvers {

    /// Query.contentTypes
    pub def contentTypes(): GeneratedAdmin.QueryContentTypesResolver[AdminEff] =
        _context -> Ok(ContentTypes.list())

    /// Query.contentType。id か apiId のどちらかで引く。両方無ければエラー
    pub def contentType(): GeneratedAdmin.QueryContentTypeResolver[AdminEff] =
        (_context, id, apiId) -> match (id, apiId) {
            case (Some(_), Some(_)) => Err(GraphqlErrors.invalid("apiId", "id か apiId のどちらか一方にしてください"))
            case (Some(given), _)   => Ok(ContentTypes.find(AdminMapping.typeId("id", given)))
            case (None, Some(text)) => Ok(ApiId.parse(text) |> Option.flatMap(ContentTypes.findByApiId))
            case (None, None)       => Err(GraphqlErrors.invalid("id", "id か apiId を指定してください"))
        }

    /// Query.entries。first は 0 〜 200 に丸める
    pub def entries(): GeneratedAdmin.QueryEntriesResolver[AdminEff] =
        (_context, typeId, search, first, skip) -> {
            let (limit, offset) = EntryPage.clamp(50, first, skip);
            Ok(listKeepingIds(AdminMapping.typeId("typeId", typeId), { search = search |> Option.getWithDefault(""), first = limit, skip = offset }))
        }

    /// 一覧を引き、ページの entry id を先読みの写しに覚える（行の versions / diff がまとめて引くため。SQL は増えない）。
    def listKeepingIds(typeId: TypeId, entryQuery: EntryQuery): EntryPage \ DbRead + CmsErr + Tenant + Session + Preloaded =
        let page = ContentEntries.list(typeId, entryQuery);
        Preloaded.keepEntryIds(page#entries |> List.map(entry -> entry#id));
        page

    /// Query.entry
    pub def entry(): GeneratedAdmin.QueryEntryResolver[AdminEff] =
        (_context, id) -> Ok(ContentEntries.find(AdminMapping.entryId("id", id)))

    /// Query.assets。first は 0 〜 200 に丸める
    pub def assets(): GeneratedAdmin.QueryAssetsResolver[AdminEff] =
        (_context, first, skip) -> {
            let (limit, offset) = EntryPage.clamp(50, first, skip);
            Ok(Assets.list(limit, offset))
        }

    /// Query.asset
    pub def asset(): GeneratedAdmin.QueryAssetResolver[AdminEff] =
        (_context, id) -> Ok(Assets.find(AdminMapping.assetId("id", id)))

    /// Query.publishCheck（dry-run）
    pub def publishCheck(): GeneratedAdmin.QueryPublishCheckResolver[AdminEff] =
        (_context, id) -> Ok(ContentEntries.publishReport(AdminMapping.entryId("id", id)))

    /// Query.impact
    pub def impact(): GeneratedAdmin.QueryImpactResolver[AdminEff] =
        (_context, id, action) -> Ok(ContentEntries.impact(AdminMapping.entryId("id", id), AdminMapping.impactActionOf(action)))

    /// Query.publishPlan（まとめて dry-run）。withDependencies の既定は true
    pub def publishPlan(): GeneratedAdmin.QueryPublishPlanResolver[AdminEff] =
        (_context, ids, withDependencies) -> Ok(planFor(ids, withDependencies))

    /// ids を読んで計画を作る。ラムダの中で effect を使わないための切り出し（VerifyError）。
    def planFor(ids: List[Id], withDependencies: Option[Bool]): PublishPlan \ DbRead + CmsErr + Tenant + Session =
        ContentEntries.publishPlan(ids |> List.map(AdminMapping.entryId("ids")), withDependencies |> Option.getWithDefault(true))

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
        _context -> Ok(Members.list())

    /// Query.invitations
    pub def invitations(): GeneratedAdmin.QueryInvitationsResolver[AdminEff] =
        _context -> Ok(Members.invitations())

    /// Query.webhooks
    pub def webhooks(): GeneratedAdmin.QueryWebhooksResolver[AdminEff] =
        _context -> Ok(Webhooks.list())

    /// Query.webhookDeliveries
    pub def webhookDeliveries(): GeneratedAdmin.QueryWebhookDeliveriesResolver[AdminEff] =
        (_context, webhookId, first) -> Ok(Webhooks.deliveries(AdminMapping.publicIdOf(webhookId), EntryPage.clamp(20, first, None) |> fst))

    /// Query.schedules
    pub def schedules(): GeneratedAdmin.QuerySchedulesResolver[AdminEff] =
        (_context, entryId, first) -> Ok(Schedules.list(entryId |> Option.map(AdminMapping.entryId("entryId")), EntryPage.clamp(50, first, None) |> fst))

    /// Query.apiKeys
    pub def apiKeys(): GeneratedAdmin.QueryApiKeysResolver[AdminEff] =
        _context -> Ok(ApiKeys.list())

    /// type Query のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.QueryResolvers[AdminEff] =
        { contentTypes = contentTypes(), contentType = contentType(), entries = entries(), entry = entry(), assets = assets(), asset = asset(),
          publishCheck = publishCheck(), impact = impact(), publishPlan = publishPlan(), viewer = viewer(), me = me(), members = members(), invitations = invitations(), apiKeys = apiKeys(), webhooks = webhooks(), webhookDeliveries = webhookDeliveries(), schedules = schedules() }

}
