///
/// プロジェクトのメンバーと招待、組織の作成。誰が何をできるかは Session（役割）で守り、最後の owner は消せない。
///
mod Members {

    ///
    /// 今のプロジェクトのメンバー。
    ///
    pub def list(): List[Member] \ DbRead + DbErr + CmsErr + Tenant + Session =
        Session.require(Permission.ManageMembers);
        AuthQueries.listMembers(Tenant.currentId()) |> List.map(row ->
            { userId = UserId.UserId(row#id), email = row#email, name = row#name, role = Role.parse(row#role) |> Rows.orRaise("memberships.role", row#role) })

    ///
    /// 今のプロジェクトの招待。
    ///
    pub def invitations(): List[Invitation] \ DbRead + DbErr + CmsErr + Tenant + Session =
        Session.require(Permission.ManageMembers);
        AuthQueries.listInvitations(Tenant.currentId()) |> List.map(row ->
            { id = row#id, email = row#email, role = Role.parse(row#role) |> Rows.orRaise("invitations.role", row#role), createdAt = row#createdAt })

    ///
    /// email で招待する。既にユーザーがいれば membership を直接付け、いなければ招待として置く（初回ログインで写る）。
    ///
    /// WhyNot: email でユーザーを探して直接付けるのを「同じ発行元のユーザーだけ」に限らないのは、招待は owner の明示の操作で、
    /// 発行元は環境で 1 つに決まっているため。
    ///
    pub def invite(email: String, role: Role): Invitation \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.ManageMembers);
        let normalized = String.toLowerCase(String.trim(email));
        CmsErr.raiseIfAny(if (String.isMatch(regex = "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", normalized)) Nil else Violation.Violation("email", "'${email}' は email の形ではありません") :: Nil);
        let inviter = Session.currentUser();
        discard AuthQueries.upsertInvitation({ projectId = Tenant.currentId(), email = normalized, role = Role.text(role), invitedBy = UserId.toInt64(inviter) });
        invitations() |> List.find(invitation -> invitation#email == normalized) |> CmsErr.orNotFound(Entity.Invitation, normalized)

    ///
    /// 役割を変える。最後の owner を降格させる事はできない。
    ///
    pub def changeRole(userId: UserId, role: Role): Member \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.ManageMembers);
        let current = AuthQueries.findMembership({ userId = UserId.toInt64(userId), projectId = Tenant.currentId() }) |> CmsErr.orNotFound(Entity.Member, "${userId}");
        if (current#role == Role.text(Role.Owner) and role != Role.Owner) guardLastOwner() else ();
        discard AuthQueries.upsertMembership({ userId = UserId.toInt64(userId), projectId = Tenant.currentId(), role = Role.text(role) });
        list() |> List.find(member -> member#userId == userId) |> CmsErr.orNotFound(Entity.Member, "${userId}")

    ///
    /// 外す。最後の owner は外せない。
    ///
    pub def remove(userId: UserId): Unit \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.ManageMembers);
        let current = AuthQueries.findMembership({ userId = UserId.toInt64(userId), projectId = Tenant.currentId() }) |> CmsErr.orNotFound(Entity.Member, "${userId}");
        if (current#role == Role.text(Role.Owner)) guardLastOwner() else ();
        discard AuthQueries.deleteMembership({ userId = UserId.toInt64(userId), projectId = Tenant.currentId() })

    ///
    /// 招待を取り消す。
    ///
    pub def cancelInvitation(id: Int64): Unit \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.ManageMembers);
        let known = AuthQueries.listInvitations(Tenant.currentId()) |> List.exists(row -> row#id == id);
        if (known) discard AuthQueries.deleteInvitation(id) else CmsErr.notFound(Entity.Invitation, Int64.toString(id))

    /// プロジェクトの owner が 1 人しかいなければ invalid。組織の owner は数えない（組織側で守る）。
    def guardLastOwner(): Unit \ DbRead + CmsErr + Tenant =
        let owners = AuthQueries.countProjectOwners(Tenant.currentId()) |> Rows.total;
        CmsErr.raiseIfAny(if (owners <= 1i64) Violation.Violation("role", "最後の owner は外せません。先に別の owner を付けてください") :: Nil else Nil)

}

///
/// 組織。プロジェクトと請求のまとまり。作った人が owner になり、owner がプロジェクトと組織のメンバーを管理する。
/// Tenant を持たない（プロジェクトを選ぶ前の操作）。
///
mod Organizations {

    ///
    /// 作る。人でなければ forbidden。Closed なら既定の組織の owner だけ（セルフホストで見知らぬ人に組織を作らせない）。
    ///
    pub def create(signup: Signup, name: String): Organization \ Db + CmsErr + Session =
        let user = Session.currentUser();
        if (signup == Signup.Closed and not isOwner(user, OrgId.default())) CmsErr.forbidden(Permission.ManageProject) else ();
        CmsErr.raiseIfAny(if (String.isEmpty(String.trim(name))) Violation.Violation("name", "名前を付けてください") :: Nil else Nil);
        let id = AuthQueries.insertOrganization(name) |> Rows.expectId;
        discard AuthQueries.upsertOrgMember({ userId = UserId.toInt64(user), orgId = id, role = OrgRole.text(OrgRole.Owner) });
        { id = OrgId.OrgId(id), name = name }

    ///
    /// 1 つ。自分が member でなければ None（存在も教えない）。
    ///
    pub def find(orgId: OrgId): Option[Organization] \ DbRead + CmsErr + Session =
        let user = Session.currentUser();
        if (Option.isEmpty(roleOf(user, orgId))) None
        else AuthQueries.findOrganization(OrgId.toInt64(orgId)) |> Option.map(row -> { id = OrgId.OrgId(row#id), name = row#name })

    ///
    /// 組織での役割。属していなければ None。
    ///
    pub def roleOf(userId: UserId, orgId: OrgId): Option[OrgRole] \ DbRead =
        AuthQueries.findOrgRole({ userId = UserId.toInt64(userId), orgId = OrgId.toInt64(orgId) }) |> Option.flatMap(row -> OrgRole.parse(row#role))

    ///
    /// 組織の owner か。プロジェクトの作成とメンバーの追加に使う。
    ///
    pub def isOwner(userId: UserId, orgId: OrgId): Bool \ DbRead =
        roleOf(userId, orgId) == Some(OrgRole.Owner)

    ///
    /// 組織の owner だけができる操作の入口。member でもなければ notFound（存在を教えない）。
    ///
    pub def requireOwner(orgId: OrgId): Unit \ DbRead + CmsErr + Session =
        match roleOf(Session.currentUser(), orgId) {
            case Some(OrgRole.Owner) => ()
            case Some(_)             => CmsErr.forbidden(Permission.ManageProject)
            case None                => CmsErr.notFound(Entity.Organization, "${orgId}")
        }

    ///
    /// 組織のメンバー。owner だけが見られる（member には空）。
    ///
    pub def members(orgId: OrgId): List[OrganizationMember] \ DbRead + DbErr + CmsErr + Session =
        if (isOwner(Session.currentUser(), orgId))
            AuthQueries.listOrgMembers(OrgId.toInt64(orgId)) |> List.map(row ->
                { userId = UserId.UserId(row#id), email = row#email, name = row#name, role = OrgRole.parse(row#role) |> Rows.orRaise("org_members.role", row#role) })
        else Nil

    ///
    /// 既にログインした事のある人を email で足す（owner か member）。owner だけ。居なければ notFound。
    ///
    /// WhyNot: 組織への招待（未ログインの email を置いておく）を作らないのは、プロジェクトの招待で足りるため。
    /// 組織の owner を増やすのは稀で、相手は既にどこかのプロジェクトでログインしている。
    ///
    pub def addMemberByEmail(orgId: OrgId, email: String, role: OrgRole): OrganizationMember \ Db + CmsErr + Session =
        requireOwner(orgId);
        let user = Accounts.findByEmail(email) |> CmsErr.orNotFound(Entity.Member, email);
        discard AuthQueries.upsertOrgMember({ userId = UserId.toInt64(user#id), orgId = OrgId.toInt64(orgId), role = OrgRole.text(role) });
        { userId = user#id, email = user#email, name = user#name, role = role }

    ///
    /// 組織にメンバーを足す（owner か member）。owner だけができる。bootstrap とテストが使う。
    ///
    pub def addMember(orgId: OrgId, userId: UserId, role: OrgRole): Unit \ Db + CmsErr + Session =
        requireOwner(orgId);
        discard AuthQueries.findUserById(UserId.toInt64(userId)) |> CmsErr.orNotFound(Entity.Member, "${userId}");
        discard AuthQueries.upsertOrgMember({ userId = UserId.toInt64(userId), orgId = OrgId.toInt64(orgId), role = OrgRole.text(role) })

    ///
    /// 組織から外す。owner だけ。最後の owner は外せない。
    ///
    pub def removeMember(orgId: OrgId, userId: UserId): Unit \ Db + CmsErr + Session =
        requireOwner(orgId);
        let current = roleOf(userId, orgId) |> CmsErr.orNotFound(Entity.Member, "${userId}");
        if (current == OrgRole.Owner) guardLastOwner(orgId) else ();
        discard AuthQueries.deleteOrgMember({ userId = UserId.toInt64(userId), orgId = OrgId.toInt64(orgId) })

    /// 組織の owner が 1 人しかいなければ invalid。
    def guardLastOwner(orgId: OrgId): Unit \ DbRead + CmsErr =
        let owners = AuthQueries.countOrgOwners(OrgId.toInt64(orgId)) |> Rows.total;
        CmsErr.raiseIfAny(if (owners <= 1i64) Violation.Violation("role", "最後の owner は外せません。先に別の owner を付けてください") :: Nil else Nil)

    ///
    /// 組織の下にプロジェクトを作る。owner だけ。
    ///
    pub def createProject(orgId: OrgId, slug: ProjectSlug, name: String): Project \ Db + CmsErr + Session =
        requireOwner(orgId);
        let id = Projects.create(orgId, slug, name);
        Projects.find(id) |> CmsErr.orNotFound(Entity.Organization, "${id}")

    ///
    /// 組織の下のプロジェクト。member なら見られる。
    ///
    pub def projects(orgId: OrgId): List[Project] \ DbRead + DbErr + CmsErr + Session =
        if (Option.nonEmpty(roleOf(Session.currentUser(), orgId))) Projects.listOfOrg(orgId) else Nil

}
