///
/// 本人（Principal）からユーザーと主体（Actor）を組む。初回ログインで users を作り、招待を membership に写し、
/// 最初の owner（bootstrap）を組織の owner にする。
///
mod Accounts {

    ///
    /// bootstrap の設定。この email の初回ログインを既定の組織の owner にする。無ければ誰も owner にならない。
    ///
    pub type alias Bootstrap = { ownerEmail = Option[String] }

    ///
    /// 本人からユーザー。無ければ作り、email / name が変わっていれば更新する。招待と bootstrap もここで処理する。
    ///
    pub def resolveUser(bootstrap: Bootstrap, principal: Principal): User \ Db =
        let user = match AuthQueries.findUserByIdentity({ issuer = principal#issuer, subject = principal#subject }) {
            case Some(row) =>
                if (row#email != principal#email or row#name != principal#name)
                    discard AuthQueries.updateUserProfile({ id = row#id, email = principal#email, name = principal#name })
                else ();
                { id = UserId.UserId(row#id), issuer = row#issuer, subject = row#subject, email = principal#email, name = principal#name }
            case None =>
                let id = AuthQueries.insertUser({ issuer = principal#issuer, subject = principal#subject, email = principal#email, name = principal#name }) |> Rows.expectId;
                { id = UserId.UserId(id), issuer = principal#issuer, subject = principal#subject, email = principal#email, name = principal#name }
        };
        acceptInvitations(user);
        bootstrapOwner(bootstrap, user);
        user

    /// この email 宛の招待を membership に写して消す。
    def acceptInvitations(user: User): Unit \ Db =
        AuthQueries.listInvitationsForEmail(user#email) |> List.forEach(invitation -> {
            discard AuthQueries.upsertMembership({ userId = UserId.toInt64(user#id), projectId = invitation#projectId, role = invitation#role });
            discard AuthQueries.deleteInvitation(invitation#id)
        })

    ///
    /// bootstrap の email なら既定の組織の owner にする。既に owner がいる組織には何もしない（最初の 1 人だけ）。
    ///
    /// WhyNot: 2 人目以降も owner にしないのは、環境変数を書き換えるだけで owner を増やせる道を残さないため。
    /// 以後の owner は既存の owner が招待する。
    ///
    def bootstrapOwner(bootstrap: Bootstrap, user: User): Unit \ Db =
        let org = OrgId.toInt64(OrgId.default());
        let owners = AuthQueries.countOrgOwners(org) |> Rows.total;
        if (bootstrap#ownerEmail == Some(user#email) and owners == 0i64)
            discard AuthQueries.upsertOrgMember({ userId = UserId.toInt64(user#id), orgId = org, role = OrgRole.text(OrgRole.Owner) })
        else ()

    ///
    /// このプロジェクトでの主体。直接の membership と、プロジェクトが属する組織での役割から役割の並びを組む。
    ///
    pub def actorFor(user: User, projectId: ProjectId): Actor \ DbRead =
        let membership = AuthQueries.findMembership({ userId = UserId.toInt64(user#id), projectId = ProjectId.toInt64(projectId) })
            |> Option.flatMap(row -> Role.parse(row#role));
        let orgRole = AuthQueries.findProjectOrg(ProjectId.toInt64(projectId))
            |> Option.flatMap(owner -> AuthQueries.findOrgRole({ userId = UserId.toInt64(user#id), orgId = owner#orgId }))
            |> Option.flatMap(row -> OrgRole.parse(row#role));
        Actor.User(user#id, user#email, Authz.rolesOf(membership, orgRole))

    ///
    /// プロジェクト無しの管理 API（me など）の主体。役割は空。
    ///
    pub def actorWithoutProject(user: User): Actor =
        Actor.User(user#id, user#email, Nil)

    ///
    /// ユーザーが属する組織と役割。
    ///
    pub def organizationsOf(userId: UserId): List[{ id = OrgId, name = String, role = OrgRole }] \ DbRead =
        AuthQueries.listOrganizationsOfUser(UserId.toInt64(userId))
            |> List.filterMap(row -> OrgRole.parse(row#role) |> Option.map(role -> { id = OrgId.OrgId(row#id), name = row#name, role = role }))

    ///
    /// ユーザーが触れるプロジェクトと役割。直接の membership に加え、owner である組織の全プロジェクト（owner として）。
    /// 同じプロジェクトが両方にあれば高い方の役割。
    ///
    pub def projectsOf(userId: UserId): List[{ id = ProjectId, slug = String, name = String, role = Role }] \ DbRead =
        let direct = AuthQueries.listMembershipsOfUser(UserId.toInt64(userId))
            |> List.filterMap(row -> Role.parse(row#role) |> Option.map(role -> { id = ProjectId.ProjectId(row#id), slug = row#slug, name = row#name, role = role }));
        let owned = organizationsOf(userId) |> List.filter(org -> org#role == OrgRole.Owner)
            |> List.flatMap(org -> AuthQueries.listProjectsOfOrg(OrgId.toInt64(org#id))
                |> List.map(row -> { id = ProjectId.ProjectId(row#id), slug = row#slug, name = row#name, role = Role.Owner }));
        (direct ::: owned)
            |> List.foldLeft((acc, item) -> match List.find(found -> found#id == item#id, acc) {
                case Some(found) if found#role >= item#role => acc
                case Some(_) => (item :: List.filter(found -> found#id != item#id, acc))
                case None    => item :: acc
            }, Nil)
            |> List.sortWith((a, b) -> Order.compare(a#id, b#id))

}
