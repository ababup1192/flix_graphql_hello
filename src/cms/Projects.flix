///
/// プロジェクト（型と entry の集まり）。パスの /p/{slug}/ で選ぶ。既定の 1 つは migration が作る。
///
mod Projects {

    ///
    /// slug で 1 つ。無ければ None。
    ///
    pub def findBySlug(slug: String): Option[ProjectId] \ DbRead =
        ProjectsQueries.findProjectBySlug(slug) |> Option.map(row -> ProjectId.ProjectId(row#id))

    ///
    /// subdomain と /p/ で使えない slug。DNS のラベルとしては有効だが、入口や他のホストと衝突する。
    ///
    pub def reservedSlugs(): List[String] =
        List#{ "www", "api", "admin", "app", "assets", "cdn", "mail", "static", "p", "default-org" }

    ///
    /// 組織の下に作る。slug は URL と subdomain に出るので DNS のラベル（[a-z0-9-]）に限り、予約した物は使えない。
    ///
    pub def create(orgId: OrgId, slug: String, name: String): ProjectId \ Db + CmsErr =
        CmsErr.raiseIfAny(if (String.isMatch(regex = "^[a-z0-9][a-z0-9-]{0,63}$", slug)) Nil else Violation.Violation("slug", "'${slug}' は英小文字・数字・- を 1 〜 64 文字にしてください") :: Nil);
        CmsErr.raiseIfAny(if (List.memberOf(slug, reservedSlugs())) Violation.Violation("slug", "'${slug}' は予約されています") :: Nil else Nil);
        CmsErr.raiseIfAny(if (Option.isEmpty(findBySlug(slug))) Nil else Violation.Violation("slug", "'${slug}' は既にあります") :: Nil);
        ProjectsQueries.insertProject({ orgId = OrgId.toInt64(orgId), slug = slug, name = name }) |> Rows.expectId |> ProjectId.ProjectId

}
