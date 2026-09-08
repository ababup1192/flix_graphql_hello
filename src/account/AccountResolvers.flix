///
/// Account API のリゾルバ。Query / Mutation と、型ごとのフィールド。source はドメインの値。
/// 素通しのフィールドは生成された既定リゾルバに任せ、写しが要る物だけレコードの更新で上書きする。
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
            removeOrganizationMember = (_context, orgId, userId) -> { Organizations.removeMember(AccountMapping.orgId("orgId", orgId), AccountMapping.userId("userId", userId)); Ok(userId) },
            createPersonalAccessToken = createPersonalAccessToken(deps),
            revokePersonalAccessToken = (_context, id) -> { PersonalTokens.revoke(AccountMapping.publicIdOf(id)); Ok(true) }
        }

    /// Mutation.createPersonalAccessToken。pepper が無ければ発行できない
    def createPersonalAccessToken(deps: Deps): GeneratedAccount.MutationCreatePersonalAccessTokenResolver[AccountEff] =
        (_context, name, scope, ttlDays) -> match deps#auth#pepper {
            case Some(pepper) => Ok(issuePersonalToken(pepper, name, scope, ttlDays))
            case None         => Err(FieldError.internal("Personal Access Token を発行できません（CMS_API_KEY_PEPPER が設定されていません）"))
        }

    /// PAT を発行する。ログインの JWT で来た本人の証明を作って渡す。
    def issuePersonalToken(pepper: SecretHash.Pepper, name: String, scope: GeneratedAccount.PatScope, ttlDays: Option[Int32]): IssuedPersonalAccessToken \ DbWrite + CmsErr + IdGen + Session + Time.Clock.Clock =
        PersonalTokens.issue(Session.grantInteractive(), pepper, { name = name, scope = AccountMapping.patScopeOf(scope), ttlDays = ttlDays }, Time.Clock.now())

}

mod AccountPersonalAccessTokenResolvers {

    pub def resolvers(): GeneratedAccount.PersonalAccessTokenResolvers[AccountEff] =
        {
            id         = (_context, source) -> Ok(AccountMapping.idOfPublic(source#publicId)),
            scope      = (_context, source) -> Ok(AccountMapping.patScopeToGql(source#scope)),
            createdAt  = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            expiresAt  = (_context, source) -> Ok(Timestamp.toIso8601(source#expiresAt)),
            lastUsedAt = (_context, source) -> Ok(source#lastUsedAt |> Option.map(Timestamp.toIso8601)),
            revokedAt  = (_context, source) -> Ok(source#revokedAt |> Option.map(Timestamp.toIso8601))
            | GeneratedAccount.personalAccessTokenDefaults()
        }

}

mod AccountIssuedPersonalAccessTokenResolvers {

    pub def resolvers(): GeneratedAccount.IssuedPersonalAccessTokenResolvers[AccountEff] =
        {
            id        = (_context, source) -> Ok(AccountMapping.idOfPublic(source#publicId)),
            scope     = (_context, source) -> Ok(AccountMapping.patScopeToGql(source#scope)),
            expiresAt = (_context, source) -> Ok(Timestamp.toIso8601(source#expiresAt))
            | GeneratedAccount.issuedPersonalAccessTokenDefaults()
        }

}

mod AccountMeResolvers {

    pub def resolvers(): GeneratedAccount.MeResolvers[AccountEff] =
        {
            id            = (_context, source) -> Ok(AccountMapping.idOfPublic(source#user#publicId)),
            email         = (_context, source) -> Ok(source#user#email),
            name          = (_context, source) -> Ok(source#user#name),
            organizations = (_context, source) -> Ok(source#organizations),
            projects      = (_context, source) -> Ok(source#projects),
            personalAccessTokens = (_context, _source) -> Ok(PersonalTokens.list())
        }

}

mod AccountOrganizationResolvers {

    pub def resolvers(): GeneratedAccount.OrganizationResolvers[AccountEff] =
        {
            id        = (_context, source) -> Ok(AccountMapping.idOfPublic(source#publicId)),
            +members  = (_context, source) -> Ok(Organizations.members(source#id)),
            +projects = (_context, source) -> Ok(Organizations.projects(source#id))
            | GeneratedAccount.organizationDefaults()
        }

}

mod AccountOrganizationMemberResolvers {

    pub def resolvers(): GeneratedAccount.OrganizationMemberResolvers[AccountEff] =
        {
            userId = (_context, source) -> Ok(AccountMapping.idOfPublic(source#publicId)),
            role   = (_context, source) -> Ok(AccountMapping.orgRoleToGql(source#role))
            | GeneratedAccount.organizationMemberDefaults()
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
            id         = (_context, source) -> Ok(AccountMapping.idOfPublic(source#publicId)),
            slug       = (_context, source) -> Ok(ProjectSlug.text(source#slug)),
            visibility = (_context, source) -> Ok(AccountMapping.visibilityToGql(source#visibility))
            | GeneratedAccount.projectDefaults()
        }

}

mod AccountProjectMembershipResolvers {

    pub def resolvers(): GeneratedAccount.ProjectMembershipResolvers[AccountEff] =
        {
            project_ = (_context, source) -> Ok(source#target),
            role     = (_context, source) -> Ok(AccountMapping.roleToGql(source#role))
        }

}
