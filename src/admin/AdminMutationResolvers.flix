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
        (_context, id, expected) -> { deleteType(id, expected); Ok(id) }

    def deleteType(id: Id, expected: Option[GeneratedAdmin.SchemaImpactInput]): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        guarded(expected, () -> ContentTypes.delete(Session.grant(), AdminMapping.typeId("id", id)))

    /// Mutation.addField
    pub def addField(): GeneratedAdmin.MutationAddFieldResolver[AdminEff] =
        (_context, typeId, input, expected) -> Ok(addFieldTo(typeId, input, expected))

    ///
    /// 足すだけなら影響は空なので expected は要らない。要るのは消した apiId で足し直す時だけで、
    /// その時は残っている値が配信に戻る。
    ///
    /// WhyNot: microCMS の取り込みはここを通らない（ContentTypes.addField を直に呼ぶ）。
    /// 取り込みが作るのは新しい型のフィールドなので、通しても影響は空になる。
    ///
    def addFieldTo(typeId: Id, input: GeneratedAdmin.FieldInput, expected: Option[GeneratedAdmin.SchemaImpactInput]): FieldDef \ Db + CmsErr + IdGen + Tenant + Session =
        guarded(expected, () -> ContentTypes.addField(Session.grant(), AdminMapping.typeId("typeId", typeId), AdminMapping.fieldDraft(input)))

    /// Mutation.updateField
    pub def updateField(): GeneratedAdmin.MutationUpdateFieldResolver[AdminEff] =
        (_context, id, patch, expected) -> Ok(updateFieldOf(id, patch, expected))

    def updateFieldOf(id: Id, patch: GeneratedAdmin.FieldPatch, expected: Option[GeneratedAdmin.SchemaImpactInput]): FieldDef \ Db + CmsErr + IdGen + Tenant + Session =
        guarded(expected, () -> ContentTypes.updateField(Session.grant(), AdminMapping.fieldId("id", id), AdminMapping.fieldChanges(patch)))

    /// Mutation.removeField。消した id を返す
    pub def removeField(): GeneratedAdmin.MutationRemoveFieldResolver[AdminEff] =
        (_context, id, expected) -> { removeFieldOf(id, expected); Ok(id) }

    def removeFieldOf(id: Id, expected: Option[GeneratedAdmin.SchemaImpactInput]): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        guarded(expected, () -> ContentTypes.removeField(Session.grant(), AdminMapping.fieldId("id", id)))

    ///
    /// スキーマを壊しうる操作を包む。影響が空なら expected 無しでも通り、空でなければ
    /// 見た影響（expected）と突き合わせて、悪くなっていれば止める。
    ///
    def guarded(expected: Option[GeneratedAdmin.SchemaImpactInput], thunk: Unit -> a \ ef): a \ ef + DbRead + CmsErr + Tenant + Session =
        SchemaGuard.withImpact(Session.grant(), expected |> Option.map(AdminMapping.fingerprint), thunk)

    /// Mutation.reorderFields
    pub def reorderFields(): GeneratedAdmin.MutationReorderFieldsResolver[AdminEff] =
        (_context, typeId, ids) -> Ok(reorderFieldsOf(typeId, ids))

    def reorderFieldsOf(typeId: Id, ids: List[Id]): ContentType \ Db + CmsErr + IdGen + Tenant + Session =
        ContentTypes.reorderFields(Session.grant(), AdminMapping.typeId("typeId", typeId), ids |> List.map(AdminMapping.fieldId("ids")))

    /// Mutation.createEntry
    pub def createEntry(): GeneratedAdmin.MutationCreateEntryResolver[AdminEff] =
        (_context, typeId, fields, id) -> Ok(createEntryOf(typeId, fields, id))

    def createEntryOf(typeId: Id, fields: Value, id: Option[Id]): Entry \ Db + CmsErr + IdGen + Tenant + Session =
        ContentEntries.create(Session.grant(),
            AdminMapping.typeId("typeId", typeId),
            id |> Option.map(AdminMapping.entryId("id")),
            AdminMapping.entryData("fields", fields))

    /// Mutation.updateEntry
    pub def updateEntry(): GeneratedAdmin.MutationUpdateEntryResolver[AdminEff] =
        (_context, id, fields, expectedVersion, saveVersion) -> Ok(updateEntryOf(id, fields, expectedVersion, saveVersion |> Option.getWithDefault(false)))

    ///
    /// 下書きを直す。saveVersion なら同じ Tx で版も積む（保存だけ通って版が積まれない形を作らない）。
    /// 版は直した後の中身で積むので、`ContentEntries.update` の後に呼ぶ。
    ///
    def updateEntryOf(id: Id, fields: Value, expectedVersion: Int32, saveVersion: Bool): Entry \ Db + CmsErr + Tenant + Session =
        let entryId = AdminMapping.entryId("id", id);
        let updated = ContentEntries.update(Session.grant(), entryId, AdminMapping.entryData("fields", fields), expectedVersion);
        if (saveVersion) discard ContentEntries.saveVersion(Session.grant(), entryId, Session.displayName()) else ();
        updated

    /// Mutation.deleteEntry。消した id を返す
    pub def deleteEntry(): GeneratedAdmin.MutationDeleteEntryResolver[AdminEff] =
        (_context, id) -> { deleteEntryOf(id); Ok(id) }

    /// 消す。公開中の物には取り下げの証明も要るので、持てるだけ渡す（writer は公開中の物を消せない）。
    def deleteEntryOf(id: Id): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        ContentEntries.delete(Session.grant(), Session.tryGrant(), AdminMapping.entryId("id", id))

    /// Mutation.publishEntry
    pub def publishEntry(): GeneratedAdmin.MutationPublishEntryResolver[AdminEff] =
        (_context, id, withDependencies) -> Ok(publishAs(id, withDependencies |> Option.getWithDefault(false)))

    /// 今の主体の名前で公開する。
    def publishAs(id: Id, withDependencies: Bool): Entry \ Db + CmsErr + IdGen + Tenant + Session =
        ContentEntries.publish(Session.grant(), AdminMapping.entryId("id", id), Session.displayName(), withDependencies)

    /// Mutation.publishMany。withDependencies の既定は true
    pub def publishMany(): GeneratedAdmin.MutationPublishManyResolver[AdminEff] =
        (_context, ids, withDependencies) -> Ok(publishManyAs(ids |> List.map(AdminMapping.entryId("ids")), withDependencies |> Option.getWithDefault(true)))

    /// 今の主体の名前で一括公開する。ラムダの中で effect を使わないための切り出し（VerifyError）。
    def publishManyAs(ids: List[EntryId], withDependencies: Bool): List[Entry] \ Db + CmsErr + IdGen + Tenant + Session =
        ContentEntries.publishMany(Session.grant(), ids, Session.displayName(), withDependencies)

    /// Mutation.unpublishEntry
    pub def unpublishEntry(): GeneratedAdmin.MutationUnpublishEntryResolver[AdminEff] =
        (_context, id) -> Ok(unpublishOf(id))

    def unpublishOf(id: Id): Entry \ Db + CmsErr + IdGen + Tenant + Session =
        ContentEntries.unpublish(Session.grant(), AdminMapping.entryId("id", id))

    /// Mutation.saveVersion
    pub def saveVersion(): GeneratedAdmin.MutationSaveVersionResolver[AdminEff] =
        (_context, id) -> Ok(saveVersionAs(id))

    /// 今の主体の名前で版を積む。
    def saveVersionAs(id: Id): EntryVersion \ Db + CmsErr + Tenant + Session =
        ContentEntries.saveVersion(Session.grant(), AdminMapping.entryId("id", id), Session.displayName())

    /// Mutation.restoreVersion
    pub def restoreVersion(): GeneratedAdmin.MutationRestoreVersionResolver[AdminEff] =
        (_context, id, versionId, expectedVersion) -> Ok(restoreVersionOf(id, versionId, expectedVersion))

    def restoreVersionOf(id: Id, versionId: Id, expectedVersion: Int32): Entry \ Db + CmsErr + Tenant + Session =
        ContentEntries.restoreVersion(Session.grant(), AdminMapping.entryId("id", id), AdminMapping.versionId("versionId", versionId), expectedVersion)

    /// Mutation.autosaveEntry
    pub def autosaveEntry(): GeneratedAdmin.MutationAutosaveEntryResolver[AdminEff] =
        (_context, id, fields) -> Ok(autosaveEntryOf(id, fields))

    /// 編集中の中身を自分の置き場に預かる。ラムダの中で effect を使わないための切り出し（VerifyError）。
    def autosaveEntryOf(id: Id, fields: Value): Option[EntryAutosave] \ Db + CmsErr + Tenant + Session =
        EntryAutosaves.save(Session.grant(), AdminMapping.entryId("id", id), AdminMapping.entryData("fields", fields))

    /// Mutation.discardAutosave。捨てた entry の id を返す
    pub def discardAutosave(): GeneratedAdmin.MutationDiscardAutosaveResolver[AdminEff] =
        (_context, id) -> { discardAutosaveOf(id); Ok(id) }

    def discardAutosaveOf(id: Id): Unit \ DbWrite + CmsErr + Tenant + Session =
        EntryAutosaves.clear(Session.grant(), AdminMapping.entryId("id", id))

    /// Mutation.createUploadUrl
    pub def createUploadUrl(): GeneratedAdmin.MutationCreateUploadUrlResolver[AdminEff] =
        (_context, input) -> Ok(createUpload(input))

    def createUpload(input: GeneratedAdmin.UploadInput): Upload \ Db + CmsErr + IdGen + Tenant + ObjectStore + Session =
        Assets.createUpload(Session.grant(), AdminMapping.uploadRequest(input))

    /// Mutation.confirmAsset。input を省けば寸法も alt も無し
    pub def confirmAsset(): GeneratedAdmin.MutationConfirmAssetResolver[AdminEff] =
        (_context, id, input) -> Ok(confirmUpload(id, input))

    def confirmUpload(id: Id, input: Option[GeneratedAdmin.AssetConfirmInput]): Asset \ Db + CmsErr + IdGen + Tenant + ObjectStore + Session =
        Assets.confirm(Session.grant(), AdminMapping.assetId("id", id), AdminMapping.assetConfirm(input))

    /// Mutation.updateAsset
    pub def updateAsset(): GeneratedAdmin.MutationUpdateAssetResolver[AdminEff] =
        (_context, id, patch) -> Ok(updateAssetOf(id, patch))

    def updateAssetOf(id: Id, patch: GeneratedAdmin.AssetPatch): Asset \ Db + CmsErr + IdGen + Tenant + Session =
        Assets.update(Session.grant(), AdminMapping.assetId("id", id), AdminMapping.assetChanges(patch))

    /// Mutation.deleteAsset。消した id を返す
    pub def deleteAsset(): GeneratedAdmin.MutationDeleteAssetResolver[AdminEff] =
        (_context, id) -> { deleteAssetOf(id); Ok(id) }

    def deleteAssetOf(id: Id): Unit \ Db + CmsErr + IdGen + Tenant + ObjectStore + Session =
        Assets.delete(Session.grant(), AdminMapping.assetId("id", id))

    /// Mutation.updateProjectVisibility
    pub def updateProjectVisibility(): GeneratedAdmin.MutationUpdateProjectVisibilityResolver[AdminEff] =
        (_context, visibility) -> Ok(updateVisibility(visibility))

    def updateVisibility(visibility: GeneratedAdmin.Visibility): Project \ Db + CmsErr + IdGen + Tenant + Session =
        Projects.updateVisibility(Session.grant(), AdminMapping.visibilityOf(visibility))

    /// Mutation.inviteMember
    pub def inviteMember(): GeneratedAdmin.MutationInviteMemberResolver[AdminEff] =
        (_context, email, role) -> Ok(inviteOf(email, role))

    def inviteOf(email: String, role: GeneratedAdmin.Role): Invitation \ Db + CmsErr + IdGen + Tenant + Session + Time.Clock.Clock =
        Members.invite(Session.grant(), email, AdminMapping.roleOf(role))

    /// Mutation.cancelInvitation。消した id を返す
    pub def cancelInvitation(): GeneratedAdmin.MutationCancelInvitationResolver[AdminEff] =
        (_context, id) -> { cancelInvitationOf(id); Ok(id) }

    def cancelInvitationOf(id: Id): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        Members.cancelInvitation(Session.grant(), AdminMapping.publicIdOf(id))

    /// Mutation.changeMemberRole
    pub def changeMemberRole(): GeneratedAdmin.MutationChangeMemberRoleResolver[AdminEff] =
        (_context, userId, role) -> Ok(changeRoleOf(userId, role))

    def changeRoleOf(userId: Id, role: GeneratedAdmin.Role): Member \ Db + CmsErr + IdGen + Tenant + Session =
        Members.changeRole(Session.grant(), AdminMapping.userId("userId", userId), AdminMapping.roleOf(role))

    /// Mutation.removeMember。外した id を返す
    pub def removeMember(): GeneratedAdmin.MutationRemoveMemberResolver[AdminEff] =
        (_context, userId) -> { removeMemberOf(userId); Ok(userId) }

    def removeMemberOf(userId: Id): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        Members.remove(Session.grant(), AdminMapping.userId("userId", userId))

    /// Mutation.createApiKey。pepper が無ければ発行できない
    pub def createApiKey(deps: Deps): GeneratedAdmin.MutationCreateApiKeyResolver[AdminEff] =
        (_context, name, scope, role, expiresAt) -> match deps#auth#pepper {
            case Some(pepper) => Ok(createApiKeyWith(pepper, name, scope, role, expiresAt))
            case None         => Err(FieldError.internal("API キーを発行できません（CMS_API_KEY_PEPPER が設定されていません）"))
        }

    /// 鍵を発行する。manageApiKeys の証明と、ログインの JWT で来た本人の証明の 2 つを作って渡す。
    def createApiKeyWith(pepper: SecretHash.Pepper, name: String, scope: GeneratedAdmin.ApiKeyScope, role: Option[GeneratedAdmin.Role], expiresAt: Option[String]): IssuedApiKey \ Db + CmsErr + IdGen + Tenant + Session + Time.Clock.Clock =
        ApiKeys.create(Session.grant(), Session.grantInteractive(), pepper, {
            name = name, scope = AdminMapping.apiKeyScopeOf(scope, role),
            expiresAt = expiresAt |> Option.map(text -> AdminMapping.timestampOf("expiresAt", text)) }, Time.Clock.now())

    /// Mutation.revokeApiKey。失効した id を返す
    pub def revokeApiKey(): GeneratedAdmin.MutationRevokeApiKeyResolver[AdminEff] =
        (_context, id) -> { revokeApiKeyOf(id); Ok(id) }

    def revokeApiKeyOf(id: Id): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        ApiKeys.revoke(Session.grant(), AdminMapping.publicIdOf(id))

    /// Mutation.createPreviewToken。pepper が無ければ発行できない
    pub def createPreviewToken(deps: Deps): GeneratedAdmin.MutationCreatePreviewTokenResolver[AdminEff] =
        (_context, entryId, expiresInSeconds) -> match deps#auth#pepper {
            case Some(pepper) => Ok(issuePreviewToken(pepper, entryId, expiresInSeconds))
            case None         => Err(FieldError.internal("プレビュートークンを発行できません（CMS_API_KEY_PEPPER が設定されていません）"))
        }

    def issuePreviewToken(pepper: SecretHash.Pepper, entryId: Id, expiresInSeconds: Option[Int32]): PreviewToken \ DbRead + CmsErr + Tenant + Session + Time.Clock.Clock =
        PreviewTokens.issue(Session.grant(), pepper, AdminMapping.entryId("entryId", entryId), { ttlSeconds = expiresInSeconds |> Option.map(Int32.toInt64) |> Option.getWithDefault(PreviewTokens.defaultTtlSeconds()), nowMillis = Time.Clock.now() })

    /// Mutation.schedulePublish
    pub def schedulePublish(): GeneratedAdmin.MutationSchedulePublishResolver[AdminEff] =
        (_context, entryId, at, withDependencies) -> Ok(scheduleOf(entryId, ScheduleAction.Publish, at, withDependencies |> Option.getWithDefault(false)))

    /// Mutation.scheduleUnpublish
    pub def scheduleUnpublish(): GeneratedAdmin.MutationScheduleUnpublishResolver[AdminEff] =
        (_context, entryId, at) -> Ok(scheduleOf(entryId, ScheduleAction.Unpublish, at, false))

    def scheduleOf(entryId: Id, action: ScheduleAction, at: String, withDependencies: Bool): Schedule \ Db + CmsErr + IdGen + Tenant + Session =
        Schedules.schedule(Session.grant(), AdminMapping.entryId("entryId", entryId), action, AdminMapping.timestampOf("at", at), withDependencies)

    /// Mutation.cancelSchedule
    pub def cancelSchedule(): GeneratedAdmin.MutationCancelScheduleResolver[AdminEff] =
        (_context, id) -> Ok(cancelScheduleOf(id))

    /// Mutation.fetchLinkCard
    pub def fetchLinkCard(): GeneratedAdmin.MutationFetchLinkCardResolver[AdminEff] =
        (_context, url) -> Ok(fetchLinkCardOf(url))

    def fetchLinkCardOf(url: String): LinkCard \ Db + CmsErr + Tenant + Session + Net.Http.Http + Time.Clock.Clock =
        LinkCards.fetch(Session.grant(), url)

    def cancelScheduleOf(id: Id): Schedule \ Db + CmsErr + Tenant + Session =
        Schedules.cancel(Session.grant(), AdminMapping.publicIdOf(id))

    /// Mutation.createWebhook
    pub def createWebhook(): GeneratedAdmin.MutationCreateWebhookResolver[AdminEff] =
        (_context, input) -> Ok(createWebhookOf(input))

    def createWebhookOf(input: GeneratedAdmin.WebhookInput): IssuedWebhook \ Db + CmsErr + IdGen + Tenant + Session =
        Webhooks.create(Session.grant(), AdminMapping.webhookDraftOf(input))

    /// Mutation.updateWebhook
    pub def updateWebhook(): GeneratedAdmin.MutationUpdateWebhookResolver[AdminEff] =
        (_context, id, input) -> Ok(updateWebhookOf(id, input))

    def updateWebhookOf(id: Id, input: GeneratedAdmin.WebhookInput): Webhook \ Db + CmsErr + IdGen + Tenant + Session =
        Webhooks.update(Session.grant(), AdminMapping.publicIdOf(id), AdminMapping.webhookDraftOf(input))

    /// Mutation.deleteWebhook。消した id を返す
    pub def deleteWebhook(): GeneratedAdmin.MutationDeleteWebhookResolver[AdminEff] =
        (_context, id) -> { deleteWebhookOf(id); Ok(id) }

    def deleteWebhookOf(id: Id): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        Webhooks.delete(Session.grant(), AdminMapping.publicIdOf(id))

    /// Mutation.redeliverWebhook
    pub def redeliverWebhook(): GeneratedAdmin.MutationRedeliverWebhookResolver[AdminEff] =
        (_context, deliveryId) -> Ok(redeliverOf(deliveryId))

    def redeliverOf(deliveryId: Id): WebhookDelivery \ Db + CmsErr + IdGen + Tenant + Session =
        Webhooks.redeliver(Session.grant(), AdminMapping.publicIdOf(deliveryId))

    /// Mutation.recordAuditExport。積めたら true
    pub def recordAuditExport(): GeneratedAdmin.MutationRecordAuditExportResolver[AdminEff] =
        (_context, input) -> { recordAuditExportOf(input); Ok(true) }

    def recordAuditExportOf(input: GeneratedAdmin.AuditExportInput): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        CmsErr.raiseIfAny(if (input#count < 0) Violation.Violation("count", "count は 0 以上にしてください") :: Nil else Nil);
        Audit.recordExport(Session.grant(), AdminMapping.auditExportFormatOf(input#format),
            AdminMapping.auditFilterOf(input#actorKind, input#action, input#since, input#until), input#count)

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
            publishMany       = publishMany(),
            unpublishEntry    = unpublishEntry(),
            saveVersion       = saveVersion(),
            restoreVersion    = restoreVersion(),
        autosaveEntry     = autosaveEntry(),
        discardAutosave   = discardAutosave(),
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
            redeliverWebhook        = redeliverWebhook(),
            recordAuditExport       = recordAuditExport(),
            fetchLinkCard           = fetchLinkCard()
        }

}
