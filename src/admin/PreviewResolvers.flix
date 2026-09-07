///
/// 管理 API の PreviewToken のリゾルバ。
///
mod PreviewTokenResolvers {

    /// type PreviewToken のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.PreviewTokenResolvers[AdminEff] =
        {
            entryId   = (_context, source) -> Ok(AdminMapping.idOfEntry(source#entryId)),
            expiresAt = (_context, source) -> Ok(Timestamp.toIso8601(source#expiresAt))
            | GeneratedAdmin.previewTokenDefaults()
        }

}
