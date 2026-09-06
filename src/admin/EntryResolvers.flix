///
/// 管理 API の type Entry のリゾルバ。source はドメインの Entry で、ID と stage と中身と時刻を GraphQL の形に写す。
///
mod EntryResolvers {

    /// type Entry のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.EntryResolvers[AdminEff] =
        {
            id          = (_context, source) -> Ok(AdminMapping.idOfEntry(source#id)),
            typeId      = (_context, source) -> Ok(AdminMapping.idOfType(source#typeId)),
            version     = (_context, source) -> Ok(source#version),
            stage       = (_context, source) -> Ok(AdminMapping.stageToGql(source#stage)),
            fields      = (_context, source) -> Ok(AdminMapping.entryDataValue(source#data)),
            publishedAt = (_context, source) -> Ok(source#publishedAt |> Option.map(Timestamp.toIso8601)),
            createdAt   = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            updatedAt   = (_context, source) -> Ok(Timestamp.toIso8601(source#updatedAt))
        }

}

///
/// 管理 API の type EntryPage のリゾルバ。totalCount は GraphQL の Int に収める。
///
mod EntryPageResolvers {

    /// type EntryPage のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.EntryPageResolvers[AdminEff] =
        {
            nodes      = (_context, source) -> Ok(source#entries),
            totalCount = (_context, source) -> Ok(Int64.clampToInt32(min = 0, max = Int32.maxValue(), source#totalCount))
        }

}
