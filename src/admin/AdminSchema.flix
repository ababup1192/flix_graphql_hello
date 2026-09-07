///
/// 管理 API のスキーマ。admin.graphql から生成された GeneratedAdmin.Resolvers に、src/admin/ の型ごとのリゾルバを当てはめる。
///
mod AdminSchema {

    ///
    /// スキーマを組み立てる。runner は AdminEff を IO に落とす（本番はプール、テストはメモリ）。
    ///
    pub def make(deps: Deps, runner: Runner[AdminEff]): Schema =
        GeneratedAdmin.schema({
            queryRoot    = AdminQueryResolvers.resolvers(),
            mutationRoot = AdminMutationResolvers.resolvers(deps),
            me                     = MeResolvers.resolvers(),
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
            webhook                = WebhookResolvers.resolvers(),
            issuedWebhook          = IssuedWebhookResolvers.resolvers(),
            webhookDelivery        = WebhookDeliveryResolvers.resolvers(),
            asset        = AssetResolvers.resolvers(),
            assetPage    = AssetPageResolvers.resolvers(),
            upload       = UploadResolvers.resolvers(),
            violation     = ViolationResolvers.resolvers(),
            publishReport = PublishReportResolvers.resolvers(),
            referrer      = ReferrerResolvers.resolvers(),
            impact        = ImpactResolvers.resolvers(),
            entry        = EntryResolvers.resolvers(),
            entryVersion = EntryVersionResolvers.resolvers(),
            fieldChange  = FieldChangeResolvers.resolvers(),
            diffLine     = DiffLineResolvers.resolvers(),
            entryPage    = EntryPageResolvers.resolvers(),
            contentType  = ContentTypeResolvers.resolvers(),
            fieldDef     = FieldDefResolvers.resolvers(),
            fieldConfig  = FieldConfigResolvers.resolvers()
        }, runner)

}
