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
    pub def resolveUser(bootstrap: Bootstrap, principal: Principal): User \ Db + IdGen =
        let user = match AuthQueries.findUserByIdentity({ issuer = principal#issuer, subject = principal#subject }) {
            case Some(row) =>
                if (row#email != principal#email or row#name != principal#name)
                    discard AuthQueries.updateUserProfile({ id = row#id, email = principal#email, name = principal#name })
                else ();
                { id = UserId.UserId(row#id), publicId = row#publicId, issuer = row#issuer, subject = row#subject, email = principal#email, name = principal#name }
            case None =>
                let publicId = IdGen.freshPublicId();
                let id = AuthQueries.insertUser({ publicId = publicId, issuer = principal#issuer, subject = principal#subject, email = principal#email, name = principal#name }) |> Rows.expectId;
                { id = UserId.UserId(id), publicId = publicId, issuer = principal#issuer, subject = principal#subject, email = principal#email, name = principal#name }
        };
        // RLS の印。以後この Tx では、自分の memberships と自分宛の invitations がプロジェクトを跨いで見える
        discard TenantQueries.stampUser({ userId = "${user#id}", email = user#email });
        acceptInvitations(user);
        bootstrapOwner(bootstrap, user);
        user

    ///
    /// PAT で来た人。users を引いて RLS の印を置く。招待の受け入れと bootstrap はしない（PAT は既にログインした人が作る物）。
    /// 無ければ None（ユーザーが消えていれば PAT も効かない）。
    ///
    pub def resolveUserById(userId: UserId): Option[User] \ DbRead =
        AuthQueries.findUserById(UserId.toInt64(userId)) |> Option.map(row -> {
            let user = AuthRows.toUser(row);
            discard TenantQueries.stampUser({ userId = "${user#id}", email = user#email });
            user
        })

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
    pub def actorFor(user: User, projectId: ProjectId, login: Login): Actor \ DbRead =
        let membership = AuthQueries.findMembership({ userId = UserId.toInt64(user#id), projectId = ProjectId.toInt64(projectId) })
            |> Option.flatMap(row -> Role.parse(row#role));
        let orgRole = AuthQueries.findProjectOrg(ProjectId.toInt64(projectId))
            |> Option.flatMap(owner -> AuthQueries.findOrgRole({ userId = UserId.toInt64(user#id), orgId = owner#orgId }))
            |> Option.flatMap(row -> OrgRole.parse(row#role));
        Actor.User(user#id, user#email, Authz.rolesOf(membership, orgRole), login)

    ///
    /// Account API（プロジェクトを選ぶ前の操作）の主体。プロジェクトの役割は空。
    ///
    pub def actorWithoutProject(user: User, login: Login): Actor =
        Actor.User(user#id, user#email, Nil, login)

    ///
    /// email で 1 人。誰も居なければ None、同じ email が発行元をまたいで複数居れば invalid（どちらか決められない）。
    ///
    pub def findByEmail(email: String): Option[User] \ DbRead + CmsErr =
        match AuthQueries.listUsersByEmail(String.toLowerCase(String.trim(email))) {
            case Nil        => None
            case row :: Nil => Some(AuthRows.toUser(row))
            case _          => CmsErr.invalid(Violation.Violation("email", "'${email}' のユーザーが複数います。発行元を 1 つにしてください") :: Nil)
        }

    ///
    /// 外向きの id で 1 人。無ければ None。
    ///
    def findByPublicId(publicId: String): Option[User] \ DbRead =
        AuthQueries.findUserByPublicId(publicId) |> Option.map(AuthRows.toUser)

    ///
    /// 外向きの id から内部の UserId。無ければ notFound（argument は誤りの path）。GraphQL の写しが使う。
    ///
    pub def requireByPublicId(argument: String, publicId: String): UserId \ DbRead + CmsErr =
        findByPublicId(publicId) |> Option.map(user -> user#id) |> CmsErr.orNotFound(Entity.Member, "${argument}=${publicId}")

    ///
    /// ユーザーが属する組織と役割。
    ///
    def organizationsOf(userId: UserId): List[OrganizationMembership] \ DbRead =
        AuthQueries.listOrganizationsOfUser(UserId.toInt64(userId))
            |> List.filterMap(row -> OrgRole.parse(row#role) |> Option.map(role -> { organization = AuthRows.toOrganization(row), role = role }))

    ///
    /// ユーザーが触れるプロジェクトと役割。直接の membership に加え、owner である組織の全プロジェクト（owner として）。
    /// 同じプロジェクトが両方にあれば高い方の役割。
    ///
    def projectsOf(userId: UserId): List[ProjectMembership] \ DbRead =
        let direct = AuthQueries.listMembershipsOfUser(UserId.toInt64(userId))
            |> List.filterMap(row -> Role.parse(row#role) |> Option.map(role -> { target = AuthRows.toProject(row), role = role }));
        let owned = organizationsOf(userId) |> List.filter(org -> org#role == OrgRole.Owner)
            |> List.flatMap(org -> Projects.listOfOrg(org#organization#id) |> List.map(target -> { target = target, role = Role.Owner }));
        (direct ::: owned)
            |> List.foldLeft((acc, item) -> match List.find(found -> found#target#id == item#target#id, acc) {
                case Some(found) if found#role >= item#role => acc
                case Some(_) => (item :: List.filter(found -> found#target#id != item#target#id, acc))
                case None    => item :: acc
            }, Nil)
            |> List.sortWith((a, b) -> Order.compare(a#target#id, b#target#id))

    ///
    /// 自分。人でなければ None。
    ///
    pub def me(): Option[Me] \ DbRead + Session = match Session.current() {
        case Actor.User(id, _, roles, login) => meOf(id, Authz.effectiveRoles(login, roles))
        case _                               => None
    }

    def meOf(id: UserId, roles: List[Role]): Option[Me] \ DbRead =
        AuthQueries.findUserById(UserId.toInt64(id)) |> Option.map(row ->
            { user = AuthRows.toUser(row), roles = roles, organizations = organizationsOf(id), projects = projectsOf(id) })

}
