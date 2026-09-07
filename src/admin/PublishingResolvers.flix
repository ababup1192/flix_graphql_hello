///
/// 管理 API の公開の検査（PublishReport）と影響（Impact）の型のリゾルバ。source はドメインの値。
///
mod ViolationResolvers {

    /// type Violation のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ViolationResolvers[AdminEff] =
        {
            path    = (_context, source) -> Ok(AdminMapping.violationPath(source)),
            message = (_context, source) -> Ok(AdminMapping.violationMessage(source))
        }

}

mod PublishReportResolvers {

    /// type PublishReport のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.PublishReportResolvers[AdminEff] =
        {
            ok                      = (_context, source) -> Ok(List.isEmpty(source#violations)),
            violations              = (_context, source) -> Ok(source#violations),
            unpublishedDependencies = (_context, source) -> Ok(source#unpublishedDependencies)
        }

}

mod ReferrerResolvers {

    /// type Referrer のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ReferrerResolvers[AdminEff] =
        {
            entry = (_context, source) -> Ok(source#entry),
            via   = (_context, source) -> Ok(ApiId.text(source#via)),
            stage = (_context, source) -> Ok(AdminMapping.contentStageToGql(source#stage))
        }

}

mod ImpactResolvers {

    /// type Impact のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ImpactResolvers[AdminEff] =
        {
            breaks   = (_context, source) -> Ok(source#breaks),
            cascades = (_context, source) -> Ok(source#cascades)
        }

}
