///
/// 管理 API の type Mutation のリゾルバ。入力をドメインの型に写してユースケースを呼ぶだけ。
///
mod AdminMutationResolvers {

    /// Mutation.createContentType
    pub def createContentType(): GeneratedAdmin.MutationCreateContentTypeResolver[AdminEff] =
        (_context, input) -> Ok(createType(input))

    def createType(input: GeneratedAdmin.ContentTypeInput): ContentType \ Db + CmsErr + IdGen + Tenant + Session =
        ContentTypes.create(Session.grant(), AdminMapping.typeDraft(input))

    /// Mutation.updateContentType
    pub def updateContentType(): GeneratedAdmin.MutationUpdateContentTypeResolver[AdminEff] =
        (_context, id, patch) -> Ok(updateType(id, patch))

    def updateType(id: Id, patch: GeneratedAdmin.ContentTypePatch): ContentType \ Db + CmsErr + IdGen + Tenant + Session =
        ContentTypes.update(Session.grant(), AdminMapping.typeId("id", id), AdminMapping.typeChanges(patch))

    /// Mutation.deleteContentType。消した id を返す
    pub def deleteContentType(): GeneratedAdmin.MutationDeleteContentTypeResolver[AdminEff] =
        (_context, id) -> { deleteType(id); Ok(id) }

    def deleteType(id: Id): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        ContentTypes.delete(Session.grant(), AdminMapping.typeId("id", id))

    /// Mutation.addField
    pub def addField(): GeneratedAdmin.MutationAddFieldResolver[AdminEff] =
        (_context, typeId, input) -> Ok(addFieldTo(typeId, input))

    def addFieldTo(typeId: Id, input: GeneratedAdmin.FieldInput): FieldDef \ Db + CmsErr + IdGen + Tenant + Session =
        ContentTypes.addField(Session.grant(), AdminMapping.typeId("typeId", typeId), AdminMapping.fieldDraft(input))

    /// Mutation.updateField
    pub def updateField(): GeneratedAdmin.MutationUpdateFieldResolver[AdminEff] =
        (_context, id, patch) -> Ok(updateFieldOf(id, patch))

    def updateFieldOf(id: Id, patch: GeneratedAdmin.FieldPatch): FieldDef \ Db + CmsErr + IdGen + Tenant + Session =
        ContentTypes.updateField(Session.grant(), AdminMapping.fieldId("id", id), AdminMapping.fieldChanges(patch))

    /// Mutation.removeField。消した id を返す
    pub def removeField(): GeneratedAdmin.MutationRemoveFieldResolver[AdminEff] =
        (_context, id) -> { removeFieldOf(id); Ok(id) }

    def removeFieldOf(id: Id): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        ContentTypes.removeField(Session.grant(), AdminMapping.fieldId("id", id))

    /// Mutation.reorderFields
    pub def reorderFields(): GeneratedAdmin.MutationReorderFieldsResolver[AdminEff] =
        (_context, typeId, ids) -> Ok(reorderFieldsOf(typeId, ids))

    def reorderFieldsOf(typeId: Id, ids: List[Id]): ContentType \ Db + CmsErr + IdGen + Tenant + Session =
        ContentTypes.reorderFields(Session.grant(), AdminMapping.typeId("typeId", typeId), ids |> List.map(AdminMapping.fieldId("ids")))

    /// Mutation.createEntry
    pub def createEntry(): GeneratedAdmin.MutationCreateEntryResolver[AdminEff] =
        (_context, typeId, fields, id) -> Ok(ContentEntries.create(
            AdminMapping.typeId("typeId", typeId),
            id |> Option.map(AdminMapping.entryId("id")),
            AdminMapping.entryData("fields", fields)))

    /// Mutation.updateEntry
    pub def updateEntry(): GeneratedAdmin.MutationUpdateEntryResolver[AdminEff] =
        (_context, id, fields, expectedVersion) -> Ok(ContentEntries.update(AdminMapping.entryId("id", id), AdminMapping.entryData("fields", fields), expectedVersion))

    /// Mutation.deleteEntry。消した id を返す
    pub def deleteEntry(): GeneratedAdmin.MutationDeleteEntryResolver[AdminEff] =
        (_context, id) -> { ContentEntries.delete(AdminMapping.entryId("id", id)); Ok(id) }

    /// Mutation.publishEntry
    pub def publishEntry(): GeneratedAdmin.MutationPublishEntryResolver[AdminEff] =
        (_context, id, withDependencies) -> Ok(ContentEntries.publish(AdminMapping.entryId("id", id), Session.displayName(), withDependencies |> Option.getWithDefault(false)))

    /// Mutation.unpublishEntry
    pub def unpublishEntry(): GeneratedAdmin.MutationUnpublishEntryResolver[AdminEff] =
        (_context, id) -> Ok(ContentEntries.unpublish(AdminMapping.entryId("id", id)))

    /// Mutation.saveVersion
    pub def saveVersion(): GeneratedAdmin.MutationSaveVersionResolver[AdminEff] =
        (_context, id) -> Ok(ContentEntries.saveVersion(AdminMapping.entryId("id", id), Session.displayName()))

    /// Mutation.restoreVersion
    pub def restoreVersion(): GeneratedAdmin.MutationRestoreVersionResolver[AdminEff] =
        (_context, id, versionId, expectedVersion) -> Ok(ContentEntries.restoreVersion(AdminMapping.entryId("id", id), AdminMapping.versionId("versionId", versionId), expectedVersion))

    /// Mutation.createUploadUrl
    pub def createUploadUrl(): GeneratedAdmin.MutationCreateUploadUrlResolver[AdminEff] =
        (_context, input) -> Ok(createUpload(input))

    def createUpload(input: GeneratedAdmin.UploadInput): Upload \ Db + CmsErr + IdGen + Tenant + ObjectStore + Session =
        Assets.createUpload(Session.grant(), AdminMapping.uploadRequest(input))

    /// Mutation.confirmAsset。input を省けば寸法も alt も無し
    pub def confirmAsset(): GeneratedAdmin.MutationConfirmAssetResolver[AdminEff] =
        (_context, id, input) -> Ok(confirmUpload(id, input))

    def confirmUpload(id: Id, input: Option[GeneratedAdmin.AssetConfirmInput]): Asset \ Db + CmsErr + Tenant + ObjectStore + Session =
        Assets.confirm(Session.grant(), AdminMapping.assetId("id", id), AdminMapping.assetConfirm(input))

    /// Mutation.updateAsset
    pub def updateAsset(): GeneratedAdmin.MutationUpdateAssetResolver[AdminEff] =
        (_context, id, patch) -> Ok(updateAssetAlt(id, patch#alt))

    def updateAssetAlt(id: Id, alt: String): Asset \ Db + CmsErr + Tenant + Session =
        Assets.updateAlt(Session.grant(), AdminMapping.assetId("id", id), alt)

    /// Mutation.deleteAsset。消した id を返す
    pub def deleteAsset(): GeneratedAdmin.MutationDeleteAssetResolver[AdminEff] =
        (_context, id) -> { deleteAssetOf(id); Ok(id) }

    def deleteAssetOf(id: Id): Unit \ Db + CmsErr + Tenant + ObjectStore + Session =
        Assets.delete(Session.grant(), AdminMapping.assetId("id", id))

    /// Mutation.updateProjectVisibility
    pub def updateProjectVisibility(): GeneratedAdmin.MutationUpdateProjectVisibilityResolver[AdminEff] =
        (_context, visibility) -> Ok(updateVisibility(visibility))

    def updateVisibility(visibility: GeneratedAdmin.Visibility): Project \ Db + CmsErr + Tenant + Session =
        Projects.updateVisibility(Session.grant(), AdminMapping.visibilityOf(visibility))

    /// Mutation.inviteMember
    pub def inviteMember(): GeneratedAdmin.MutationInviteMemberResolver[AdminEff] =
        (_context, email, role) -> Ok(Members.invite(email, AdminMapping.roleOf(role)))

    /// Mutation.cancelInvitation。消した id を返す
    pub def cancelInvitation(): GeneratedAdmin.MutationCancelInvitationResolver[AdminEff] =
        (_context, id) -> { Members.cancelInvitation(AdminMapping.publicIdOf(id)); Ok(id) }

    /// Mutation.changeMemberRole
    pub def changeMemberRole(): GeneratedAdmin.MutationChangeMemberRoleResolver[AdminEff] =
        (_context, userId, role) -> Ok(Members.changeRole(AdminMapping.userId("userId", userId), AdminMapping.roleOf(role)))

    /// Mutation.removeMember。外した id を返す
    pub def removeMember(): GeneratedAdmin.MutationRemoveMemberResolver[AdminEff] =
        (_context, userId) -> { Members.remove(AdminMapping.userId("userId", userId)); Ok(userId) }

    /// Mutation.createApiKey。pepper が無ければ発行できない
    pub def createApiKey(deps: Deps): GeneratedAdmin.MutationCreateApiKeyResolver[AdminEff] =
        (_context, name, scope, role, expiresAt) -> match deps#auth#pepper {
            case Some(pepper) => Ok(ApiKeys.create(pepper, {
                name = name, scope = AdminMapping.apiKeyScopeOf(scope, role),
                expiresAt = expiresAt |> Option.map(text -> AdminMapping.timestampOf("expiresAt", text)) }, Time.Clock.now()))
            case None         => Err(FieldError.internal("API キーを発行できません（CMS_API_KEY_PEPPER が設定されていません）"))
        }

    /// Mutation.revokeApiKey。失効した id を返す
    pub def revokeApiKey(): GeneratedAdmin.MutationRevokeApiKeyResolver[AdminEff] =
        (_context, id) -> { ApiKeys.revoke(AdminMapping.publicIdOf(id)); Ok(id) }

    /// Mutation.createPreviewToken。pepper が無ければ発行できない
    pub def createPreviewToken(deps: Deps): GeneratedAdmin.MutationCreatePreviewTokenResolver[AdminEff] =
        (_context, entryId, expiresInSeconds) -> match deps#auth#pepper {
            case Some(pepper) => Ok(PreviewTokens.issue(pepper, AdminMapping.entryId("entryId", entryId), { ttlSeconds = expiresInSeconds |> Option.map(Int32.toInt64) |> Option.getWithDefault(PreviewTokens.defaultTtlSeconds()), nowMillis = Time.Clock.now() }))
            case None         => Err(FieldError.internal("プレビュートークンを発行できません（CMS_API_KEY_PEPPER が設定されていません）"))
        }

    /// Mutation.schedulePublish
    pub def schedulePublish(): GeneratedAdmin.MutationSchedulePublishResolver[AdminEff] =
        (_context, entryId, at, withDependencies) ->
            Ok(Schedules.schedule(AdminMapping.entryId("entryId", entryId), ScheduleAction.Publish, AdminMapping.timestampOf("at", at), withDependencies |> Option.getWithDefault(false)))

    /// Mutation.scheduleUnpublish
    pub def scheduleUnpublish(): GeneratedAdmin.MutationScheduleUnpublishResolver[AdminEff] =
        (_context, entryId, at) -> Ok(Schedules.schedule(AdminMapping.entryId("entryId", entryId), ScheduleAction.Unpublish, AdminMapping.timestampOf("at", at), false))

    /// Mutation.cancelSchedule
    pub def cancelSchedule(): GeneratedAdmin.MutationCancelScheduleResolver[AdminEff] =
        (_context, id) -> Ok(Schedules.cancel(AdminMapping.publicIdOf(id)))

    /// Mutation.createWebhook
    pub def createWebhook(): GeneratedAdmin.MutationCreateWebhookResolver[AdminEff] =
        (_context, input) -> Ok(Webhooks.create(AdminMapping.webhookDraftOf(input)))

    /// Mutation.updateWebhook
    pub def updateWebhook(): GeneratedAdmin.MutationUpdateWebhookResolver[AdminEff] =
        (_context, id, input) -> Ok(Webhooks.update(AdminMapping.publicIdOf(id), AdminMapping.webhookDraftOf(input)))

    /// Mutation.deleteWebhook。消した id を返す
    pub def deleteWebhook(): GeneratedAdmin.MutationDeleteWebhookResolver[AdminEff] =
        (_context, id) -> { Webhooks.delete(AdminMapping.publicIdOf(id)); Ok(id) }

    /// Mutation.redeliverWebhook
    pub def redeliverWebhook(): GeneratedAdmin.MutationRedeliverWebhookResolver[AdminEff] =
        (_context, deliveryId) -> Ok(Webhooks.redeliver(AdminMapping.publicIdOf(deliveryId)))

    /// type Mutation のリゾルバ一式
    pub def resolvers(deps: Deps): GeneratedAdmin.MutationResolvers[AdminEff] =
        {
            createContentType = createContentType(),
            updateContentType = updateContentType(),
            deleteContentType = deleteContentType(),
            addField          = addField(),
            updateField       = updateField(),
            removeField       = removeField(),
            reorderFields     = reorderFields(),
            createEntry       = createEntry(),
            updateEntry       = updateEntry(),
            deleteEntry       = deleteEntry(),
            publishEntry      = publishEntry(),
            unpublishEntry    = unpublishEntry(),
            saveVersion       = saveVersion(),
            restoreVersion    = restoreVersion(),
            createUploadUrl   = createUploadUrl(),
            confirmAsset      = confirmAsset(),
            updateAsset       = updateAsset(),
            deleteAsset       = deleteAsset(),
            updateProjectVisibility = updateProjectVisibility(),
            inviteMember            = inviteMember(),
            cancelInvitation        = cancelInvitation(),
            changeMemberRole        = changeMemberRole(),
            removeMember            = removeMember(),
            createApiKey            = createApiKey(deps),
            revokeApiKey            = revokeApiKey(),
            createPreviewToken      = createPreviewToken(deps),
            schedulePublish         = schedulePublish(),
            scheduleUnpublish       = scheduleUnpublish(),
            cancelSchedule          = cancelSchedule(),
            createWebhook           = createWebhook(),
            updateWebhook           = updateWebhook(),
            deleteWebhook           = deleteWebhook(),
            redeliverWebhook        = redeliverWebhook()
        }

}
