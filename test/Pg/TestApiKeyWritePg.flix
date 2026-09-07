///
/// write の API キーを実 PostgreSQL で見る。管理 API を鍵で叩き、役割の範囲で書け、管理（鍵・メンバー・プロジェクト）はできず、
/// 期限切れ・失効・他プロジェクトの鍵は匿名扱いになり、使った鍵に lastUsedAt が付く。
///
mod TestApiKeyWritePg {

    /// 応答の data から文字列（id など）を取る。無ければ空。
    def strIn(path: List[String], response: (Value, Option[String])): String =
        Value.path(path, fst(response)) |> Value.asStr |> Option.getWithDefault("")

    /// blogs 型（title）を作り、shop プロジェクトも作る。戻り値は (blogs の型 id, shop)。
    def seed(): (TypeId, ProjectId) \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        (blogs#id, Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店"))

    /// 管理 API をこの身元で叩く ask。
    def asCredential(schema: Schema, credential: Credential): String -> (Value, Option[String]) \ IO =
        queryText -> GraphqlTestKit.askWith(schema, Context.withCredential(credential), queryText)

    ///
    /// 発行と使い方。owner が WRITE / WRITER と WRITE / EDITOR の鍵を作り、
    ///   writer の鍵: createEntry は通り、publishEntry / createApiKey / inviteMember / updateProjectVisibility は forbidden
    ///   editor の鍵: publishEntry が通る
    ///   READ に role を付ける・WRITE に role を付けない: invalid
    /// 使った鍵には lastUsedAt が付き、使っていない鍵には付かない。
    ///
    @Test
    def testPgWriteApiKeyByRole(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1"}, seed), (schema, seeded) -> {
            let (blogs, _) = seeded;
            let owner = PgTestSupport.askOwner(schema);
            let writerKey = strIn(List#{"createApiKey", "key"}, owner("mutation { createApiKey(name: \"ci\", scope: WRITE, role: WRITER) { key role scope } }"));
            let editorIssued = owner("mutation { createApiKey(name: \"deploy\", scope: WRITE, role: EDITOR) { id key role expiresAt } }");
            let editorKey = strIn(List#{"createApiKey", "key"}, editorIssued);
            let readWithRole = owner("mutation { createApiKey(name: \"x\", scope: READ, role: WRITER) { id } }") |> snd;
            let writeWithoutRole = owner("mutation { createApiKey(name: \"y\", scope: WRITE) { id } }") |> snd;
            let writer = asCredential(schema, Credential.ApiKey(writerKey));
            let editor = asCredential(schema, Credential.ApiKey(editorKey));
            let created = writer("mutation { createEntry(typeId: \"${TypeId.toInt64(blogs)}\", fields: { title: \"hi\" }) { id stage } }");
            let entryId = strIn(List#{"createEntry", "id"}, created);
            let writerPublishes = writer("mutation { publishEntry(id: \"${entryId}\") { id } }") |> snd;
            let writerCreatesKey = writer("mutation { createApiKey(name: \"z\", scope: READ) { id } }") |> snd;
            let writerInvites = writer("mutation { inviteMember(email: \"x@example.com\", role: VIEWER) { id } }") |> snd;
            let writerChangesVisibility = writer("mutation { updateProjectVisibility(visibility: PRIVATE) { id } }") |> snd;
            let editorPublishes = editor("mutation { publishEntry(id: \"${entryId}\") { stage } }");
            let keys = owner("{ apiKeys { name scope role lastUsedAt } }") |> fst |> Value.path(List#{"apiKeys"});
            let used = match keys {
                case Value.List(items) => items |> List.map(item -> (Value.field("name", item), Value.field("scope", item), Value.field("role", item), Value.field("lastUsedAt", item) != Value.Null))
                case _                 => Nil
            };
            (fst(created) |> Value.path(List#{"createEntry", "stage"}),
             Value.path(List#{"createApiKey", "role"}, fst(editorIssued)), Value.path(List#{"createApiKey", "expiresAt"}, fst(editorIssued)),
             readWithRole, writeWithoutRole,
             writerPublishes, writerCreatesKey, writerInvites, writerChangesVisibility,
             editorPublishes,
             used)
        });
        Assert.assertEq(
            expected = (
                Value.Str("DRAFT"),
                Value.Str("EDITOR"), Value.Null,
                Some("role: role は scope が WRITE の鍵にだけ渡せます"),
                Some("role: scope が WRITE の鍵には role が要ります（WRITER / EDITOR / OWNER）"),
                Some("この操作（publishEntries）の権限がありません"),
                Some("この操作（manageApiKeys）の権限がありません"),
                Some("この操作（manageMembers）の権限がありません"),
                Some("この操作（manageProject）の権限がありません"),
                (Value.Obj(Map#{ "publishEntry" => Value.Obj(Map#{ "stage" => Value.Str("PUBLISHED") }) }), None),
                List#{ (Value.Str("ci"), Value.Str("WRITE"), Value.Str("WRITER"), true), (Value.Str("deploy"), Value.Str("WRITE"), Value.Str("EDITOR"), true) }),
            outcome)

    ///
    /// 効かない鍵。期限切れ（expiresAt が過去）と失効した鍵と他プロジェクト（shop）の鍵は匿名扱いで、createEntry は forbidden（writeEntries）。
    /// 期限は応答にそのまま出る。
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
            let expiredIssued = owner("mutation { createApiKey(name: \"old\", scope: WRITE, role: WRITER, expiresAt: \"2000-01-01T00:00:00Z\") { key expiresAt } }");
            let revokedIssued = owner("mutation { createApiKey(name: \"gone\", scope: WRITE, role: WRITER) { id key } }");
            discard owner("mutation { revokeApiKey(id: \"${strIn(List#{"createApiKey", "id"}, revokedIssued)}\") }");
            let shopKey = strIn(List#{"createApiKey", "key"}, shopOwner("mutation { createApiKey(name: \"shop\", scope: WRITE, role: OWNER) { key } }"));
            let createWith = key -> asCredential(schema, Credential.ApiKey(key))("mutation { createEntry(typeId: \"${TypeId.toInt64(blogs)}\", fields: { title: \"hi\" }) { id } }") |> snd;
            (Value.path(List#{"createApiKey", "expiresAt"}, fst(expiredIssued)),
             createWith(strIn(List#{"createApiKey", "key"}, expiredIssued)),
             createWith(strIn(List#{"createApiKey", "key"}, revokedIssued)),
             createWith(shopKey),
             createWith("cms_unknown"))
        });
        Assert.assertEq(
            expected = (
                Value.Str("2000-01-01T00:00:00Z"),
                Some("この操作（writeEntries）の権限がありません"),
                Some("この操作（writeEntries）の権限がありません"),
                Some("この操作（writeEntries）の権限がありません"),
                Some("この操作（writeEntries）の権限がありません")),
            outcome)

    ///
    /// ユースケースを直に呼ぶ形。owner は OWNER までの鍵を作れ、鍵の役割は resolve で戻り、期限の無い鍵は 2100 年でも生きている。
    ///
    @Test
    def testPgWriteApiKeyResolve(): Unit \ {IO, Assert} =
        let pepper = { pepperId = "test", secret = "test-pepper" };
        let farFuture = 4_102_444_800_000i64;
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"k1"}, () -> {
            let owner = Accounts.resolveUser({ ownerEmail = Some("owner@test") }, { issuer = "test", subject = "owner", email = "owner@test", name = "owner" });
            let issued = Session.runWith(Accounts.actorFor(owner, ProjectId.default()), () ->
                ApiKeys.create(pepper, { name = "ci", scope = ApiKeyScope.Write(Role.Owner), expiresAt = None }));
            ApiKeys.resolve(pepper, issued#key, ProjectId.default(), farFuture) |> Option.map(found -> found#scope)
        }));
        Assert.assertEq(expected = Ok(Ok(Some(ApiKeyScope.Write(Role.Owner)))), result)

}
