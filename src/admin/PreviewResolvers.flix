///
/// 管理 API の PreviewToken のリゾルバ。
///
mod PreviewTokenResolvers {

    /// type PreviewToken のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.PreviewTokenResolvers[AdminEff] =
        {
            token     = (_context, source) -> Ok(source#token),
            entryId   = (_context, source) -> Ok(Id.Id(EntryId.text(source#entryId))),
            expiresAt = (_context, source) -> Ok(Timestamp.toIso8601(source#expiresAt)),
            url       = (_context, source) -> Ok(source#url)
        }

}
