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
            case (Some(given), _)   => Ok(ContentTypes.find(AdminMapping.typeId("id", given)))
            case (None, Some(text)) => Ok(ApiId.parse(text) |> Option.flatMap(ContentTypes.findByApiId))
            case (None, None)       => Err("id か apiId を指定してください")
        }

    /// Query.entries。first は 1 〜 200 に丸める
    pub def entries(): GeneratedAdmin.QueryEntriesResolver[AdminEff] =
        (_context, typeId, search, first, skip) -> Ok(ContentEntries.list(AdminMapping.typeId("typeId", typeId), {
            search = search |> Option.getWithDefault(""),
            first  = first |> Option.getWithDefault(50) |> Int32.max(1) |> Int32.min(200),
            skip   = skip |> Option.getWithDefault(0) |> Int32.max(0)
        }))

    /// Query.entry
    pub def entry(): GeneratedAdmin.QueryEntryResolver[AdminEff] =
        (_context, id) -> Ok(ContentEntries.find(AdminMapping.entryId("id", id)))

    /// type Query のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.QueryResolvers[AdminEff] =
        { contentTypes = contentTypes(), contentType = contentType(), entries = entries(), entry = entry() }

}
