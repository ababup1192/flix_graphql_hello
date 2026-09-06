///
/// 管理 API の type Mutation のリゾルバ。ID を DB の id に読んでユースケースを呼ぶだけ。
///
mod AdminMutationResolvers {

    /// Mutation.createContentType
    pub def createContentType(): GeneratedAdmin.MutationCreateContentTypeResolver[AdminEff] =
        (_context, input) -> Ok(ContentTypes.create(input))

    /// Mutation.updateContentType
    pub def updateContentType(): GeneratedAdmin.MutationUpdateContentTypeResolver[AdminEff] =
        (_context, id, patch) -> AdminIds.parse("id", id) |> Result.map(number -> ContentTypes.update(number, patch))

    /// Mutation.deleteContentType。消した id を返す
    pub def deleteContentType(): GeneratedAdmin.MutationDeleteContentTypeResolver[AdminEff] =
        (_context, id) -> AdminIds.parse("id", id) |> Result.map(number -> { ContentTypes.delete(number); id })

    /// Mutation.addField
    pub def addField(): GeneratedAdmin.MutationAddFieldResolver[AdminEff] =
        (_context, typeId, input) -> AdminIds.parse("typeId", typeId) |> Result.map(number -> ContentTypes.addField(number, input))

    /// Mutation.updateField
    pub def updateField(): GeneratedAdmin.MutationUpdateFieldResolver[AdminEff] =
        (_context, id, patch) -> AdminIds.parse("id", id) |> Result.map(number -> ContentTypes.updateField(number, patch))

    /// Mutation.removeField。消した id を返す
    pub def removeField(): GeneratedAdmin.MutationRemoveFieldResolver[AdminEff] =
        (_context, id) -> AdminIds.parse("id", id) |> Result.map(number -> { ContentTypes.removeField(number); id })

    /// Mutation.reorderFields
    pub def reorderFields(): GeneratedAdmin.MutationReorderFieldsResolver[AdminEff] =
        (_context, typeId, ids) -> forM (
            owner   <- AdminIds.parse("typeId", typeId);
            numbers <- Result.traverse(AdminIds.parse("ids"), ids)
        ) yield ContentTypes.reorderFields(owner, numbers)

    /// type Mutation のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.MutationResolvers[AdminEff] =
        {
            createContentType = createContentType(),
            updateContentType = updateContentType(),
            deleteContentType = deleteContentType(),
            addField          = addField(),
            updateField       = updateField(),
            removeField       = removeField(),
            reorderFields     = reorderFields()
        }

}

///
/// GraphQL の ID と DB の id の橋渡し。
///
mod AdminIds {

    ///
    /// ID を DB の id に読む。数字でなければ引数名付きのエラー。
    ///
    pub def parse(argument: String, id: Id): Result[FieldError, Int64] =
        ContentModel.parseId(id) |> Option.toOk("${argument} '${id}' は数字の ID ではありません")

}
