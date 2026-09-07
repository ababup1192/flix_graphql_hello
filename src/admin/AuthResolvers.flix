///
/// 管理 API の認証まわりの型（Me / Organization / Project / Member / Invitation / ApiKey）のリゾルバ。source はドメインの値。
/// 素通しのフィールドは生成された既定リゾルバに任せ、写しが要る物だけレコードの更新で上書きする。
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
            id = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId))
            | GeneratedAdmin.organizationDefaults()
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
            visibility = (_context, source) -> Ok(AdminMapping.visibilityToGql(source#visibility))
            | GeneratedAdmin.projectDefaults()
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
            role   = (_context, source) -> Ok(AdminMapping.roleToGql(source#role))
            | GeneratedAdmin.memberDefaults()
        }

}

mod InvitationResolvers {

    /// type Invitation のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.InvitationResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            role      = (_context, source) -> Ok(AdminMapping.roleToGql(source#role)),
            createdAt = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt))
            | GeneratedAdmin.invitationDefaults()
        }

}

mod ApiKeyResolvers {

    /// type ApiKey のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.ApiKeyResolvers[AdminEff] =
        {
            id        = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            scope     = (_context, source) -> Ok(AdminMapping.apiKeyScopeToGql(source#scope)),
            role      = (_context, source) -> Ok(AdminMapping.apiKeyRoleToGql(source#scope)),
            createdAt = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt)),
            expiresAt = (_context, source) -> Ok(source#expiresAt |> Option.map(Timestamp.toIso8601)),
            lastUsedAt = (_context, source) -> Ok(source#lastUsedAt |> Option.map(Timestamp.toIso8601)),
            revokedAt = (_context, source) -> Ok(source#revokedAt |> Option.map(Timestamp.toIso8601))
            | GeneratedAdmin.apiKeyDefaults()
        }

}

mod IssuedApiKeyResolvers {

    /// type IssuedApiKey のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.IssuedApiKeyResolvers[AdminEff] =
        {
            id    = (_context, source) -> Ok(AdminMapping.idOfPublic(source#publicId)),
            scope = (_context, source) -> Ok(AdminMapping.apiKeyScopeToGql(source#scope)),
            role  = (_context, source) -> Ok(AdminMapping.apiKeyRoleToGql(source#scope)),
            expiresAt = (_context, source) -> Ok(source#expiresAt |> Option.map(Timestamp.toIso8601))
            | GeneratedAdmin.issuedApiKeyDefaults()
        }

}
