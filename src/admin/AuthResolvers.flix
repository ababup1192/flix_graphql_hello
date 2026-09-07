///
/// 管理 API の認証まわりの型（Me / Organization / Project / Member / Invitation / ApiKey）のリゾルバ。source はドメインの値。
///
mod MeResolvers {

    /// type Me のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.MeResolvers[AdminEff] =
        {
            id            = (_context, source) -> Ok(AdminMapping.idOfPublic(source#user#publicId)),
            email         = (_context, source) -> Ok(source#user#email),
            name          = (_context, source) -> Ok(source#user#name),
            roles         = (_context, source) -> Ok(source#roles |> List.map(AdminMapping.roleToGql)),
            permissions   = (_context, source) -> Ok(Authz.permissionsOf(source#roles)),
            organizations = (_context, source) -> Ok(source#organizations),
            projects      = (_context, source) -> Ok(source#projects)
        }

}

mod OrganizationResolvers {

    /// type Organization のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.OrganizationResolvers[AdminEff] =
        {
            id   = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            name = (_context, source) -> Ok(source#name)
        }

}

mod OrganizationMembershipResolvers {

    /// type OrganizationMembership のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.OrganizationMembershipResolvers[AdminEff] =
        {
            organization = (_context, source) -> Ok(source#organization),
            role         = (_context, source) -> Ok(AdminMapping.orgRoleToGql(source#role))
        }

}

mod ProjectResolvers {

    /// type Project のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ProjectResolvers[AdminEff] =
        {
            id         = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            slug       = (_context, source) -> Ok(ProjectSlug.text(source#slug)),
            name       = (_context, source) -> Ok(source#name),
            visibility = (_context, source) -> Ok(AdminMapping.visibilityToGql(source#visibility))
        }

}

mod ProjectMembershipResolvers {

    /// type ProjectMembership のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ProjectMembershipResolvers[AdminEff] =
        {
            project_ = (_context, source) -> Ok(source#target),
            role     = (_context, source) -> Ok(AdminMapping.roleToGql(source#role))
        }

}

mod MemberResolvers {

    /// type Member のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.MemberResolvers[AdminEff] =
        {
            userId = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            email  = (_context, source) -> Ok(source#email),
            name   = (_context, source) -> Ok(source#name),
            role   = (_context, source) -> Ok(AdminMapping.roleToGql(source#role))
        }

}

mod InvitationResolvers {

    /// type Invitation のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.InvitationResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            email     = (_context, source) -> Ok(source#email),
            role      = (_context, source) -> Ok(AdminMapping.roleToGql(source#role)),
            createdAt = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt))
        }

}

mod ApiKeyResolvers {

    /// type ApiKey のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ApiKeyResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            name      = (_context, source) -> Ok(source#name),
            scope     = (_context, source) -> Ok(AdminMapping.apiKeyScopeToGql(source#scope)),
            role      = (_context, source) -> Ok(AdminMapping.apiKeyRoleToGql(source#scope)),
            createdAt = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            expiresAt = (_context, source) -> Ok(source#expiresAt |> Option.map(Timestamp.toIso8601)),
            lastUsedAt = (_context, source) -> Ok(source#lastUsedAt |> Option.map(Timestamp.toIso8601)),
            revokedAt = (_context, source) -> Ok(source#revokedAt |> Option.map(Timestamp.toIso8601))
        }

}

mod IssuedApiKeyResolvers {

    /// type IssuedApiKey のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.IssuedApiKeyResolvers[AdminEff] =
        {
            id    = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            name  = (_context, source) -> Ok(source#name),
            scope = (_context, source) -> Ok(AdminMapping.apiKeyScopeToGql(source#scope)),
            role  = (_context, source) -> Ok(AdminMapping.apiKeyRoleToGql(source#scope)),
            expiresAt = (_context, source) -> Ok(source#expiresAt |> Option.map(Timestamp.toIso8601)),
            key   = (_context, source) -> Ok(source#key)
        }

}
