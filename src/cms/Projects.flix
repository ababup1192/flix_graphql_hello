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
    /// 作る。slug は URL に出るので lowerCamel か kebab（[a-z0-9-]）に限る。
    ///
    pub def create(slug: String, name: String): ProjectId \ Db + CmsErr =
        CmsErr.raiseIfAny(if (String.isMatch(regex = "^[a-z0-9][a-z0-9-]{0,63}$", slug)) Nil else Violation.Violation("slug", "'${slug}' は英小文字・数字・- を 1 〜 64 文字にしてください") :: Nil);
        CmsErr.raiseIfAny(if (Option.isEmpty(findBySlug(slug))) Nil else Violation.Violation("slug", "'${slug}' は既にあります") :: Nil);
        ProjectsQueries.insertProject({ slug = slug, name = name }) |> Rows.expectId |> ProjectId.ProjectId

}
