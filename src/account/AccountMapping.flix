///
/// Account API の GraphQL の型とドメインの写し。id の文字列化と enum の対応はここだけが知る。
///
mod AccountMapping {

    pub def idOfUser(id: UserId): Id = Id.Id(Int64.toString(UserId.toInt64(id)))

    pub def idOfOrg(id: OrgId): Id = Id.Id(Int64.toString(OrgId.toInt64(id)))

    pub def idOfProject(id: ProjectId): Id = Id.Id(Int64.toString(ProjectId.toInt64(id)))

    ///
    /// GraphQL の ID から。数字でなければ invalid（argument は誤りの path）。
    ///
    pub def userId(argument: String, id: Id): UserId \ CmsErr = UserId.UserId(number(argument, id))

    pub def orgId(argument: String, id: Id): OrgId \ CmsErr = OrgId.OrgId(number(argument, id))

    def number(argument: String, id: Id): Int64 \ CmsErr =
        let Id.Id(text) = id;
        Int64.fromString(text) |> CmsErr.orInvalid(argument, "'${text}' は数字の ID ではありません")

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

    pub def visibilityToGql(visibility: Visibility): GeneratedAccount.Visibility = match visibility {
        case Visibility.Public  => GeneratedAccount.Visibility.Public
        case Visibility.Private => GeneratedAccount.Visibility.Private
    }

}
