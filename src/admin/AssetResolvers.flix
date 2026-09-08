///
/// 管理 API の type Asset のリゾルバ。source はドメインの Asset。url は ObjectStore が組む。
/// 素通しのフィールドは生成された既定リゾルバに任せ、写しが要る物だけレコードの更新で上書きする。
///
mod AssetResolvers {

    /// type Asset のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.AssetResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfAsset(source#id)),
            url       = (_context, source) -> Ok(ObjectStore.publicUrl(source#key)),
            size      = (_context, source) -> Ok(AdminMapping.sizeToGql(source#size)),
            status    = (_context, source) -> Ok(AdminMapping.assetStatusToGql(source#status)),
            createdAt = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            +usedBy   = (_context, source) -> Ok(usedBy(source#id))
            | GeneratedAdmin.assetDefaults()
        }

    def usedBy(id: AssetId): List[Entry] \ DbRead + CmsErr + Tenant + Session =
        Assets.holders(Session.grant(), id) |> List.filterMap(ContentEntries.find)

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
            +asset = (_context, source) -> Ok(source#asset)
            | GeneratedAdmin.uploadDefaults()
        }

}
