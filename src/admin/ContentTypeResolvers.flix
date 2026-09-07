///
/// 管理 API の type ContentType のリゾルバ。source はドメインの ContentType で、ID と enum と時刻を GraphQL の形に写す。
/// 素通しのフィールドは生成された既定リゾルバに任せ、写しが要る物だけレコードの更新で上書きする。
///
mod ContentTypeResolvers {

    /// type ContentType のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ContentTypeResolvers[AdminEff] =
        {
            id         = (_context, source) -> Ok(AdminMapping.idOfType(source#id)),
            apiId      = (_context, source) -> Ok(ApiId.text(source#apiId)),
            kind       = (_context, source) -> Ok(AdminMapping.typeKindToGql(source#kind)),
            singular   = (_context, source) -> Ok(TypeName.text(source#singular)),
            plural     = (_context, source) -> Ok(ApiId.text(source#plural)),
            createdAt  = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            updatedAt  = (_context, source) -> Ok(Timestamp.toIso8601(source#updatedAt)),
            +fields    = (_context, source) -> Ok(source#fields)
            | GeneratedAdmin.contentTypeDefaults()
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
            kind      = (_context, source) -> Ok(AdminMapping.fieldKindToGql(source#kind)),
            targetTypeId = (_context, source) -> Ok(source#target |> Option.map(AdminMapping.idOfType)),
            parentFieldId = (_context, source) -> Ok(source#parent |> Option.map(AdminMapping.idOfField)),
            +children = (_context, source) -> Ok(Children.toList(source#children)),
            +config   = (_context, source) -> Ok(source#config)
            | GeneratedAdmin.fieldDefDefaults()
        }

}

///
/// 管理 API の type FieldConfig のリゾルバ。sourceField だけ ApiId を文字列にする。
///
mod FieldConfigResolvers {

    /// type FieldConfig のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.FieldConfigResolvers[AdminEff] =
        {
            sourceField = (_context, source) -> Ok(source#sourceField |> Option.map(ApiId.text)),
            options     = (_context, source) -> Ok(if (List.isEmpty(source#options)) None else Some(source#options))
            | GeneratedAdmin.fieldConfigDefaults()
        }

}
