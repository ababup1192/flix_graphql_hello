///
/// 権限の判定。役割の表と包含、組織の owner の継承、鍵と匿名。
///
mod TestAuthz {

    def user(roles: List[Role]): Actor = Actor.User(UserId.UserId(1i64), "a@example.com", roles, Login.Interactive)

    def readPatUser(roles: List[Role]): Actor = Actor.User(UserId.UserId(1i64), "a@example.com", roles, Login.PersonalToken(PatScope.Read))

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
            (Authz.can(Actor.ApiKey("site", ApiKeyScope.ReadDraft), Permission.ReadDraft, Authz.anyResource()),
             Authz.can(Actor.ApiKey("site", ApiKeyScope.ReadDraft), Permission.WriteEntries, Authz.anyResource()),
             Authz.can(Actor.ApiKey("site", ApiKeyScope.Read), Permission.ReadDraft, Authz.anyResource()),
             Authz.can(Actor.Anonymous, Permission.ReadDraft, Authz.anyResource())))

    /// write の鍵は役割の範囲で書けるが、メンバー・鍵・プロジェクトの管理は owner の鍵でもできない。
    @Test
    def testWriteApiKey(): Unit \ Assert =
        let writerKey = Actor.ApiKey("ci", ApiKeyScope.Write(Role.Writer));
        let editorKey = Actor.ApiKey("ci", ApiKeyScope.Write(Role.Editor));
        let ownerKey = Actor.ApiKey("ci", ApiKeyScope.Write(Role.Owner));
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

    /// read の PAT の人は役割が owner でも読むだけ。役割が無ければ読む事もできない。write の PAT は本人の役割のまま。
    @Test
    def testReadPatCapsToViewer(): Unit \ Assert =
        let readOnlyOwner = readPatUser(Role.Owner :: Nil);
        let writePatOwner = Actor.User(UserId.UserId(1i64), "a@example.com", Role.Owner :: Nil, Login.PersonalToken(PatScope.Write));
        Assert.assertEq(
            expected = (true, false, false, true, List#{ Role.Viewer }, Nil, List#{ Role.Owner }),
            (Authz.can(readOnlyOwner, Permission.ReadDraft, Authz.anyResource()),
             Authz.can(readOnlyOwner, Permission.WriteEntries, Authz.anyResource()),
             Authz.can(readPatUser(Nil), Permission.ReadDraft, Authz.anyResource()),
             Authz.can(writePatOwner, Permission.ManageMembers, Authz.anyResource()),
             Authz.effectiveRoles(Login.PersonalToken(PatScope.Read), Role.Editor :: Role.Owner :: Nil),
             Authz.capToViewer(Nil),
             Authz.effectiveRoles(Login.PersonalToken(PatScope.Write), Role.Owner :: Nil)))

    def allPermissions(): List[Permission] =
        List#{ Permission.ReadDraft, Permission.WriteEntries, Permission.PublishEntries, Permission.ManageTypes,
               Permission.ManageAssets, Permission.ManageMembers, Permission.ManageApiKeys, Permission.ManageProject }

    /// 主体がこの対象に対してできる操作の名前（allPermissions の順）。
    def granted(actor: Actor, resource: Authz.Resource): List[String] =
        allPermissions() |> List.filter(permission -> Authz.can(actor, permission, resource)) |> List.map(Permission.text)

    def patUser(scope: PatScope, roles: List[Role]): Actor = Actor.User(UserId.UserId(1i64), "a@example.com", roles, Login.PersonalToken(scope))

    /// 主体 × 権限の表。System は全部、Anonymous と read の鍵は何も、readDraft の鍵は下書きを読むだけ、
    /// write の鍵は役割の範囲で管理以外、プレビューはその entry の readDraft だけ、write の PAT は本人の役割、read の PAT は viewer。
    @Test
    def testActorPermissionTable(): Unit \ Assert =
        let any = Authz.anyResource();
        let e1 = CmsTestKit.entryId("e1");
        let editorPermissions = List#{ "readDraft", "writeEntries", "publishEntries", "manageTypes", "manageAssets" };
        let rows = List#{
            ("system",                  Actor.System,                                           any,                        allPermissions() |> List.map(Permission.text)),
            ("anonymous",               Actor.Anonymous,                                        any,                        Nil),
            ("apiKey read",             Actor.ApiKey("site", ApiKeyScope.Read),                 any,                        Nil),
            ("apiKey readDraft",        Actor.ApiKey("site", ApiKeyScope.ReadDraft),            any,                        List#{ "readDraft" }),
            ("apiKey write viewer",     Actor.ApiKey("ci", ApiKeyScope.Write(Role.Viewer)),     any,                        List#{ "readDraft" }),
            ("apiKey write owner",      Actor.ApiKey("ci", ApiKeyScope.Write(Role.Owner)),      any,                        editorPermissions),
            ("preview own entry",       Actor.Preview(e1),                                      Authz.entryResource(e1),    List#{ "readDraft" }),
            ("preview other entry",     Actor.Preview(e1),                                      Authz.entryResource(CmsTestKit.entryId("e2")), Nil),
            ("preview without entry",   Actor.Preview(e1),                                      any,                        Nil),
            ("pat write viewer",        patUser(PatScope.Write, Role.Viewer :: Nil),            any,                        List#{ "readDraft" }),
            ("pat write writer",        patUser(PatScope.Write, Role.Writer :: Nil),            any,                        List#{ "readDraft", "writeEntries" }),
            ("pat write editor",        patUser(PatScope.Write, Role.Editor :: Nil),            any,                        editorPermissions),
            ("pat read owner",          patUser(PatScope.Read, Role.Owner :: Nil),              any,                        List#{ "readDraft" }),
            ("pat read without roles",  patUser(PatScope.Read, Nil),                            any,                        Nil)
        };
        Assert.assertEq(
            expected = rows |> List.map(match (label, _, _, permissions) -> (label, permissions)),
            rows |> List.map(match (label, actor, resource, _) -> (label, granted(actor, resource))))

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
