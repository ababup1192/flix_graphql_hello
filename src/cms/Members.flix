///
/// プロジェクトのメンバーと招待、組織の作成。pub の入口は manageMembers の証明（`Granted[ManageMembers]`）を最初の引数で受け、最後の owner は消せない。
///
mod Members {

    ///
    /// 今のプロジェクトのメンバー。
    ///
    pub def list(_proof: Granted[ManageMembers]): List[Member] \ DbRead + Tenant =
        AuthQueries.listMembers(Tenant.currentId()) |> List.map(AuthRows.toMember)

    ///
    /// 今のプロジェクトの招待。
    ///
    pub def invitations(_proof: Granted[ManageMembers]): List[Invitation] \ DbRead + Tenant =
        AuthQueries.listInvitations(Tenant.currentId()) |> List.map(AuthRows.toInvitation)

    ///
    /// email で招待する。既にユーザーがいれば membership を直接付け、いなければ招待として置く（初回ログインで写る）。
    ///
    /// WhyNot: email でユーザーを探して直接付けるのを「同じ発行元のユーザーだけ」に限らないのは、招待は owner の明示の操作で、
    /// 発行元は環境で 1 つに決まっているため。
    ///
    pub def invite(proof: Granted[ManageMembers], email: String, role: Role): Invitation \ Db + CmsErr + IdGen + Tenant + Session =
        let normalized = String.toLowerCase(String.trim(email));
        CmsErr.raiseIfAny(if (String.isMatch(regex = "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", normalized)) Nil else Violation.Violation("email", "'${email}' は email の形ではありません") :: Nil);
        let inviter = Session.currentUser();
        discard AuthQueries.upsertInvitation({ publicId = IdGen.freshPublicId(), projectId = Tenant.currentId(), email = normalized, role = Role.text(role), invitedBy = UserId.toInt64(inviter) });
        invitations(proof) |> List.find(invitation -> invitation#email == normalized) |> CmsErr.orNotFound(Entity.Invitation, normalized)

    ///
    /// 役割を変える。最後の owner を降格させる事はできない。
    ///
    pub def changeRole(proof: Granted[ManageMembers], userId: UserId, role: Role): Member \ Db + CmsErr + Tenant =
        let current = roleOf(userId) |> CmsErr.orNotFound(Entity.Member, "${userId}");
        if (current == Role.Owner and role != Role.Owner) guardLastOwner() else ();
        discard AuthQueries.upsertMembership({ userId = UserId.toInt64(userId), projectId = Tenant.currentId(), role = Role.text(role) });
        list(proof) |> List.find(member -> member#userId == userId) |> CmsErr.orNotFound(Entity.Member, "${userId}")

    ///
    /// 外す。最後の owner は外せない。
    ///
    pub def remove(_proof: Granted[ManageMembers], userId: UserId): Unit \ Db + CmsErr + Tenant =
        let current = roleOf(userId) |> CmsErr.orNotFound(Entity.Member, "${userId}");
        if (current == Role.Owner) guardLastOwner() else ();
        discard AuthQueries.deleteMembership({ userId = UserId.toInt64(userId), projectId = Tenant.currentId() })

    ///
    /// 招待を取り消す。
    ///
    pub def cancelInvitation(_proof: Granted[ManageMembers], publicId: String): Unit \ DbWrite + CmsErr + Tenant =
        let deleted = AuthQueries.deleteInvitationByPublicId({ publicId = publicId, projectId = Tenant.currentId() });
        if (deleted == 0) CmsErr.notFound(Entity.Invitation, publicId) else ()

    /// 今のプロジェクトでの直接の役割。membership が無ければ None。
    def roleOf(userId: UserId): Option[Role] \ DbRead + Tenant =
        AuthQueries.findMembership({ userId = UserId.toInt64(userId), projectId = Tenant.currentId() }) |> Option.flatMap(row -> Role.parse(row#role))

    /// プロジェクトの owner が 1 人しかいなければ invalid。組織の owner は数えない（組織側で守る）。
    def guardLastOwner(): Unit \ DbRead + CmsErr + Tenant =
        AuthQueries.countProjectOwners(Tenant.currentId()) |> Rows.total |> requireAnotherOwner

    ///
    /// owner が 1 人しかいなければ invalid。プロジェクトと組織で同じ規則。
    ///
    pub def requireAnotherOwner(owners: Int64): Unit \ CmsErr =
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
    pub def create(signup: Signup, name: String): Organization \ Db + CmsErr + IdGen + Session =
        let user = Session.currentUser();
        if (signup == Signup.Closed and not isOwner(user, OrgId.default())) CmsErr.forbidden(Permission.ManageProject) else ();
        CmsErr.raiseIfAny(Naming.validateName("name", name));
        let publicId = IdGen.freshPublicId();
        let id = AuthQueries.insertOrganization({ publicId = publicId, name = name }) |> Rows.expectId;
        discard AuthQueries.upsertOrgMember({ userId = UserId.toInt64(user), orgId = id, role = OrgRole.text(OrgRole.Owner) });
        { id = OrgId.OrgId(id), publicId = publicId, name = name }

    ///
    /// 1 つ。自分が member でなければ None（存在も教えない）。read の PAT でも読める。
    ///
    pub def find(orgId: OrgId): Option[Organization] \ DbRead + Session =
        Session.currentUserForRead()
            |> Option.filter(user -> Option.nonEmpty(roleOf(user, orgId)))
            |> Option.flatMap(_ -> AuthQueries.findOrganization(OrgId.toInt64(orgId)) |> Option.map(AuthRows.toOrganization))

    ///
    /// 外向きの id から内部の id。無ければ notFound（member かどうかは呼ぶ先が見る）。
    ///
    /// WhyNot: 権限の証明を取らないのは、id の写しで中身を返さず、写した先（find / members / addMember …）が本人か owner かを見るため。
    ///
    pub def idOfPublic(publicId: String): OrgId \ DbRead + CmsErr =
        AuthQueries.findOrganizationByPublicId(publicId) |> Option.map(row -> OrgId.OrgId(row#id)) |> CmsErr.orNotFound(Entity.Organization, publicId)

    ///
    /// 組織での役割。属していなければ None。
    ///
    def roleOf(userId: UserId, orgId: OrgId): Option[OrgRole] \ DbRead =
        AuthQueries.findOrgRole({ userId = UserId.toInt64(userId), orgId = OrgId.toInt64(orgId) }) |> Option.flatMap(row -> OrgRole.parse(row#role))

    ///
    /// 組織の owner か。
    ///
    def isOwner(userId: UserId, orgId: OrgId): Bool \ DbRead =
        roleOf(userId, orgId) == Some(OrgRole.Owner)

    ///
    /// 組織の owner だけができる操作の入口。member でもなければ notFound（存在を教えない）。サーバ自身（System）は通る。
    ///
    pub def requireOwner(orgId: OrgId): Unit \ DbRead + CmsErr + Session = match Session.current() {
        case Actor.System => ()
        case _ => match roleOf(Session.currentUser(), orgId) {
            case Some(OrgRole.Owner) => ()
            case Some(_)             => CmsErr.forbidden(Permission.ManageProject)
            case None                => CmsErr.notFound(Entity.Organization, "${orgId}")
        }
    }

    ///
    /// 組織のメンバー。owner だけが見られる（member と人でない主体には空）。read の PAT でも読める。
    ///
    pub def members(orgId: OrgId): List[OrganizationMember] \ DbRead + Session =
        if (Session.currentUserForRead() |> Option.exists(user -> isOwner(user, orgId)))
            AuthQueries.listOrgMembers(OrgId.toInt64(orgId)) |> List.map(AuthRows.toOrganizationMember)
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
        { userId = user#id, publicId = user#publicId, email = user#email, name = user#name, role = role }

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
        AuthQueries.countOrgOwners(OrgId.toInt64(orgId)) |> Rows.total |> Members.requireAnotherOwner

    ///
    /// 組織の下にプロジェクトを作る。owner だけ（Projects.create が見る）。
    ///
    pub def createProject(orgId: OrgId, slug: ProjectSlug, name: String): Project \ Db + CmsErr + IdGen + Session =
        let id = Projects.create(orgId, slug, name);
        Projects.find(id) |> CmsErr.orNotFound(Entity.Organization, "${id}")

    ///
    /// 組織の下のプロジェクト。member なら見られる（人でない主体には空）。read の PAT でも読める。
    ///
    pub def projects(orgId: OrgId): List[Project] \ DbRead + Session =
        if (Session.currentUserForRead() |> Option.exists(user -> Option.nonEmpty(roleOf(user, orgId)))) Projects.listOfOrg(orgId) else Nil

}
