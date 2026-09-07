///
/// 認証・組織・権限を実 PostgreSQL で見る。bootstrap の owner、招待と初回ログイン、役割ごとの拒否、API キー、公開範囲。
///
mod TestAuthPg {

    use Util.Json.Json

    /// テスト用の bootstrap（owner@test が最初の owner）。
    def bootstrap(): Accounts.Bootstrap = { ownerEmail = Some("owner@test") }

    def principal(subject: String, email: String): Principal = { issuer = "test", subject = subject, email = email, name = subject }

    /// その人として今のプロジェクトで走らせる。
    def runAs(user: User, f: Unit -> a \ ef): a \ (ef - Session) + DbRead + Tenant =
        Session.runWith(Accounts.actorFor(user, Tenant.current()), f)

    ///
    /// bootstrap の email の初回ログインは既定の組織の owner になり、既定のプロジェクトの owner として振る舞える。
    /// 2 人目は何も持たない（組織にも属さない）。
    ///
    @Test
    def testPgBootstrapOwner(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let owner = Accounts.resolveUser(bootstrap(), principal("owner", "owner@test"));
            let stranger = Accounts.resolveUser(bootstrap(), principal("u-2", "someone@test"));
            let again = Accounts.resolveUser(bootstrap(), principal("owner", "owner@test"));
            (Accounts.actorFor(owner, ProjectId.default()) == Actor.User(owner#id, "owner@test", Role.Owner :: Nil),
             Accounts.actorFor(stranger, ProjectId.default()) == Actor.User(stranger#id, "someone@test", Nil),
             again#id == owner#id,
             Accounts.projectsOf(owner#id) |> List.map(membership -> (ProjectSlug.text(membership#target#slug), membership#role)))
        });
        Assert.assertEq(expected = Ok(Ok((true, true, true, List#{ ("default", Role.Owner) }))), result)

    ///
    /// 招待 → 初回ログインで membership に写る。viewer は型を作れず、writer は公開できず、editor は公開できる。
    /// プロジェクトの owner が 1 人（second。bootstrap の owner は組織の owner なので数えない）なら外せない。
    ///
    @Test
    def testPgInvitationsAndRoles(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"e1"}, () -> {
            let owner = Accounts.resolveUser(bootstrap(), principal("owner", "owner@test"));
            runAs(owner, () -> {
                discard Members.invite("Viewer@Test.dev", Role.Viewer);
                discard Members.invite("writer@test.dev", Role.Writer);
                discard Members.invite("editor@test.dev", Role.Editor);
                discard Members.invite("second@test.dev", Role.Owner)
            });
            let second = Accounts.resolveUser(bootstrap(), principal("u-s", "second@test.dev"));
            let viewer = Accounts.resolveUser(bootstrap(), principal("u-v", "viewer@test.dev"));
            let writer = Accounts.resolveUser(bootstrap(), principal("u-w", "writer@test.dev"));
            let editor = Accounts.resolveUser(bootstrap(), principal("u-e", "editor@test.dev"));
            let blogs = runAs(owner, () -> ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事")));
            discard runAs(owner, () -> ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty())));
            let viewerCreatesType = runAs(viewer, () -> CmsTestKit.failureMessage(() -> ContentTypes.create(CmsTestKit.typeDraft("x", "x"))));
            let viewerReads = runAs(viewer, () -> List.length(ContentTypes.list()));
            let entry = runAs(writer, () -> ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("hi"))})));
            let writerPublishes = runAs(writer, () -> CmsTestKit.failureMessage(() -> ContentEntries.publish(entry#id, "writer", false)));
            let editorPublishes = runAs(editor, () -> ContentEntries.publish(entry#id, "editor", false))#stage;
            let invitationsLeft = runAs(owner, () -> List.length(Members.invitations()));
            let members = runAs(owner, () -> Members.list() |> List.map(member -> (member#email, member#role)) |> List.sort);
            let lastOwner = runAs(owner, () -> CmsTestKit.failureMessage(() -> Members.remove(second#id)));
            (viewerCreatesType, viewerReads, writerPublishes, editorPublishes, invitationsLeft, members, lastOwner)
        }));
        Assert.assertEq(
            expected = Ok(Ok((
                Err("この操作（manageTypes）の権限がありません"),
                1,
                Err("この操作（publishEntries）の権限がありません"),
                Stage.Published,
                0,
                List#{ ("editor@test.dev", Role.Editor), ("second@test.dev", Role.Owner), ("viewer@test.dev", Role.Viewer), ("writer@test.dev", Role.Writer) },
                Err("role: 最後の owner は外せません。先に別の owner を付けてください")))),
            result)

    ///
    /// API キー。発行した鍵はこのプロジェクトでだけ解決でき、失効すれば解決できず、他の鍵の文字列は解決できない。
    ///
    @Test
    def testPgApiKeys(): Unit \ {IO, Assert} =
        let pepper = { pepperId = "test", secret = "test-pepper" };
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"k1", "k2"}, () -> {
            let owner = Accounts.resolveUser(bootstrap(), principal("owner", "owner@test"));
            let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
            let issued = runAs(owner, () -> ApiKeys.create(pepper, readKey("site")));
            let scopeOf = found -> found |> Option.map(key -> key#scope);
            let resolved = ApiKeys.resolve(pepper, issued#key, ProjectId.default(), 0i64) |> scopeOf;
            let otherProject = ApiKeys.resolve(pepper, issued#key, shop, 0i64) |> scopeOf;
            let wrongKey = ApiKeys.resolve(pepper, "cms_nope", ProjectId.default(), 0i64) |> scopeOf;
            runAs(owner, () -> ApiKeys.revoke(issued#publicId));
            let afterRevoke = ApiKeys.resolve(pepper, issued#key, ProjectId.default(), 0i64) |> scopeOf;
            let listed = runAs(owner, () -> ApiKeys.list() |> List.map(key -> (key#name, Option.nonEmpty(key#revokedAt))));
            (String.startsWith(prefix = "cms_", issued#key), resolved, otherProject, wrongKey, afterRevoke, listed)
        }));
        Assert.assertEq(
            expected = Ok(Ok((true, Some(ApiKeyScope.Read), None, None, None, List#{ ("site", true) }))),
            result)

    /// 期限無しの read の鍵の入力。
    def readKey(name: String): ApiKeyDraft = { name = name, scope = ApiKeyScope.Read, expiresAt = None }

    ///
    /// 管理 API を通した形。owner の me に役割と組織とプロジェクトが出て、身元が無ければ me は null で mutation は権限エラー。
    ///
    @Test
    def testPgAuthViaAdminApi(): Unit \ {IO, Assert} =
        let (me, anonymousMe, anonymousMutation, invited) = PgTestSupport.withAdminApi(() -> (), (schema, _) -> {
            let ask = PgTestSupport.askOwner(schema);
            let anonymous = queryText -> GraphqlTestKit.askWith(schema, Context.anonymous(), queryText);
            (ask("{ me { email roles permissions organizations { organization { name } role } projects { project { slug } role } } }"),
             anonymous("{ me { email } }"),
             anonymous("mutation { createContentType(input: { apiId: \"blogs\", name: \"x\" }) { id } }") |> snd,
             ask("mutation { inviteMember(email: \"a@example.com\", role: EDITOR) { email role } }"))
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "me" => Value.Obj(Map#{
                    "email" => Value.Str("owner@test"),
                    "roles" => Value.List(Value.Str("OWNER") :: Nil),
                    "permissions" => Value.List(List#{ "manageApiKeys", "manageAssets", "manageMembers", "manageProject", "manageTypes", "publishEntries", "readDraft", "writeEntries" } |> List.map(Value.Str)),
                    "organizations" => Value.List(Value.Obj(Map#{ "organization" => Value.Obj(Map#{ "name" => Value.Str("default") }), "role" => Value.Str("OWNER") }) :: Nil),
                    "projects" => Value.List(Value.Obj(Map#{ "project" => Value.Obj(Map#{ "slug" => Value.Str("default") }), "role" => Value.Str("OWNER") }) :: Nil)
                }) }), None),
                (Value.Obj(Map#{ "me" => Value.Null }), None),
                Some("この操作（manageTypes）の権限がありません"),
                (Value.Obj(Map#{ "inviteMember" => Value.Obj(Map#{ "email" => Value.Str("a@example.com"), "role" => Value.Str("EDITOR") }) }), None)),
            (me, anonymousMe, anonymousMutation, invited))

    ///
    /// コンテンツ API。public なら誰でも公開中を読めるが下書きは readDraft が要り、private にすると鍵か役割が無い読みは止まる。
    ///
    @Test
    def testPgContentApiVisibility(): Unit \ {IO, Assert} =
        let pepper = { pepperId = "test", secret = "test-pepper" };
        let seed = () -> CmsTestKit.withIds(List#{"e1", "k1"}, () -> {
            let owner = Accounts.resolveUser(bootstrap(), principal("owner", "owner@test"));
            let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let entry = ContentEntries.create(blogs#id, Some(CmsTestKit.entryId("e1")), CmsTestKit.entryData(List#{("title", Json.JString("hi"))}));
            discard ContentEntries.publish(entry#id, "tester", false);
            runAs(owner, () -> ApiKeys.create(pepper, readKey("site")))#key
        });
        let (publicRead, anonymousDraft, ownerDraft, privateAnonymous, privateWithKey) = PgTestSupport.withContentApiAndPool(seed, (pool, askOwner) -> {
            let cache = ContentEngine.create(PgTestSupport.deps());
            let engine = match ContentEngine.current(cache, pool, ProjectId.default()) { case Ok(found) => found case Err(message) => bug!(message) };
            let anonymous = queryText -> GraphqlTestKit.askEngineWith(engine, Context.anonymous(), queryText);
            let publicRead = anonymous("{ blogs { totalCount } }");
            let anonymousDraft = anonymous("{ blogs(stage: DRAFT) { totalCount } }") |> snd;
            let ownerDraft = askOwner("{ blogs(stage: DRAFT) { totalCount } }");
            discard PgTestSupport.mutate(pool, () -> AuthQueries.updateProjectVisibility({ projectId = ProjectId.toInt64(ProjectId.default()), visibility = "private" }));
            let privateAnonymous = anonymous("{ blogs { totalCount } }") |> snd;
            let key = match PgTestSupport.mutate(pool, () -> CmsTestKit.withIds(List#{"k9"}, () -> {
                let owner = Accounts.resolveUser(bootstrap(), principal("owner", "owner@test"));
                runAs(owner, () -> ApiKeys.create(pepper, readKey("site2")))#key
            })) { case Ok(Ok(found)) => found case other => bug!("${other}") };
            let privateWithKey = GraphqlTestKit.askEngineWith(engine, Context.withCredential(Credential.ApiKey(key)), "{ blogs { totalCount } }");
            (publicRead, anonymousDraft, ownerDraft, privateAnonymous, privateWithKey)
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }), None),
                Some("この操作（readDraft）の権限がありません"),
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }), None),
                Some("auth: このプロジェクトは非公開です。API キーを X-Api-Key で渡してください"),
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }), None)),
            (publicRead, anonymousDraft, ownerDraft, privateAnonymous, privateWithKey))

}
