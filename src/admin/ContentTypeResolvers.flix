///
/// 管理 API の type ContentType のリゾルバ。スカラーは source の同名ラベルを返す既定に任せ、fields だけ書く。
///
mod ContentTypeResolvers {

    /// ContentType.fields。source が抱えている
    pub def fields(): GeneratedAdmin.ContentTypeFieldsResolver[AdminEff] =
        (_context, contentType) -> Ok(contentType#fields)

    /// type ContentType のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ContentTypeResolvers[AdminEff] =
        { +fields = fields() | GeneratedAdmin.contentTypeDefaults() }

}

///
/// 管理 API の type FieldDef のリゾルバ。config だけ書く。
///
mod FieldDefResolvers {

    /// FieldDef.config。source が抱えている
    pub def config(): GeneratedAdmin.FieldDefConfigResolver[AdminEff] =
        (_context, field) -> Ok(field#config)

    /// type FieldDef のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.FieldDefResolvers[AdminEff] =
        { +config = config() | GeneratedAdmin.fieldDefDefaults() }

}
