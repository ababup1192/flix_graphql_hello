///
/// 管理 API の type Asset のリゾルバ。source はドメインの Asset。url は ObjectStore が組む。
///
mod AssetResolvers {

    /// type Asset のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.AssetResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfAsset(source#id)),
            url       = (_context, source) -> Ok(ObjectStore.publicUrl(source#key)),
            fileName  = (_context, source) -> Ok(source#fileName),
            mime      = (_context, source) -> Ok(source#mime),
            size      = (_context, source) -> Ok(AdminMapping.sizeToGql(source#size)),
            width     = (_context, source) -> Ok(source#width),
            height    = (_context, source) -> Ok(source#height),
            alt       = (_context, source) -> Ok(source#alt),
            status    = (_context, source) -> Ok(AdminMapping.assetStatusToGql(source#status)),
            createdAt = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt))
        }

}

///
/// 管理 API の type AssetPage のリゾルバ。
///
mod AssetPageResolvers {

    /// type AssetPage のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.AssetPageResolvers[AdminEff] =
        {
            nodes      = (_context, source) -> Ok(source#assets),
            totalCount = (_context, source) -> Ok(AdminMapping.sizeToGql(source#totalCount))
        }

}

///
/// 管理 API の type Upload のリゾルバ。
///
mod UploadResolvers {

    /// type Upload のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.UploadResolvers[AdminEff] =
        {
            asset            = (_context, source) -> Ok(source#asset),
            uploadUrl        = (_context, source) -> Ok(source#uploadUrl),
            expiresInSeconds = (_context, source) -> Ok(source#expiresInSeconds)
        }

}
