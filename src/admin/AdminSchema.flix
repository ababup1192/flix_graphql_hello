///
/// 管理 API のスキーマ。admin.graphql から生成された GeneratedAdmin.Resolvers に、src/admin/ の型ごとのリゾルバを当てはめる。
///
mod AdminSchema {

    ///
    /// スキーマを組み立てる。runner は AdminEff を IO に落とす（本番はプール、テストはメモリ）。
    ///
    pub def make(deps: Deps, runner: Runner[AdminEff]): Schema =
        GeneratedAdmin.schema({
            queryRoot    = AdminQueryResolvers.resolvers(deps),
            mutationRoot = AdminMutationResolvers.resolvers(deps),
            me                     = MeResolvers.resolvers(),
            viewer                 = ViewerResolvers.resolvers(),
            organization           = OrganizationResolvers.resolvers(),
            organizationMembership = OrganizationMembershipResolvers.resolvers(),
            project_               = ProjectResolvers.resolvers(),
            projectMembership      = ProjectMembershipResolvers.resolvers(),
            member                 = MemberResolvers.resolvers(),
            invitation             = InvitationResolvers.resolvers(),
            apiKey                 = ApiKeyResolvers.resolvers(),
            issuedApiKey           = IssuedApiKeyResolvers.resolvers(),
            previewToken           = PreviewTokenResolvers.resolvers(),
            schedule               = ScheduleResolvers.resolvers(),
            linkCard               = LinkCardResolvers.resolvers(),
            auditEvent             = AuditResolvers.resolvers(),
            webhook                = WebhookResolvers.resolvers(),
            issuedWebhook          = IssuedWebhookResolvers.resolvers(),
            webhookDelivery        = WebhookDeliveryResolvers.resolvers(),
            asset        = AssetResolvers.resolvers(),
            assetPage    = AssetPageResolvers.resolvers(),
            assetEdge    = AssetEdgeResolvers.resolvers(),
            pageInfo     = PageInfoResolvers.resolvers(),
            upload       = UploadResolvers.resolvers(),
            focalPoint   = GeneratedAdmin.focalPointDefaults(),
            cropRect     = GeneratedAdmin.cropRectDefaults(),
            violation     = ViolationResolvers.resolvers(),
            publishReport = PublishReportResolvers.resolvers(),
            publishPlanStep = PublishPlanStepResolvers.resolvers(),
            publishPlan   = PublishPlanResolvers.resolvers(),
            referrer      = ReferrerResolvers.resolvers(),
            impact        = ImpactResolvers.resolvers(),
            schemaEffect  = SchemaEffectResolvers.resolvers(),
            schemaImpact  = SchemaImpactResolvers.resolvers(),
            entry        = EntryResolvers.resolvers(),
            entryVersion = EntryVersionResolvers.resolvers(),
            entryAutosave = EntryAutosaveResolvers.resolvers(),
            fieldChange  = FieldChangeResolvers.resolvers(),
            diffLine     = DiffLineResolvers.resolvers(),
            entryPage    = EntryPageResolvers.resolvers(),
            entryEdge    = EntryEdgeResolvers.resolvers(),
            contentType  = ContentTypeResolvers.resolvers(),
            fieldDef     = FieldDefResolvers.resolvers(),
            fieldConfig  = FieldConfigResolvers.resolvers()
        }, runner)

}
