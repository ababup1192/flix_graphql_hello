///
/// 管理 API の type Mutation のリゾルバ。入力をドメインの型に写してユースケースを呼ぶだけ。
///
mod AdminMutationResolvers {

    /// Mutation.createContentType
    pub def createContentType(): GeneratedAdmin.MutationCreateContentTypeResolver[AdminEff] =
        (_context, input) -> Ok(ContentTypes.create(AdminMapping.typeDraft(input)))

    /// Mutation.updateContentType
    pub def updateContentType(): GeneratedAdmin.MutationUpdateContentTypeResolver[AdminEff] =
        (_context, id, patch) -> Ok(ContentTypes.update(AdminMapping.typeId("id", id), AdminMapping.typeChanges(patch)))

    /// Mutation.deleteContentType。消した id を返す
    pub def deleteContentType(): GeneratedAdmin.MutationDeleteContentTypeResolver[AdminEff] =
        (_context, id) -> { ContentTypes.delete(AdminMapping.typeId("id", id)); Ok(id) }

    /// Mutation.addField
    pub def addField(): GeneratedAdmin.MutationAddFieldResolver[AdminEff] =
        (_context, typeId, input) -> Ok(ContentTypes.addField(AdminMapping.typeId("typeId", typeId), AdminMapping.fieldDraft(input)))

    /// Mutation.updateField
    pub def updateField(): GeneratedAdmin.MutationUpdateFieldResolver[AdminEff] =
        (_context, id, patch) -> Ok(ContentTypes.updateField(AdminMapping.fieldId("id", id), AdminMapping.fieldChanges(patch)))

    /// Mutation.removeField。消した id を返す
    pub def removeField(): GeneratedAdmin.MutationRemoveFieldResolver[AdminEff] =
        (_context, id) -> { ContentTypes.removeField(AdminMapping.fieldId("id", id)); Ok(id) }

    /// Mutation.reorderFields
    pub def reorderFields(): GeneratedAdmin.MutationReorderFieldsResolver[AdminEff] =
        (_context, typeId, ids) -> Ok(ContentTypes.reorderFields(AdminMapping.typeId("typeId", typeId), ids |> List.map(AdminMapping.fieldId("ids"))))

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
        (context, id, withDependencies) -> Ok(ContentEntries.publish(AdminMapping.entryId("id", id), AdminMapping.authorOf(context), withDependencies |> Option.getWithDefault(false)))

    /// Mutation.unpublishEntry
    pub def unpublishEntry(): GeneratedAdmin.MutationUnpublishEntryResolver[AdminEff] =
        (_context, id) -> Ok(ContentEntries.unpublish(AdminMapping.entryId("id", id)))

    /// Mutation.saveVersion
    pub def saveVersion(): GeneratedAdmin.MutationSaveVersionResolver[AdminEff] =
        (context, id) -> Ok(ContentEntries.saveVersion(AdminMapping.entryId("id", id), AdminMapping.authorOf(context)))

    /// Mutation.restoreVersion
    pub def restoreVersion(): GeneratedAdmin.MutationRestoreVersionResolver[AdminEff] =
        (_context, id, versionId, expectedVersion) -> Ok(ContentEntries.restoreVersion(AdminMapping.entryId("id", id), AdminMapping.versionId("versionId", versionId), expectedVersion))

    /// Mutation.createUploadUrl
    pub def createUploadUrl(): GeneratedAdmin.MutationCreateUploadUrlResolver[AdminEff] =
        (_context, input) -> Ok(Assets.createUpload(AdminMapping.uploadRequest(input)))

    /// Mutation.confirmAsset。input を省けば寸法も alt も無し
    pub def confirmAsset(): GeneratedAdmin.MutationConfirmAssetResolver[AdminEff] =
        (_context, id, input) -> Ok(Assets.confirm(AdminMapping.assetId("id", id), AdminMapping.assetConfirm(input)))

    /// Mutation.updateAsset
    pub def updateAsset(): GeneratedAdmin.MutationUpdateAssetResolver[AdminEff] =
        (_context, id, patch) -> Ok(Assets.updateAlt(AdminMapping.assetId("id", id), patch#alt))

    /// Mutation.deleteAsset。消した id を返す
    pub def deleteAsset(): GeneratedAdmin.MutationDeleteAssetResolver[AdminEff] =
        (_context, id) -> { Assets.delete(AdminMapping.assetId("id", id)); Ok(id) }

    /// Mutation.updateProjectVisibility
    pub def updateProjectVisibility(): GeneratedAdmin.MutationUpdateProjectVisibilityResolver[AdminEff] =
        (_context, visibility) -> Ok(Projects.updateVisibility(AdminMapping.visibilityOf(visibility)))

    /// Mutation.inviteMember
    pub def inviteMember(): GeneratedAdmin.MutationInviteMemberResolver[AdminEff] =
        (_context, email, role) -> Ok(Members.invite(email, AdminMapping.roleOf(role)))

    /// Mutation.cancelInvitation。消した id を返す
    pub def cancelInvitation(): GeneratedAdmin.MutationCancelInvitationResolver[AdminEff] =
        (_context, id) -> { Members.cancelInvitation(AdminMapping.number("id", id)); Ok(id) }

    /// Mutation.changeMemberRole
    pub def changeMemberRole(): GeneratedAdmin.MutationChangeMemberRoleResolver[AdminEff] =
        (_context, userId, role) -> Ok(Members.changeRole(AdminMapping.userId("userId", userId), AdminMapping.roleOf(role)))

    /// Mutation.removeMember。外した id を返す
    pub def removeMember(): GeneratedAdmin.MutationRemoveMemberResolver[AdminEff] =
        (_context, userId) -> { Members.remove(AdminMapping.userId("userId", userId)); Ok(userId) }

    /// Mutation.createApiKey。pepper が無ければ発行できない
    pub def createApiKey(deps: Deps): GeneratedAdmin.MutationCreateApiKeyResolver[AdminEff] =
        (_context, name, scope) -> match deps#auth#pepper {
            case Some(pepper) => Ok(ApiKeys.create(pepper, name, AdminMapping.apiKeyScopeOf(scope)))
            case None         => Err("API キーを発行できません（CMS_API_KEY_PEPPER が設定されていません）")
        }

    /// Mutation.revokeApiKey。失効した id を返す
    pub def revokeApiKey(): GeneratedAdmin.MutationRevokeApiKeyResolver[AdminEff] =
        (_context, id) -> { ApiKeys.revoke(AdminMapping.number("id", id)); Ok(id) }

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
            revokeApiKey            = revokeApiKey()
        }

}
