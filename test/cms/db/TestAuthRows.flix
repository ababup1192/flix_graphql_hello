///
/// AuthRows: users / organizations / projects / memberships / org_members / invitations / api_keys / personal_access_tokens の行と
/// ドメインの値の往復。純粋（DbErr は Result に落として見る）。
///
/// 観点:
/// - 往復: Role / OrgRole / Visibility / ApiKeyScope / PatScope の全 case、Option の時刻の None / Some、public_id はそのまま
/// - 境界: 規則外の slug / role / visibility / scope は DbErr。scope 列と role 列の組が合わない鍵も DbErr
///
mod TestAuthRows {

    def at(millis: Int64): Timestamp.Timestamp = Timestamp.fromEpochMillis(millis)

    def publicId(): String = "3f9a1c2b7e6d"

    // ---- users / organizations ----

    /// users と organizations の行は失敗しない。id は包み、public_id と文字列はそのまま。
    @Test
    def testUserAndOrganization(): Unit \ Assert =
        let user = AuthRows.toUser({ id = 3i64, publicId = publicId(), issuer = "https://issuer.example", subject = "sub|1", email = "a@example.com", name = "" });
        let organization = AuthRows.toOrganization({ id = 4i64, publicId = publicId(), name = "組織" });
        Assert.assertEq(expected = ((UserId.UserId(3i64), publicId(), "https://issuer.example", "sub|1", "a@example.com", ""), (OrgId.OrgId(4i64), publicId(), "組織")),
            ((user#id, user#publicId, user#issuer, user#subject, user#email, user#name), (organization#id, organization#publicId, organization#name)))

    // ---- projects ----

    /// projects の行は visibility の全 case で往復し、slug は ProjectSlug になる。
    @Test
    def testProjectRoundTrip(): Unit \ Assert =
        let table = List#{Visibility.Public, Visibility.Private};
        Assert.assertEq(expected = table |> List.map(visibility -> Ok((ProjectId.ProjectId(2i64), publicId(), ProjectSlug.default(), "既定", visibility))),
            table |> List.map(visibility -> DbErr.runWithResult(() -> {
                let found = AuthRows.toProject({ id = 2i64, publicId = publicId(), slug = "default", name = "既定", visibility = Visibility.text(visibility) });
                (found#id, found#publicId, found#slug, found#name, found#visibility)
            })))

    /// 規則外の slug（大文字）と知らない visibility は DbErr。
    @Test
    def testToProjectRejects(): Unit \ Assert =
        let good = { id = 2i64, publicId = publicId(), slug = "default", name = "既定", visibility = "public" };
        Assert.assertEq(expected = (true, true),
            (DbErr.runWithResult(() -> AuthRows.toProject({ slug = "Default" | good })) |> Result.isErr,
             DbErr.runWithResult(() -> AuthRows.toProject({ visibility = "internal" | good })) |> Result.isErr))

    // ---- memberships / org_members / invitations ----

    /// プロジェクトのメンバーは Role の全 case、組織のメンバーは OrgRole の全 case、招待は Role の全 case で往復する。
    @Test
    def testRoleRowsRoundTrip(): Unit \ Assert =
        let roles = List#{Role.Viewer, Role.Writer, Role.Editor, Role.Owner};
        let orgRoles = List#{OrgRole.Member, OrgRole.Owner};
        Assert.assertEq(expected = (List.map(Ok, roles), List.map(Ok, orgRoles), List.map(Ok, roles)),
            (roles |> List.map(role -> DbErr.runWithResult(() -> AuthRows.toMember({ id = 1i64, publicId = publicId(), email = "a@example.com", name = "A", role = Role.text(role) })#role)),
             orgRoles |> List.map(role -> DbErr.runWithResult(() -> AuthRows.toOrganizationMember({ id = 1i64, publicId = publicId(), email = "a@example.com", name = "A", role = OrgRole.text(role) })#role)),
             roles |> List.map(role -> DbErr.runWithResult(() -> AuthRows.toInvitation({ id = 1i64, publicId = publicId(), email = "a@example.com", role = Role.text(role), createdAt = at(0i64) })#role))))

    /// メンバーの行の他の列（id / public_id / email / name / 時刻）もそのまま。
    @Test
    def testMemberColumns(): Unit \ Assert =
        Assert.assertEq(expected = Ok(((UserId.UserId(8i64), publicId(), "a@example.com", "A"), (UserId.UserId(8i64), publicId(), "a@example.com", "A"), (9i64, publicId(), "b@example.com", at(1725000000123i64)))),
            DbErr.runWithResult(() -> {
                let member = AuthRows.toMember({ id = 8i64, publicId = publicId(), email = "a@example.com", name = "A", role = "viewer" });
                let organizationMember = AuthRows.toOrganizationMember({ id = 8i64, publicId = publicId(), email = "a@example.com", name = "A", role = "member" });
                let invitation = AuthRows.toInvitation({ id = 9i64, publicId = publicId(), email = "b@example.com", role = "editor", createdAt = at(1725000000123i64) });
                ((member#userId, member#publicId, member#email, member#name),
                 (organizationMember#userId, organizationMember#publicId, organizationMember#email, organizationMember#name),
                 (invitation#id, invitation#publicId, invitation#email, invitation#createdAt))
            }))

    /// 知らない役割は 3 つの行とも DbErr（組織の役割をプロジェクトの行に入れても、その逆も）。
    @Test
    def testRoleRowsReject(): Unit \ Assert =
        Assert.assertEq(expected = (true, true, true),
            (DbErr.runWithResult(() -> AuthRows.toMember({ id = 1i64, publicId = publicId(), email = "", name = "", role = "member" })) |> Result.isErr,
             DbErr.runWithResult(() -> AuthRows.toOrganizationMember({ id = 1i64, publicId = publicId(), email = "", name = "", role = "editor" })) |> Result.isErr,
             DbErr.runWithResult(() -> AuthRows.toInvitation({ id = 1i64, publicId = publicId(), email = "", role = "admin", createdAt = at(0i64) })) |> Result.isErr))

    // ---- api_keys ----

    /// 発行の入力 → INSERT の引数（scope 列 + role 列）→ 読みで ApiKeyScope の全 case が戻る。
    @Test
    def testApiKeyScopeRoundTrip(): Unit \ Assert =
        let scopes = List#{ApiKeyScope.Read, ApiKeyScope.ReadDraft, ApiKeyScope.Write(Role.Writer), ApiKeyScope.Write(Role.Editor), ApiKeyScope.Write(Role.Owner)};
        Assert.assertEq(expected = List.map(Ok, scopes),
            scopes |> List.map(scope -> DbErr.runWithResult(() ->
                AuthRows.toApiKeyScope(AuthRows.toApiKeyInsert({ publicId = publicId(), projectId = 1i64, name = "ci", keyHash = "h", pepperId = "p", scope = scope, expiresAt = None })))))

    /// INSERT の引数は入力の列をそのまま持ち、write の鍵だけ role 列が Some。
    @Test
    def testApiKeyInsertColumns(): Unit \ Assert =
        let insert = AuthRows.toApiKeyInsert({ publicId = publicId(), projectId = 6i64, name = "ci", keyHash = "hash", pepperId = "v1", scope = ApiKeyScope.Write(Role.Editor), expiresAt = Some(at(1725000000123i64)) });
        let readOnly = AuthRows.toApiKeyInsert({ publicId = publicId(), projectId = 6i64, name = "ro", keyHash = "hash", pepperId = "v1", scope = ApiKeyScope.Read, expiresAt = None });
        Assert.assertEq(expected = ((publicId(), 6i64, "ci", "hash", "v1", "write", Some("editor"), Some(at(1725000000123i64))), ("read", None, None)),
            ((insert#publicId, insert#projectId, insert#name, insert#keyHash, insert#pepperId, insert#scope, insert#role, insert#expiresAt), (readOnly#scope, readOnly#role, readOnly#expiresAt)))

    /// scope 列と role 列の組が合わない（write に役割が無い、read に役割がある、write の viewer、知らない scope）は DbErr。
    @Test
    def testApiKeyScopeRejects(): Unit \ Assert =
        let table = List#{("write", None), ("read", Some("owner")), ("readDraft", Some("viewer")), ("write", Some("viewer")), ("write", Some("admin")), ("admin", None)};
        Assert.assertEq(expected = List.repeat(List.length(table), true),
            table |> List.map(match (scope, role) -> DbErr.runWithResult(() -> AuthRows.toApiKeyScope({ scope = scope, role = role })) |> Result.isErr))

    /// api_keys の行は 3 つの Option の時刻（期限・最終使用・失効）が None でも Some でもそのまま戻る。
    @Test
    def testApiKeyRoundTrip(): Unit \ Assert =
        let table = List#{(None, None, None), (Some(at(1i64)), Some(at(2i64)), Some(at(1725000000123i64)))};
        Assert.assertEq(expected = table |> List.map(match (expiresAt, lastUsedAt, revokedAt) -> Ok((10i64, publicId(), "ci", ApiKeyScope.ReadDraft, at(0i64), expiresAt, lastUsedAt, revokedAt))),
            table |> List.map(match (expiresAt, lastUsedAt, revokedAt) -> DbErr.runWithResult(() -> {
                let key = AuthRows.toApiKey({ id = 10i64, publicId = publicId(), name = "ci", scope = "readDraft", role = None, createdAt = at(0i64), expiresAt = expiresAt, lastUsedAt = lastUsedAt, revokedAt = revokedAt });
                (key#id, key#publicId, key#name, key#scope, key#createdAt, key#expiresAt, key#lastUsedAt, key#revokedAt)
            })))

    // ---- personal_access_tokens ----

    /// PAT の行は PatScope の全 case で往復し、時刻はそのまま。知らない scope は DbErr。
    @Test
    def testPersonalAccessTokenRoundTrip(): Unit \ Assert =
        let scopes = List#{PatScope.Read, PatScope.Write};
        let row = { id = 12i64, publicId = publicId(), name = "laptop", scope = "read", createdAt = at(1i64), expiresAt = at(1725000000123i64), lastUsedAt = None, revokedAt = Some(at(3i64)) };
        Assert.assertEq(expected = (scopes |> List.map(scope -> Ok((12i64, publicId(), "laptop", scope, at(1i64), at(1725000000123i64), None, Some(at(3i64))))), true),
            (scopes |> List.map(scope -> DbErr.runWithResult(() -> {
                let token = AuthRows.toPersonalAccessToken({ scope = PatScope.text(scope) | row });
                (token#id, token#publicId, token#name, token#scope, token#createdAt, token#expiresAt, token#lastUsedAt, token#revokedAt)
             })),
             DbErr.runWithResult(() -> AuthRows.toPersonalAccessToken({ scope = "readDraft" | row })) |> Result.isErr))

}
