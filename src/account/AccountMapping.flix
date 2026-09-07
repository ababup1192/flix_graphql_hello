///
/// Account API の GraphQL の型とドメインの写し。id の文字列化と enum の対応はここだけが知る。
///
mod AccountMapping {

    /// 外向きの id（public_id）をそのまま ID に。内部の連番は出さない。
    pub def idOfPublic(publicId: String): Id = Id.Id(publicId)

    /// ID（public_id）から内部の UserId。無ければ notFound。
    pub def userId(argument: String, id: Id): UserId \ DbRead + CmsErr =
        let Id.Id(publicId) = id;
        Accounts.requireByPublicId(argument, publicId)

    /// ID（public_id）から内部の OrgId。無ければ notFound。
    pub def orgId(_argument: String, id: Id): OrgId \ DbRead + CmsErr =
        let Id.Id(publicId) = id;
        Organizations.idOfPublic(publicId)

    pub def roleToGql(role: Role): GeneratedAccount.Role = match role {
        case Role.Viewer => GeneratedAccount.Role.Viewer
        case Role.Writer => GeneratedAccount.Role.Writer
        case Role.Editor => GeneratedAccount.Role.Editor
        case Role.Owner  => GeneratedAccount.Role.Owner
    }

    pub def orgRoleOf(role: GeneratedAccount.OrgRole): OrgRole = match role {
        case GeneratedAccount.OrgRole.Member => OrgRole.Member
        case GeneratedAccount.OrgRole.Owner  => OrgRole.Owner
    }

    pub def orgRoleToGql(role: OrgRole): GeneratedAccount.OrgRole = match role {
        case OrgRole.Member => GeneratedAccount.OrgRole.Member
        case OrgRole.Owner  => GeneratedAccount.OrgRole.Owner
    }

    pub def patScopeOf(scope: GeneratedAccount.PatScope): PatScope = match scope {
        case GeneratedAccount.PatScope.Read  => PatScope.Read
        case GeneratedAccount.PatScope.Write => PatScope.Write
    }

    pub def patScopeToGql(scope: PatScope): GeneratedAccount.PatScope = match scope {
        case PatScope.Read  => GeneratedAccount.PatScope.Read
        case PatScope.Write => GeneratedAccount.PatScope.Write
    }

    /// ID（public_id）の中の文字列。
    pub def publicIdOf(id: Id): String =
        let Id.Id(text) = id;
        text

    pub def visibilityToGql(visibility: Visibility): GeneratedAccount.Visibility = match visibility {
        case Visibility.Public  => GeneratedAccount.Visibility.Public
        case Visibility.Private => GeneratedAccount.Visibility.Private
    }

}
