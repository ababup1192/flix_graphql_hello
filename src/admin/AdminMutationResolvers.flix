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

    /// type Mutation のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.MutationResolvers[AdminEff] =
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
            deleteEntry       = deleteEntry()
        }

}
