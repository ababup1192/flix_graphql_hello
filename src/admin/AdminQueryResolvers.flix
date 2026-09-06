///
/// 管理 API の type Query のリゾルバ。
///
mod AdminQueryResolvers {

    /// Query.contentTypes
    pub def contentTypes(): GeneratedAdmin.QueryContentTypesResolver[AdminEff] =
        _context -> Ok(ContentTypes.list())

    /// Query.contentType。id か apiId のどちらかで引く。両方無ければエラー
    pub def contentType(): GeneratedAdmin.QueryContentTypeResolver[AdminEff] =
        (_context, id, apiId) -> match (id, apiId) {
            case (Some(given), _)   => AdminIds.parse("id", given) |> Result.map(ContentTypes.find)
            case (None, Some(name)) => Ok(ContentTypes.findByApiId(name))
            case (None, None)       => Err("id か apiId を指定してください")
        }

    /// type Query のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.QueryResolvers[AdminEff] =
        { contentTypes = contentTypes(), contentType = contentType() }

}
