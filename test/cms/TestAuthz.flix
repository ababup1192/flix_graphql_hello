///
/// 権限の判定。役割の表と包含、組織の owner の継承、鍵と匿名。
///
mod TestAuthz {

    def user(roles: List[Role]): Actor = Actor.User(UserId.UserId(1i64), "a@example.com", roles)

    /// 役割 × 権限の表。包含（owner ⊃ editor ⊃ writer ⊃ viewer）が効く。
    @Test
    def testRolesGrantPermissions(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                List#{ "readDraft" },
                List#{ "readDraft", "writeEntries" },
                List#{ "manageAssets", "manageTypes", "publishEntries", "readDraft", "writeEntries" },
                List#{ "manageApiKeys", "manageAssets", "manageMembers", "manageProject", "manageTypes", "publishEntries", "readDraft", "writeEntries" }
            },
            List#{ Role.Viewer, Role.Writer, Role.Editor, Role.Owner } |> List.map(role -> Authz.permissionsOf(role :: Nil)))

    /// viewer は書けず、editor はメンバーを触れず、役割が無ければ何もできない。
    @Test
    def testCan(): Unit \ Assert =
        Assert.assertEq(
            expected = (false, true, false, true, false),
            (Authz.can(user(Role.Viewer :: Nil), Permission.WriteEntries, Authz.anyResource()),
             Authz.can(user(Role.Writer :: Nil), Permission.WriteEntries, Authz.anyResource()),
             Authz.can(user(Role.Editor :: Nil), Permission.ManageMembers, Authz.anyResource()),
             Authz.can(user(Role.Owner :: Nil), Permission.ManageMembers, Authz.anyResource()),
             Authz.can(user(Nil), Permission.ReadDraft, Authz.anyResource())))

    /// 鍵は readDraft の物だけ下書きを読め、read の鍵と匿名は管理の操作を何もできない。
    @Test
    def testApiKeyAndAnonymous(): Unit \ Assert =
        Assert.assertEq(
            expected = (true, false, false, false),
            (Authz.can(Actor.ApiKey(ApiKeyScope.ReadDraft), Permission.ReadDraft, Authz.anyResource()),
             Authz.can(Actor.ApiKey(ApiKeyScope.ReadDraft), Permission.WriteEntries, Authz.anyResource()),
             Authz.can(Actor.ApiKey(ApiKeyScope.Read), Permission.ReadDraft, Authz.anyResource()),
             Authz.can(Actor.Anonymous, Permission.ReadDraft, Authz.anyResource())))

    /// 組織の owner はプロジェクトの membership が無くても owner。member は何も足さない。
    @Test
    def testOrgOwnerInherits(): Unit \ Assert =
        Assert.assertEq(
            expected = (List#{ Role.Owner }, List#{ Role.Viewer }, List#{ Role.Viewer, Role.Owner }),
            (Authz.rolesOf(None, Some(OrgRole.Owner)),
             Authz.rolesOf(Some(Role.Viewer), Some(OrgRole.Member)),
             Authz.rolesOf(Some(Role.Viewer), Some(OrgRole.Owner))))

}
