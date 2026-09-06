///
/// 管理 API の type ContentType のリゾルバ。source はドメインの ContentType で、ID と enum と時刻を GraphQL の形に写す。
///
/// WhyNot: 生成された既定リゾルバ（source の同名ラベルをそのまま返す）を使わないのは、ドメインの id が TypeId、
/// kind がドメインの enum、時刻が Timestamp で、GraphQL の Id / GeneratedAdmin.TypeKind / String と型が違うため。
///
mod ContentTypeResolvers {

    /// type ContentType のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ContentTypeResolvers[AdminEff] =
        {
            id         = (_context, source) -> Ok(AdminMapping.idOfType(source#id)),
            apiId      = (_context, source) -> Ok(ApiId.text(source#apiId)),
            kind       = (_context, source) -> Ok(AdminMapping.typeKindToGql(source#kind)),
            name       = (_context, source) -> Ok(source#name),
            singular   = (_context, source) -> Ok(TypeName.text(source#singular)),
            plural     = (_context, source) -> Ok(ApiId.text(source#plural)),
            previewUrl = (_context, source) -> Ok(source#previewUrl),
            fields     = (_context, source) -> Ok(source#fields),
            createdAt  = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            updatedAt  = (_context, source) -> Ok(Timestamp.toIso8601(source#updatedAt))
        }

}

///
/// 管理 API の type FieldDef のリゾルバ。source はドメインの FieldDef。
///
mod FieldDefResolvers {

    /// type FieldDef のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.FieldDefResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfField(source#id)),
            apiId     = (_context, source) -> Ok(ApiId.text(source#apiId)),
            name      = (_context, source) -> Ok(source#name),
            kind      = (_context, source) -> Ok(AdminMapping.fieldKindToGql(source#kind)),
            many      = (_context, source) -> Ok(source#many),
            required  = (_context, source) -> Ok(source#required),
            unique    = (_context, source) -> Ok(source#unique),
            localized = (_context, source) -> Ok(source#localized),
            targetTypeId = (_context, source) -> Ok(source#target |> Option.map(AdminMapping.idOfType)),
            parentFieldId = (_context, source) -> Ok(source#parent |> Option.map(AdminMapping.idOfField)),
            children  = (_context, source) -> Ok(Children.toList(source#children)),
            config    = (_context, source) -> Ok(source#config),
            position  = (_context, source) -> Ok(source#position)
        }

}

///
/// 管理 API の type FieldConfig のリゾルバ。sourceField だけ ApiId を文字列にする。
///
/// WhyNot: 既定リゾルバに sourceField だけ足す形にしないのは、同じラベルの重複はレコードの別名と一致しないため。
///
mod FieldConfigResolvers {

    /// type FieldConfig のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.FieldConfigResolvers[AdminEff] =
        {
            maxLength   = (_context, source) -> Ok(source#maxLength),
            sourceField = (_context, source) -> Ok(source#sourceField |> Option.map(ApiId.text)),
            min         = (_context, source) -> Ok(source#min),
            max         = (_context, source) -> Ok(source#max),
            integer     = (_context, source) -> Ok(source#integer),
            options     = (_context, source) -> Ok(if (List.isEmpty(source#options)) None else Some(source#options))
        }

}
