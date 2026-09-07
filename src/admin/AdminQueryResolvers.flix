///
/// 管理 API の type Query のリゾルバ。ID を読んでユースケースを呼ぶだけ。
///
mod AdminQueryResolvers {

    /// Query.contentTypes
    pub def contentTypes(): GeneratedAdmin.QueryContentTypesResolver[AdminEff] =
        _context -> Ok(ContentTypes.list())

    /// Query.contentType。id か apiId のどちらかで引く。両方無ければエラー
    pub def contentType(): GeneratedAdmin.QueryContentTypeResolver[AdminEff] =
        (_context, id, apiId) -> match (id, apiId) {
            case (Some(_), Some(_)) => Err("id か apiId のどちらか一方にしてください")
            case (Some(given), _)   => Ok(ContentTypes.find(AdminMapping.typeId("id", given)))
            case (None, Some(text)) => Ok(ApiId.parse(text) |> Option.flatMap(ContentTypes.findByApiId))
            case (None, None)       => Err("id か apiId を指定してください")
        }

    /// Query.entries。first は 0 〜 200 に丸める
    pub def entries(): GeneratedAdmin.QueryEntriesResolver[AdminEff] =
        (_context, typeId, search, first, skip) -> {
            let (limit, offset) = EntryPage.clamp(50, first, skip);
            Ok(ContentEntries.list(AdminMapping.typeId("typeId", typeId), { search = search |> Option.getWithDefault(""), first = limit, skip = offset }))
        }

    /// Query.entry
    pub def entry(): GeneratedAdmin.QueryEntryResolver[AdminEff] =
        (_context, id) -> Ok(ContentEntries.find(AdminMapping.entryId("id", id)))

    /// Query.assets。first は 0 〜 200 に丸める
    pub def assets(): GeneratedAdmin.QueryAssetsResolver[AdminEff] =
        (_context, first, skip) -> {
            let (limit, offset) = EntryPage.clamp(50, first, skip);
            Ok(Assets.list(limit, offset))
        }

    /// Query.asset
    pub def asset(): GeneratedAdmin.QueryAssetResolver[AdminEff] =
        (_context, id) -> Ok(Assets.find(AdminMapping.assetId("id", id)))

    /// type Query のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.QueryResolvers[AdminEff] =
        { contentTypes = contentTypes(), contentType = contentType(), entries = entries(), entry = entry(), assets = assets(), asset = asset() }

}
