///
/// プロジェクト（型と entry の集まり）。パスの /p/{プロジェクト slug}/ で選ぶ。既定プロジェクトは migration が作る。
///
mod Projects {

    ///
    /// プロジェクト slug で 1 つ。無ければ None。
    ///
    /// WhyNot: 権限の証明を取らないのは、Main.runRoute がプロジェクトを解決する（認証の前）時に呼ぶ物で、まだ主体が無いため。
    ///
    pub def findBySlug(slug: ProjectSlug): Option[ProjectId] \ DbRead =
        ProjectsQueries.findProjectBySlug(ProjectSlug.text(slug)) |> Option.map(row -> ProjectId.ProjectId(row#id))

    ///
    /// id で 1 つ（認証の文脈の形）。無ければ None。
    ///
    /// WhyNot: 権限の証明を取らないのは、認証（Authentication）と、証明を受けた側のユースケース（Webhooks の payload、Organizations.createProject）の部品で、
    /// プロジェクトの行そのものに Permission の腕が無いため（見え方は visibilityOf を認証が見る）。
    ///
    pub def find(id: ProjectId): Option[Project] \ DbRead =
        ProjectsQueries.findProjectById(ProjectId.toInt64(id)) |> Option.map(AuthRows.toProject)

    ///
    /// プロジェクトの見え方。無いプロジェクトは private 扱い（存在を教えない）。
    ///
    /// WhyNot: 権限の証明を取らないのは、認証がコンテンツ API の匿名を断るかを決めるために読む物で、主体が決まる前だから。
    ///
    pub def visibilityOf(id: ProjectId): Visibility \ DbRead =
        find(id) |> Option.map(found -> found#visibility) |> Option.getWithDefault(Visibility.Private)

    ///
    /// 組織の下のプロジェクト。
    ///
    /// WhyNot: 権限の証明を取らないのは、組織の member かどうか（Organizations.projects / Accounts.me が見る）はプロジェクトの Permission でなく組織の役割で決まるため。
    ///
    pub def listOfOrg(orgId: OrgId): List[Project] \ DbRead =
        AuthQueries.listProjectsOfOrg(OrgId.toInt64(orgId)) |> List.map(AuthRows.toProject)

    ///
    /// 今のプロジェクトの公開範囲を変える。owner だけ。
    ///
    pub def updateVisibility(_proof: Granted[ManageProject], visibility: Visibility): Project \ Db + CmsErr + IdGen + Tenant + Session =
        let existing = find(Tenant.current()) |> CmsErr.orNotFound(Entity.Organization, "${Tenant.current()}");
        discard AuthQueries.updateProjectVisibility({ projectId = Tenant.currentId(), visibility = Visibility.text(visibility) });
        Audit.record(AuditChange.ProjectVisibilityChanged(ProjectSlug.text(existing#slug), existing#visibility, visibility));
        find(Tenant.current()) |> CmsErr.orNotFound(Entity.Organization, "${Tenant.current()}")

    ///
    /// 今のプロジェクトの版（content_version）。コンテンツ API の GET の ETag に入れる。公開・取り下げ・削除・型の変更で進む。
    /// 行が無ければ 0（RLS の印の無い Tx で projects は見えるので、通常は無い）。
    ///
    /// WhyNot: 権限の証明を取らないのは、Main.runRoute が認証と同じ Tx で読む物で、版の数字は公開中の中身と同じく誰でも見て良いため（ETag として応答に出る）。
    ///
    pub def contentVersion(): Int64 \ DbRead + Tenant =
        ProjectsQueries.findContentVersion(Tenant.currentId()) |> Option.map(row -> row#contentVersion) |> Option.getWithDefault(0i64)

    ///
    /// 今のプロジェクトの版を +1 する。呼ぶのは `Publishing.notify` だけ（公開・取り下げ・削除・型の変更のユースケースと同じ Tx）。
    /// どの出来事で進めるか（下書きの保存では進めない）は `Publishing.effectsOf` の表。
    ///
    /// WhyNot: 権限の証明を取らないのは、outbox（Webhooks.emitEntry）と同じで、進めるのは操作の結果で誰ができるかは公開などの入口が決めているため。
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
