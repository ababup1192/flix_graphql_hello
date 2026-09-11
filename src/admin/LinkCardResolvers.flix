///
/// 管理 API の type LinkCard のリゾルバ。source はドメインの LinkCard。素通しのフィールドは生成された既定リゾルバに任せ、
/// 時刻の写しだけ上書きする。
///
mod LinkCardResolvers {

    /// type LinkCard のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.LinkCardResolvers[AdminEff] =
        {
            fetchedAt = (_context, source) -> Ok(Timestamp.toIso8601(source#fetchedAt))
            | GeneratedAdmin.linkCardDefaults()
        }

}
