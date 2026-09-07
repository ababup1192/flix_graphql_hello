///
/// write の API キーを実 PostgreSQL で見る。管理 API を鍵で叩き、役割の範囲で書け、管理（鍵・メンバー・プロジェクト）はできず、
/// 失効・他プロジェクトの鍵は匿名扱いになり、管理 API で使った鍵に lastUsedAt が付く（コンテンツ API では付かない）。
///
mod TestApiKeyWritePg {

    use Util.Json.Json

    def pepper(): SecretHash.Pepper = { pepperId = "test", secret = "test-pepper" }

    /// blogs 型（title）を作り、shop プロジェクトも作る。戻り値は (blogs の型 id, shop)。
    def seed(): (TypeId, ProjectId) \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        (blogs#id, Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店"))

    /// 管理 API をこの身元で叩く ask。
    def asCredential(schema: Schema, credential: Credential): String -> (Value, Option[String]) \ IO =
        queryText -> GraphqlTestKit.askWith(schema, Context.withCredential(credential), queryText)

    /// bootstrap の owner（ログインの JWT）として今のプロジェクトで走らせる。
    def asOwner(thunk: Unit -> a \ ef): a \ (ef - Session) + Db + IdGen + Tenant =
        let owner = Accounts.resolveUser({ ownerEmail = Some("owner@test") }, { issuer = "test", subject = "owner", email = "owner@test", name = "owner" });
        Session.runWith(Accounts.actorFor(owner, Tenant.current(), Login.Interactive), thunk)

    /// apiKeys の一覧を (name, scope, role, lastUsedAt が付いたか) にして name で並べる。
    def keysUsed(response: (Value, Option[String])): List[(String, Value, Value, Bool)] =
        GraphqlTestKit.listAt(List#{"apiKeys"}, response)
            |> List.map(item -> (nameOf(item), Value.field("scope", item), Value.field("role", item), Value.field("lastUsedAt", item) != Value.Null))
            |> List.sortBy(fst4)

    def fst4(item: (a, b, c, d)): a = { let (first, _, _, _) = item; first }

    /// 一覧の 1 件の name。無ければ空。
    def nameOf(item: Value): String = Value.field("name", item) |> Value.asStr |> Option.getWithDefault("")

    ///
    /// 発行と使い方。owner が WRITE / WRITER と WRITE / EDITOR の鍵を作り、
    ///   writer の鍵: createEntry は通り、publishEntry / createApiKey / inviteMember / updateProjectVisibility は forbidden
    ///   editor の鍵: publishEntry が通り、版の author は "api-key:deploy"
    ///   READ に role を付ける・WRITE に role を付けない・WRITE に VIEWER: invalid
    /// 使った鍵には lastUsedAt が付き、使っていない鍵には付かない。
    ///
    @Test
    def testPgWriteApiKeyByRole(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1"}, seed), (schema, seeded) -> {
            let (blogs, _) = seeded;
            let owner = PgTestSupport.askOwner(schema);
            let writerKey = GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, owner("mutation { createApiKey(name: \"ci\", scope: WRITE, role: WRITER) { key role scope } }"));
            let editorIssued = owner("mutation { createApiKey(name: \"deploy\", scope: WRITE, role: EDITOR) { id key role expiresAt } }");
            let editorKey = GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, editorIssued);
            let unusedKey = owner("mutation { createApiKey(name: \"spare\", scope: READ) { id } }") |> snd;
            let readWithRole = owner("mutation { createApiKey(name: \"x\", scope: READ, role: WRITER) { id } }") |> snd;
            let writeWithoutRole = owner("mutation { createApiKey(name: \"y\", scope: WRITE) { id } }") |> snd;
            let writeViewer = owner("mutation { createApiKey(name: \"v\", scope: WRITE, role: VIEWER) { id } }") |> snd;
            let writer = asCredential(schema, Credential.ApiKey(writerKey));
            let editor = asCredential(schema, Credential.ApiKey(editorKey));
            let created = writer("mutation { createEntry(typeId: \"${TypeId.toInt64(blogs)}\", fields: { title: \"hi\" }) { id stage } }");
            let entryId = GraphqlTestKit.stringAt(List#{"createEntry", "id"}, created);
            let writerPublishes = writer("mutation { publishEntry(id: \"${entryId}\") { id } }") |> snd;
            let writerCreatesKey = writer("mutation { createApiKey(name: \"z\", scope: READ) { id } }") |> snd;
            let writerInvites = writer("mutation { inviteMember(email: \"x@example.com\", role: VIEWER) { id } }") |> snd;
            let writerChangesVisibility = writer("mutation { updateProjectVisibility(visibility: PRIVATE) { id } }") |> snd;
            let editorPublishes = editor("mutation { publishEntry(id: \"${entryId}\") { stage } }");
            let authors = owner("{ entry(id: \"${entryId}\") { versions { author } } }") |> GraphqlTestKit.valueAt(List#{"entry", "versions"});
            (GraphqlTestKit.valueAt(List#{"createEntry", "stage"}, created),
             GraphqlTestKit.valueAt(List#{"createApiKey", "role"}, editorIssued), GraphqlTestKit.valueAt(List#{"createApiKey", "expiresAt"}, editorIssued),
             unusedKey, readWithRole, writeWithoutRole, writeViewer,
             writerPublishes, writerCreatesKey, writerInvites, writerChangesVisibility,
             editorPublishes, authors,
             owner("{ apiKeys { name scope role lastUsedAt } }") |> keysUsed)
        });
        Assert.assertEq(
            expected = (
                Value.Str("DRAFT"),
                Value.Str("EDITOR"), Value.Null,
                None,
                Some("role: role は scope が WRITE の鍵にだけ渡せます"),
                Some("role: scope が WRITE の鍵には role が要ります（WRITER / EDITOR / OWNER）"),
                Some("role: WRITE の鍵の役割は WRITER / EDITOR / OWNER です"),
                Some("この操作（publishEntries）の権限がありません"),
                Some("この操作（manageApiKeys）の権限がありません"),
                Some("この操作（manageMembers）の権限がありません"),
                Some("この操作（manageProject）の権限がありません"),
                (Value.Obj(Map#{ "publishEntry" => Value.Obj(Map#{ "stage" => Value.Str("PUBLISHED") }) }), None),
                Value.List(Value.Obj(Map#{ "author" => Value.Str("api-key:deploy") }) :: Nil),
                List#{ ("ci", Value.Str("WRITE"), Value.Str("WRITER"), true),
                       ("deploy", Value.Str("WRITE"), Value.Str("EDITOR"), true),
                       ("spare", Value.Str("READ"), Value.Null, false) }),
            outcome)

    ///
    /// 効かない鍵。過去の期限は発行できず（invalid）、失効した鍵と他プロジェクト（shop）の鍵と知らない鍵は匿名扱いで、createEntry は forbidden（writeEntries）。
    ///
    @Test
    def testPgDeadApiKeysAreAnonymous(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            let (blogs, shop) = PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"e1"}, seed));
            let deps = PgTestSupport.deps();
            let schema = AdminSchema.make(deps, AdminRunner.make(pool, deps, ProjectId.default()));
            let shopSchema = AdminSchema.make(deps, AdminRunner.make(pool, deps, shop));
            let owner = PgTestSupport.askOwner(schema);
            let shopOwner = PgTestSupport.askOwner(shopSchema);
            let pastExpiry = owner("mutation { createApiKey(name: \"old\", scope: WRITE, role: WRITER, expiresAt: \"2000-01-01T00:00:00Z\") { key expiresAt } }") |> snd;
            let revokedIssued = owner("mutation { createApiKey(name: \"gone\", scope: WRITE, role: WRITER) { id key } }");
            discard owner("mutation { revokeApiKey(id: \"${GraphqlTestKit.stringAt(List#{"createApiKey", "id"}, revokedIssued)}\") }");
            let shopKey = GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, shopOwner("mutation { createApiKey(name: \"shop\", scope: WRITE, role: OWNER) { key } }"));
            let createWith = key -> asCredential(schema, Credential.ApiKey(key))("mutation { createEntry(typeId: \"${TypeId.toInt64(blogs)}\", fields: { title: \"hi\" }) { id } }") |> snd;
            (pastExpiry,
             createWith(GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, revokedIssued)),
             createWith(shopKey),
             createWith("cms_unknown"))
        });
        Assert.assertEq(
            expected = (
                Some("expiresAt: 期限は未来にしてください"),
                Some("この操作（writeEntries）の権限がありません"),
                Some("この操作（writeEntries）の権限がありません"),
                Some("この操作（writeEntries）の権限がありません")),
            outcome)

    ///
    /// ユースケースを直に呼ぶ形。owner は OWNER までの鍵を作れ、鍵の役割と名前は resolve で戻り、期限の無い鍵は 2100 年でも生きている。
    /// 期限付きの鍵は期限の 1ms 前は生きていて、期限ちょうどで切れる。
    ///
    @Test
    def testPgWriteApiKeyResolve(): Unit \ {IO, Assert} =
        let now = 1_700_000_000_000i64;
        let farFuture = 4_102_444_800_000i64;
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"k1", "k2"}, () -> asOwner(() -> {
            let forever = ApiKeys.create(pepper(), { name = "ci", scope = ApiKeyScope.Write(Role.Owner), expiresAt = None }, now);
            let untilFarFuture = ApiKeys.create(pepper(), { name = "short", scope = ApiKeyScope.Read, expiresAt = Some(Timestamp.fromEpochMillis(farFuture)) }, now);
            let summary = found -> found |> Option.map(key -> (key#name, key#scope));
            (ApiKeys.resolve(pepper(), forever#key, ProjectId.default(), farFuture) |> summary,
             ApiKeys.resolve(pepper(), untilFarFuture#key, ProjectId.default(), farFuture - 1i64) |> summary,
             ApiKeys.resolve(pepper(), untilFarFuture#key, ProjectId.default(), farFuture) |> summary)
        })));
        Assert.assertEq(expected = Ok(Ok((Some(("ci", ApiKeyScope.Write(Role.Owner))), Some(("short", ApiKeyScope.Read)), None))), result)

    ///
    /// 使用時刻は 60 秒の粒度。続けて 2 回 touch すると 1 回目は 1 行、2 回目は 0 行。
    ///
    @Test
    def testPgTouchApiKeyOncePerMinute(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"k1"}, () -> asOwner(() -> {
            let issued = ApiKeys.create(pepper(), { name = "ci", scope = ApiKeyScope.Read, expiresAt = None }, 0i64);
            (ApiKeys.touch(issued#id, ProjectId.default()), ApiKeys.touch(issued#id, ProjectId.default()))
        })));
        Assert.assertEq(expected = Ok(Ok((1, 0))), result)

    ///
    /// コンテンツ API で readDraft の鍵を使っても lastUsedAt は付かず、管理 API で使うと付く。
    ///
    @Test
    def testPgContentApiDoesNotTouchApiKey(): Unit \ {IO, Assert} =
        let seedWithKey = () -> CmsTestKit.withIds(List#{"e1", "k1"}, () -> {
            let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let entry = ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("hi"))}));
            discard ContentEntries.publish(entry#id, "tester", false);
            asOwner(() -> ApiKeys.create(pepper(), { name = "site", scope = ApiKeyScope.ReadDraft, expiresAt = None }, 0i64))#key
        });
        let outcome = PgTestSupport.withPool(pool -> {
            let key = PgTestSupport.seed(seedWithKey);
            let deps = PgTestSupport.deps();
            let cache = ContentEngine.create(deps);
            let engine = match ContentEngine.current(cache, pool, ProjectId.default()) { case Ok(found) => found case Err(message) => bug!(message) };
            let admin = AdminSchema.make(deps, AdminRunner.make(pool, deps, ProjectId.default()));
            let lastUsed = () -> PgTestSupport.mutate(pool, () -> asOwner(() -> ApiKeys.list() |> List.map(found -> Option.nonEmpty(found#lastUsedAt)))) |> PgTestSupport.seededOrBug;
            let viaContent = GraphqlTestKit.askEngineWith(engine, Context.withCredential(Credential.ApiKey(key)), "{ blogs { totalCount } }");
            let afterContent = lastUsed();
            let viaAdmin = asCredential(admin, Credential.ApiKey(key))("{ contentTypes { apiId } }") |> snd;
            (viaContent, afterContent, viaAdmin, lastUsed())
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }), None),
                List#{ false },
                None,
                List#{ true }),
            outcome)

}
