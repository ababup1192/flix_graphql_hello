///
/// auth の表（users / organizations / projects / memberships / invitations / api_keys / personal_access_tokens）の行とドメインの値の変換。
/// 列名と、列の番兵（role 無し = ''、期限無し = 0）を知るのはここだけ。
/// enum の列は書く時に検査しているので、読めなければ DB の壊れ（DbErr）。
///
mod AuthRows {

    pub def toUser(row: { id = Int64, publicId = String, issuer = String, subject = String, email = String, name = String | r }): User =
        { id = UserId.UserId(row#id), publicId = row#publicId, issuer = row#issuer, subject = row#subject, email = row#email, name = row#name }

    pub def toOrganization(row: { id = Int64, publicId = String, name = String | r }): Organization =
        { id = OrgId.OrgId(row#id), publicId = row#publicId, name = row#name }

    pub def toProject(row: { id = Int64, publicId = String, slug = String, name = String, visibility = String | r }): Project \ DbErr =
        { id = ProjectId.ProjectId(row#id),
          publicId = row#publicId,
          slug = ProjectSlug.parse(row#slug) |> Rows.orRaise("projects.slug", row#slug),
          name = row#name,
          visibility = Visibility.parse(row#visibility) |> Rows.orRaise("projects.visibility", row#visibility) }

    /// memberships と users を JOIN した行。
    pub def toMember(row: { id = Int64, publicId = String, email = String, name = String, role = String | r }): Member \ DbErr =
        { userId = UserId.UserId(row#id), publicId = row#publicId, email = row#email, name = row#name, role = Role.parse(row#role) |> Rows.orRaise("memberships.role", row#role) }

    /// org_members と users を JOIN した行。
    pub def toOrganizationMember(row: { id = Int64, publicId = String, email = String, name = String, role = String | r }): OrganizationMember \ DbErr =
        { userId = UserId.UserId(row#id), publicId = row#publicId, email = row#email, name = row#name, role = OrgRole.parse(row#role) |> Rows.orRaise("org_members.role", row#role) }

    pub def toInvitation(row: { id = Int64, publicId = String, email = String, role = String, createdAt = Timestamp.Timestamp | r }): Invitation \ DbErr =
        { id = row#id, publicId = row#publicId, email = row#email, role = Role.parse(row#role) |> Rows.orRaise("invitations.role", row#role), createdAt = row#createdAt }

    pub def toApiKey(row: { id = Int64, publicId = String, name = String, scope = String, role = Option[String], createdAt = Timestamp.Timestamp,
                            expiresAt = Option[Timestamp.Timestamp], lastUsedAt = Option[Timestamp.Timestamp], revokedAt = Option[Timestamp.Timestamp] | r }): ApiKey \ DbErr =
        { id = row#id, publicId = row#publicId, name = row#name,
          scope = toApiKeyScope(row),
          createdAt = row#createdAt, expiresAt = row#expiresAt, lastUsedAt = row#lastUsedAt, revokedAt = row#revokedAt }

    ///
    /// API キーの発行の入力を insertApiKey の行に。役割が無ければ ''（query が NULL にする）、期限が無ければ 0（query が NULL にする）。
    ///
    pub def toApiKeyInsert(draft: { publicId = String, projectId = Int64, name = String, keyHash = String, pepperId = String, scope = ApiKeyScope, expiresAt = Option[Timestamp.Timestamp] }):
            { publicId = String, projectId = Int64, name = String, keyHash = String, pepperId = String, scope = String, role = String, expiresAtMillis = Int64 } =
        { publicId = draft#publicId, projectId = draft#projectId, name = draft#name, keyHash = draft#keyHash, pepperId = draft#pepperId,
          scope = ApiKeyScope.text(draft#scope),
          role = ApiKeyScope.roleOf(draft#scope) |> Option.map(Role.text) |> Option.getWithDefault(""),
          expiresAtMillis = draft#expiresAt |> Option.map(Timestamp.toEpochMillis) |> Option.getWithDefault(0i64) }

    /// scope 列と role 列の組から。組が合わなければ DB の壊れ。
    pub def toApiKeyScope(row: { scope = String, role = Option[String] | r }): ApiKeyScope \ DbErr =
        ApiKeyScope.parse(row#scope, row#role) |> Rows.orRaise("api_keys.scope", "${row#scope}/${row#role}")

    pub def toPersonalAccessToken(row: { id = Int64, publicId = String, name = String, scope = String, createdAt = Timestamp.Timestamp,
                                         expiresAt = Timestamp.Timestamp, lastUsedAt = Option[Timestamp.Timestamp], revokedAt = Option[Timestamp.Timestamp] | r }): PersonalAccessToken \ DbErr =
        { id = row#id, publicId = row#publicId, name = row#name,
          scope = PatScope.parse(row#scope) |> Rows.orRaise("personal_access_tokens.scope", row#scope),
          createdAt = row#createdAt, expiresAt = row#expiresAt, lastUsedAt = row#lastUsedAt, revokedAt = row#revokedAt }

}
