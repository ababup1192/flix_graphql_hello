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
/// 組織。作った人が owner になる。
///
mod Organizations {

    ///
    /// 作る。人でなければ forbidden。
    ///
    pub def create(name: String): OrgId \ DbWrite + CmsErr + Session =
        let user = Session.currentUser();
        CmsErr.raiseIfAny(if (String.isEmpty(String.trim(name))) Violation.Violation("name", "名前を付けてください") :: Nil else Nil);
        let id = AuthQueries.insertOrganization(name) |> Rows.expectId;
        discard AuthQueries.upsertOrgMember({ userId = UserId.toInt64(user), orgId = id, role = OrgRole.text(OrgRole.Owner) });
        OrgId.OrgId(id)

    ///
    /// 組織の owner か。プロジェクトの作成とメンバーの追加に使う。
    ///
    pub def isOwner(userId: UserId, orgId: OrgId): Bool \ DbRead =
        AuthQueries.findOrgRole({ userId = UserId.toInt64(userId), orgId = OrgId.toInt64(orgId) })
            |> Option.exists(row -> row#role == OrgRole.text(OrgRole.Owner))

    ///
    /// 組織の owner だけができる操作の入口。
    ///
    pub def requireOwner(orgId: OrgId): Unit \ DbRead + CmsErr + Session =
        let user = Session.currentUser();
        if (isOwner(user, orgId)) () else CmsErr.forbidden(Permission.ManageProject)

    ///
    /// 組織にメンバーを足す（owner か member）。owner だけができる。
    ///
    pub def addMember(orgId: OrgId, userId: UserId, role: OrgRole): Unit \ Db + CmsErr + Session =
        requireOwner(orgId);
        discard AuthQueries.findUserById(UserId.toInt64(userId)) |> CmsErr.orNotFound(Entity.Member, "${userId}");
        discard AuthQueries.upsertOrgMember({ userId = UserId.toInt64(userId), orgId = OrgId.toInt64(orgId), role = OrgRole.text(role) })

    ///
    /// 組織の下にプロジェクトを作る。owner だけ。
    ///
    pub def createProject(orgId: OrgId, slug: String, name: String): ProjectId \ Db + CmsErr + Session =
        requireOwner(orgId);
        Projects.create(orgId, slug, name)

}
