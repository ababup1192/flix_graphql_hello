///
/// プロジェクト（型と entry の集まり）。パスの /p/{プロジェクト slug}/ で選ぶ。既定プロジェクトは migration が作る。
///
mod Projects {

    ///
    /// プロジェクト slug で 1 つ。無ければ None。
    ///
    pub def findBySlug(slug: ProjectSlug): Option[ProjectId] \ DbRead =
        ProjectsQueries.findProjectBySlug(ProjectSlug.text(slug)) |> Option.map(row -> ProjectId.ProjectId(row#id))

    ///
    /// id で 1 つ（認証の文脈の形）。無ければ None。
    ///
    pub def find(id: ProjectId): Option[Project] \ DbRead =
        ProjectsQueries.findProjectById(ProjectId.toInt64(id)) |> Option.map(fromRow)

    ///
    /// プロジェクトの見え方。無いプロジェクトは private 扱い（存在を教えない）。
    ///
    pub def visibilityOf(id: ProjectId): Visibility \ DbRead + DbErr =
        find(id) |> Option.map(found -> found#visibility) |> Option.getWithDefault(Visibility.Private)

    ///
    /// 行からプロジェクト。プロジェクト slug と visibility は書く時に検査しているので、読めなければ DB の壊れ。
    ///
    pub def fromRow(row: { id = Int64, publicId = String, slug = String, name = String, visibility = String | r }): Project \ DbErr =
        { id = ProjectId.ProjectId(row#id),
          publicId = row#publicId,
          slug = ProjectSlug.parse(row#slug) |> Rows.orRaise("projects.slug", row#slug),
          name = row#name,
          visibility = Visibility.parse(row#visibility) |> Rows.orRaise("projects.visibility", row#visibility) }

    ///
    /// 組織の下のプロジェクト。
    ///
    pub def listOfOrg(orgId: OrgId): List[Project] \ DbRead + DbErr =
        AuthQueries.listProjectsOfOrg(OrgId.toInt64(orgId)) |> List.map(fromRow)

    ///
    /// 今のプロジェクトの公開範囲を変える。owner だけ。
    ///
    pub def updateVisibility(visibility: Visibility): Project \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.ManageProject);
        discard AuthQueries.updateProjectVisibility({ projectId = Tenant.currentId(), visibility = Visibility.text(visibility) });
        find(Tenant.current()) |> CmsErr.orNotFound(Entity.Organization, "${Tenant.current()}")

    ///
    /// subdomain と /p/ で使えないプロジェクト slug。DNS のラベルとしては有効だが、入口や他のホストと衝突する。
    ///
    pub def reservedSlugs(): List[String] =
        List#{ "www", "api", "admin", "account", "app", "assets", "cdn", "mail", "static", "p", "default-org" }

    ///
    /// 文字列からプロジェクト slug。形が違えば invalid。入力の境界（GraphQL の引数）で使う。
    ///
    pub def parseSlug(text: String): ProjectSlug \ CmsErr =
        ProjectSlug.parse(text) |> CmsErr.orInvalid("slug", "'${text}' は ${ProjectSlug.rule()} にしてください")

    ///
    /// 組織の下に作る。予約したプロジェクト slug と既にある物は使えない。
    ///
    pub def create(orgId: OrgId, slug: ProjectSlug, name: String): ProjectId \ Db + CmsErr + IdGen =
        CmsErr.raiseIfAny(if (List.memberOf(ProjectSlug.text(slug), reservedSlugs())) Violation.Violation("slug", "'${slug}' は予約されています") :: Nil else Nil);
        CmsErr.raiseIfAny(if (Option.isEmpty(findBySlug(slug))) Nil else Violation.Violation("slug", "'${slug}' は既にあります") :: Nil);
        CmsErr.raiseIfAny(if (String.isEmpty(String.trim(name))) Violation.Violation("name", "名前を付けてください") :: Nil else Nil);
        ProjectsQueries.insertProject({ publicId = IdGen.freshPublicId(), orgId = OrgId.toInt64(orgId), slug = ProjectSlug.text(slug), name = name }) |> Rows.expectId |> ProjectId.ProjectId

}
