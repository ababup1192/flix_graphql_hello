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
        ProjectsQueries.findProjectById(ProjectId.toInt64(id)) |> Option.map(AuthRows.toProject)

    ///
    /// プロジェクトの見え方。無いプロジェクトは private 扱い（存在を教えない）。
    ///
    pub def visibilityOf(id: ProjectId): Visibility \ DbRead =
        find(id) |> Option.map(found -> found#visibility) |> Option.getWithDefault(Visibility.Private)

    ///
    /// 組織の下のプロジェクト。
    ///
    pub def listOfOrg(orgId: OrgId): List[Project] \ DbRead =
        AuthQueries.listProjectsOfOrg(OrgId.toInt64(orgId)) |> List.map(AuthRows.toProject)

    ///
    /// 今のプロジェクトの公開範囲を変える。owner だけ。
    ///
    pub def updateVisibility(visibility: Visibility): Project \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.ManageProject);
        discard AuthQueries.updateProjectVisibility({ projectId = Tenant.currentId(), visibility = Visibility.text(visibility) });
        find(Tenant.current()) |> CmsErr.orNotFound(Entity.Organization, "${Tenant.current()}")

    ///
    /// 今のプロジェクトの版（content_version）。コンテンツ API の GET の ETag に入れる。公開・取り下げ・削除・型の変更で進む。
    /// 行が無ければ 0（RLS の印の無い Tx で projects は見えるので、通常は無い）。
    ///
    pub def contentVersion(): Int64 \ DbRead + Tenant =
        ProjectsQueries.findContentVersion(Tenant.currentId()) |> Option.map(row -> row#contentVersion) |> Option.getWithDefault(0i64)

    ///
    /// 今のプロジェクトの版を +1 する。公開・取り下げ・削除・型の変更のユースケースが同じ Tx で呼ぶ（権限はそちらが見る）。
    ///
    /// WhyNot: 下書きの保存で進めないのは、コンテンツ API の匿名の GET は公開中しか読めず、下書きが変わってもキャッシュの中身は変わらないため。
    /// 進めると下書きの保存のたびに CDN のキャッシュが全部外れる。
    ///
    pub def bumpContentVersion(): Unit \ DbWrite + Tenant =
        discard ProjectsQueries.bumpContentVersion(Tenant.currentId())

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
    /// 組織の下に作る。組織の owner だけ。予約したプロジェクト slug と既にある物は使えない。
    ///
    pub def create(orgId: OrgId, slug: ProjectSlug, name: String): ProjectId \ Db + CmsErr + IdGen + Session =
        Organizations.requireOwner(orgId);
        CmsErr.raiseIfAny(if (List.memberOf(ProjectSlug.text(slug), reservedSlugs())) Violation.Violation("slug", "'${slug}' は予約されています") :: Nil else Nil);
        CmsErr.raiseIfAny(if (Option.isEmpty(findBySlug(slug))) Nil else Violation.Violation("slug", "'${slug}' は既にあります") :: Nil);
        CmsErr.raiseIfAny(Naming.validateName("name", name));
        ProjectsQueries.insertProject({ publicId = IdGen.freshPublicId(), orgId = OrgId.toInt64(orgId), slug = ProjectSlug.text(slug), name = name }) |> Rows.expectId |> ProjectId.ProjectId

}
