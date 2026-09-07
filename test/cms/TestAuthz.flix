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

    /// write の鍵は役割の範囲で書けるが、メンバー・鍵・プロジェクトの管理は owner の鍵でもできない。
    @Test
    def testWriteApiKey(): Unit \ Assert =
        let writerKey = Actor.ApiKey(ApiKeyScope.Write(Role.Writer));
        let editorKey = Actor.ApiKey(ApiKeyScope.Write(Role.Editor));
        let ownerKey = Actor.ApiKey(ApiKeyScope.Write(Role.Owner));
        Assert.assertEq(
            expected = (true, false, true, true, false, false, false, true),
            (Authz.can(writerKey, Permission.WriteEntries, Authz.anyResource()),
             Authz.can(writerKey, Permission.PublishEntries, Authz.anyResource()),
             Authz.can(editorKey, Permission.PublishEntries, Authz.anyResource()),
             Authz.can(editorKey, Permission.ManageTypes, Authz.anyResource()),
             Authz.can(ownerKey, Permission.ManageApiKeys, Authz.anyResource()),
             Authz.can(ownerKey, Permission.ManageMembers, Authz.anyResource()),
             Authz.can(ownerKey, Permission.ManageProject, Authz.anyResource()),
             Authz.can(ownerKey, Permission.ManageAssets, Authz.anyResource())))

    /// read の PAT の人は役割が owner でも読むだけ。役割が無ければ読む事もできない。
    @Test
    def testReadOnlyUser(): Unit \ Assert =
        let readOnlyOwner = Actor.ReadOnlyUser(UserId.UserId(1i64), "a@example.com", Role.Owner :: Nil);
        Assert.assertEq(
            expected = (true, false, false, List#{ Role.Viewer }, Nil),
            (Authz.can(readOnlyOwner, Permission.ReadDraft, Authz.anyResource()),
             Authz.can(readOnlyOwner, Permission.WriteEntries, Authz.anyResource()),
             Authz.can(Actor.ReadOnlyUser(UserId.UserId(1i64), "a@example.com", Nil), Permission.ReadDraft, Authz.anyResource()),
             Authz.capToViewer(Role.Editor :: Role.Owner :: Nil),
             Authz.capToViewer(Nil)))

    /// 役割の並びの一番高い物。空なら None。
    @Test
    def testHighestRole(): Unit \ Assert =
        Assert.assertEq(
            expected = (Some(Role.Editor), None),
            (Authz.highestRole(Role.Viewer :: Role.Editor :: Role.Writer :: Nil), Authz.highestRole(Nil)))

    /// 組織の owner はプロジェクトの membership が無くても owner。member は何も足さない。
    @Test
    def testOrgOwnerInherits(): Unit \ Assert =
        Assert.assertEq(
            expected = (List#{ Role.Owner }, List#{ Role.Viewer }, List#{ Role.Viewer, Role.Owner }),
            (Authz.rolesOf(None, Some(OrgRole.Owner)),
             Authz.rolesOf(Some(Role.Viewer), Some(OrgRole.Member)),
             Authz.rolesOf(Some(Role.Viewer), Some(OrgRole.Owner))))

}
