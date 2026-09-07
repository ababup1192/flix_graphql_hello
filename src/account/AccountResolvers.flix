///
/// Account API のリゾルバ。Query / Mutation と、型ごとのフィールド。source はドメインの値。
///
mod AccountQueryResolvers {

    pub def resolvers(): GeneratedAccount.QueryResolvers[AccountEff] =
        {
            me           = _context -> Ok(Accounts.me()),
            organization = (_context, id) -> Ok(Organizations.find(AccountMapping.orgId("id", id)))
        }

}

mod AccountMutationResolvers {

    pub def resolvers(deps: Deps): GeneratedAccount.MutationResolvers[AccountEff] =
        {
            createOrganization       = (_context, name) -> Ok(Organizations.create(deps#auth#signup, name)),
            createProject            = (_context, orgId, slug, name) -> Ok(Organizations.createProject(AccountMapping.orgId("orgId", orgId), Projects.parseSlug(slug), name)),
            addOrganizationMember    = (_context, orgId, email, role) -> Ok(Organizations.addMemberByEmail(AccountMapping.orgId("orgId", orgId), email, AccountMapping.orgRoleOf(role))),
            removeOrganizationMember = (_context, orgId, userId) -> { Organizations.removeMember(AccountMapping.orgId("orgId", orgId), AccountMapping.userId("userId", userId)); Ok(userId) }
        }

}

mod AccountMeResolvers {

    pub def resolvers(): GeneratedAccount.MeResolvers[AccountEff] =
        {
            id            = (_context, source) -> Ok(AccountMapping.idOfUser(source#user#id)),
            email         = (_context, source) -> Ok(source#user#email),
            name          = (_context, source) -> Ok(source#user#name),
            organizations = (_context, source) -> Ok(source#organizations),
            projects      = (_context, source) -> Ok(source#projects)
        }

}

mod AccountOrganizationResolvers {

    pub def resolvers(): GeneratedAccount.OrganizationResolvers[AccountEff] =
        {
            id       = (_context, source) -> Ok(AccountMapping.idOfOrg(source#id)),
            name     = (_context, source) -> Ok(source#name),
            members  = (_context, source) -> Ok(Organizations.members(source#id)),
            projects = (_context, source) -> Ok(Organizations.projects(source#id))
        }

}

mod AccountOrganizationMemberResolvers {

    pub def resolvers(): GeneratedAccount.OrganizationMemberResolvers[AccountEff] =
        {
            userId = (_context, source) -> Ok(AccountMapping.idOfUser(source#userId)),
            email  = (_context, source) -> Ok(source#email),
            name   = (_context, source) -> Ok(source#name),
            role   = (_context, source) -> Ok(AccountMapping.orgRoleToGql(source#role))
        }

}

mod AccountOrganizationMembershipResolvers {

    pub def resolvers(): GeneratedAccount.OrganizationMembershipResolvers[AccountEff] =
        {
            organization = (_context, source) -> Ok(source#organization),
            role         = (_context, source) -> Ok(AccountMapping.orgRoleToGql(source#role))
        }

}

mod AccountProjectResolvers {

    pub def resolvers(): GeneratedAccount.ProjectResolvers[AccountEff] =
        {
            id         = (_context, source) -> Ok(AccountMapping.idOfProject(source#id)),
            slug       = (_context, source) -> Ok(ProjectSlug.text(source#slug)),
            name       = (_context, source) -> Ok(source#name),
            visibility = (_context, source) -> Ok(AccountMapping.visibilityToGql(source#visibility))
        }

}

mod AccountProjectMembershipResolvers {

    pub def resolvers(): GeneratedAccount.ProjectMembershipResolvers[AccountEff] =
        {
            project_ = (_context, source) -> Ok(source#target),
            role     = (_context, source) -> Ok(AccountMapping.roleToGql(source#role))
        }

}
