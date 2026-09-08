///
/// 認証・組織・権限を実 PostgreSQL で見る。bootstrap の owner、招待と初回ログイン、役割ごとの拒否、API キー、公開範囲。
///
mod TestAuthPg {

    use Util.Json.Json

    /// テスト用の bootstrap（owner@test が最初の owner）。
    def bootstrap(): Accounts.Bootstrap = { ownerEmail = Some("owner@test") }

    def principal(subject: String, email: String): Principal = { issuer = "test", subject = subject, email = email, name = subject }

    ///
    /// bootstrap の email の初回ログインは既定の組織の owner になり、既定のプロジェクトの owner として振る舞える。
    /// 2 人目は何も持たない（組織にも属さない）。
    ///
    @Test
    def testPgBootstrapOwner(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let owner = PgTestSupport.ownerUser();
            let stranger = Accounts.resolveUser(bootstrap(), principal("u-2", "someone@test"));
            let again = PgTestSupport.ownerUser();
            (Accounts.actorFor(owner, ProjectId.default(), Login.Interactive) == Actor.User(owner#id, "owner@test", Role.Owner :: Nil, Login.Interactive),
             Accounts.actorFor(stranger, ProjectId.default(), Login.Interactive) == Actor.User(stranger#id, "someone@test", Nil, Login.Interactive),
             again#id == owner#id,
             PgTestSupport.runAs(owner, Accounts.me) |> Option.map(me -> me#projects) |> Option.getWithDefault(Nil)
                 |> List.map(membership -> (ProjectSlug.text(membership#target#slug), membership#role)))
        });
        Assert.assertEq(expected = Ok(Ok((true, true, true, List#{ ("default", Role.Owner) }))), result)

    ///
    /// 招待 → 初回ログインで membership に写る。viewer は型を作れず、writer は公開できず、editor は公開できる。
    /// プロジェクトの owner が 1 人（second。bootstrap の owner は組織の owner なので数えない）なら外せない。
    ///
    @Test
    def testPgInvitationsAndRoles(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"e1"}, () -> {
            PgTestSupport.asOwner(() -> {
                discard Members.invite(Session.grant(), "Viewer@Test.dev", Role.Viewer);
                discard Members.invite(Session.grant(), "writer@test.dev", Role.Writer);
                discard Members.invite(Session.grant(), "editor@test.dev", Role.Editor);
                discard Members.invite(Session.grant(), "second@test.dev", Role.Owner)
            });
            let second = Accounts.resolveUser(bootstrap(), principal("u-s", "second@test.dev"));
            let viewer = Accounts.resolveUser(bootstrap(), principal("u-v", "viewer@test.dev"));
            let writer = Accounts.resolveUser(bootstrap(), principal("u-w", "writer@test.dev"));
            let editor = Accounts.resolveUser(bootstrap(), principal("u-e", "editor@test.dev"));
            let blogs = PgTestSupport.asOwner(() -> ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事")));
            discard PgTestSupport.asOwner(() -> ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty())));
            let viewerCreatesType = PgTestSupport.runAs(viewer, () -> CmsTestKit.failureMessage(() -> ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("x", "x"))));
            let viewerReads = PgTestSupport.runAs(viewer, () -> List.length(ContentTypes.list(Session.grant())));
            let entry = PgTestSupport.runAs(writer, () -> ContentEntries.create(Session.grant(), blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("hi"))})));
            let writerPublishes = PgTestSupport.runAs(writer, () -> CmsTestKit.failureMessage(() -> ContentEntries.publish(Session.grant(), entry#id, "writer", false)));
            let editorPublishes = PgTestSupport.runAs(editor, () -> ContentEntries.publish(Session.grant(), entry#id, "editor", false))#stage;
            let invitationsLeft = PgTestSupport.asOwner(() -> List.length(Members.invitations(Session.grant())));
            let members = PgTestSupport.asOwner(() -> Members.list(Session.grant()) |> List.map(member -> (member#email, member#role)) |> List.sort);
            let lastOwner = PgTestSupport.asOwner(() -> CmsTestKit.failureMessage(() -> Members.remove(Session.grant(), second#id)));
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
    /// API キー。発行した鍵はこのプロジェクトでだけ解決でき（他のプロジェクトでは Unknown）、失効すれば Revoked、他の鍵の文字列は Unknown。
    ///
    @Test
    def testPgApiKeys(): Unit \ {IO, Assert} =
        let pepper = PgTestSupport.pepper();
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"k1", "k2"}, () -> {
            let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
            let issued = PgTestSupport.asOwner(() -> ApiKeys.create(Session.grant(), Session.grantInteractive(), pepper, readKey("site"), 0i64));
            let scopeOf = found -> found |> Result.map(key -> key#scope);
            let resolved = ApiKeys.resolve(pepper, issued#key, ProjectId.default(), 0i64) |> scopeOf;
            let otherProject = ApiKeys.resolve(pepper, issued#key, shop, 0i64) |> scopeOf;
            let wrongKey = ApiKeys.resolve(pepper, "cms_nope", ProjectId.default(), 0i64) |> scopeOf;
            PgTestSupport.asOwner(() -> ApiKeys.revoke(Session.grant(), issued#publicId));
            let afterRevoke = ApiKeys.resolve(pepper, issued#key, ProjectId.default(), 0i64) |> scopeOf;
            let listed = PgTestSupport.asOwner(() -> ApiKeys.list(Session.grant()) |> List.map(key -> (key#name, Option.nonEmpty(key#revokedAt))));
            (String.startsWith(prefix = "cms_", issued#key), resolved, otherProject, wrongKey, afterRevoke, listed)
        }));
        Assert.assertEq(
            expected = Ok(Ok((true, Ok(ApiKeyScope.Read), Err(ApiKeyRejection.Unknown), Err(ApiKeyRejection.Unknown), Err(ApiKeyRejection.Revoked), List#{ ("site", true) }))),
            result)

    /// 期限無しの read の鍵の入力。
    def readKey(name: String): ApiKeyDraft = { name = name, scope = ApiKeyScope.Read, expiresAt = None }

    ///
    /// 管理 API を通した形。owner の me に役割と組織とプロジェクトが出て、身元が無ければ me は null で mutation は権限エラー。
    ///
    @Test
    def testPgAuthViaAdminApi(): Unit \ {IO, Assert} =
        let (me, anonymousMe, anonymousMutation, invited) = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            let anonymous = queryText -> GraphqlTestKit.askWith(api#schema, Context.anonymous(), queryText);
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
    /// コンテンツ API。public なら誰でも公開中を読めるが下書きは readDraft が要り、private にすると鍵か役割が無い読みは止まる
    /// （匿名は UNAUTHENTICATED の文言、メンバーでない人は FORBIDDEN の文言。どちらも認証で断られるのでリゾルバは走らない）。
    ///
    @Test
    def testPgContentApiVisibility(): Unit \ {IO, Assert} =
        let pepper = PgTestSupport.pepper();
        let seed = () -> CmsTestKit.withIds(List#{"e1", "k1"}, () -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let entry = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("e1")), CmsTestKit.entryData(List#{("title", Json.JString("hi"))}));
            discard ContentEntries.publish(Session.grant(), entry#id, "tester", false);
            PgTestSupport.asOwner(() -> ApiKeys.create(Session.grant(), Session.grantInteractive(), pepper, readKey("site"), 0i64))#key
        });
        let (publicRead, anonymousDraft, ownerDraft, privateAnonymous, privateStranger, privateWithKey) = PgTestSupport.withContentApiAndPool(seed, (pool, askOwner) -> {
            let engine = PgTestSupport.contentEngine(pool);
            let anonymous = PgTestSupport.askEngineAs(pool, Engine.Content, engine, Credential.Missing);
            let stranger = PgTestSupport.askEngineAs(pool, Engine.Content, engine, PgTestSupport.bearer("stranger", "stranger@example.com"));
            let publicRead = anonymous("{ blogs { totalCount } }");
            let anonymousDraft = anonymous("{ blogs(stage: DRAFT) { totalCount } }") |> snd;
            let ownerDraft = askOwner("{ blogs(stage: DRAFT) { totalCount } }");
            discard PgTestSupport.mutate(pool, () -> AuthQueries.updateProjectVisibility({ projectId = ProjectId.toInt64(ProjectId.default()), visibility = "private" }));
            let privateAnonymous = anonymous("{ blogs { totalCount } }") |> snd;
            let privateStranger = stranger("{ blogs { totalCount } }") |> snd;
            let key = PgTestSupport.mutateOrBug(pool, () -> CmsTestKit.withIds(List#{"k9"}, () ->
                PgTestSupport.asOwner(() -> ApiKeys.create(Session.grant(), Session.grantInteractive(), pepper, readKey("site2"), 0i64))#key));
            let privateWithKey = PgTestSupport.askEngineAs(pool, Engine.Content, engine, Credential.ApiKey(key))("{ blogs { totalCount } }");
            (publicRead, anonymousDraft, ownerDraft, privateAnonymous, privateStranger, privateWithKey)
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }), None),
                Some("この操作（readDraft）の権限がありません"),
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }), None),
                Some("このプロジェクトは非公開です。API キーを X-Api-Key で渡してください"),
                Some("このプロジェクトのメンバーではありません"),
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }), None)),
            (publicRead, anonymousDraft, ownerDraft, privateAnonymous, privateStranger, privateWithKey))

    ///
    /// コンテンツ API に壊れたログインの JWT（Credential.Invalid）を付けても匿名と同じ:
    ///   public  → 公開中が読める（断らない）
    ///   private → 匿名として UNAUTHENTICATED の文言
    /// 何も付けない匿名と表で並べて、同じ結果になる事を見る。
    ///
    @Test
    def testPgContentApiTreatsBrokenJwtAsAnonymous(): Unit \ {IO, Assert} =
        let seed = () -> CmsTestKit.withIds(List#{"e1"}, () -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let entry = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("e1")), CmsTestKit.entryData(List#{("title", Json.JString("hi"))}));
            ContentEntries.publish(Session.grant(), entry#id, "tester", false)
        });
        let published = (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }), None);
        let unauthenticated = (Value.Null, Some("このプロジェクトは非公開です。API キーを X-Api-Key で渡してください"));
        let table = List#{
            ("public",  Credential.Invalid("JWT は無し"), published),
            ("public",  Credential.Missing,               published),
            ("private", Credential.Invalid("JWT は無し"), unauthenticated),
            ("private", Credential.Missing,               unauthenticated)
        };
        let results = PgTestSupport.withContentApiAndPool(seed, (pool, _) -> {
            let engine = PgTestSupport.contentEngine(pool);
            table |> List.map(match (visibility, credential, _) -> {
                discard PgTestSupport.mutate(pool, () -> AuthQueries.updateProjectVisibility({ projectId = ProjectId.toInt64(ProjectId.default()), visibility = visibility }));
                PgTestSupport.askEngineAs(pool, Engine.Content, engine, credential)("{ blogs { totalCount } }")
            })
        });
        Assert.assertEq(expected = table |> List.map(match (_, _, expected) -> expected), results)

}
