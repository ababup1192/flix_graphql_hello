///
/// POST /mcp を Server.handle から本物の管理 API のエンジンと実 PostgreSQL に通す。
/// 全ツールを 1 度は呼ぶ（VerifyError と写し漏れの見張り）、Markdown の本文の往復、権限とプロジェクトの分離と CONFLICT が isError で返る事、HTTP のステータス。
///
mod TestMcpPg {

    use Util.Json.Json

    /// ログインの JWT は無い（検証は必ず落ちる）設定でヘッダから身元を組む。
    def credentialOf(request: HttpRequest): Credential =
        Credentials.ofHeaders("Authorization", _ -> Err("JWT は無し"), request#headers)

    /// 管理画面のオリジンだけ許す設定。
    def config(): ServerConfig =
        { cors = { allowedOrigins = "https://admin.example.com" :: Nil }, version = "test" | Server.defaultConfig() }

    /// POST /mcp。
    def post(headers: List[(String, String)], body: String): HttpRequest =
        { version = "HTTP/1.1", method = "POST", path = "/mcp", headers = ("Content-Type", "application/json") :: headers, body = body }

    /// tools/call の本文。
    def callBody(tool: String, arguments: Value): String =
        JsonValue.toJsonString(Value.Obj(Map#{ "jsonrpc" => Value.Str("2.0"), "id" => Value.Int(1), "method" => Value.Str("tools/call"),
            "params" => Value.Obj(Map#{ "name" => Value.Str(tool), "arguments" => arguments }) }))

    /// 管理 API のエンジンでリクエストを処理し、(status, body の JSON) を返す。認証（リクエストに 1 回）は Main.runRoute と同じく handle の前。
    def handle(api: PgTestSupport.Api, engine: Graphql.Engine, credential: Credential, request: HttpRequest): (Int32, Value) \ IO =
        handleAuthenticated(engine, credential, PgTestSupport.authenticate(api#pool, api#engine, credential), request)

    /// 認証の結果を渡して処理する。
    def handleAuthenticated(engine: Graphql.Engine, credential: Credential, auth: Result[Rejection, Authenticated], request: HttpRequest): (Int32, Value) \ IO =
        let response = Graphql.runWithEngine(engine, () -> ServerTestKit.quietly(() -> Server.handle(config(), HealthFake.ok(), credential, auth, request)));
        (response#status, JsonValue.parse(response#body) |> Result.getWithDefault(Value.Null))

    /// ツールを 1 つ呼び、result.content[0].text を JSON に読んで (isError, text の JSON) にする。
    def call(api: PgTestSupport.Api, engine: Graphql.Engine, credential: Credential, tool: String, arguments: Value): (Value, Value) \ IO =
        let (_, body) = handle(api, engine, credential, post(Nil, callBody(tool, arguments)));
        let result = Value.field("result", body);
        (Value.field("isError", result), contentJson(result))

    /// content[0].text を JSON に。形が違うのはテストの前提が壊れている。
    def contentJson(result: Value): Value = match Value.field("content", result) {
        case Value.List(first :: Nil) => Value.field("text", first) |> Value.asStr |> Option.getWithDefault("") |> JsonValue.parse |> Result.getWithDefault(Value.Null)
        case other                    => bug!("content が 1 件ではありません: ${other}")
    }

    def obj(pairs: List[(String, Value)]): Value = Value.Obj(List.toMap(pairs))

    /// posts 型（title: TEXT, body: RICH_TEXT）を owner が管理 API で作る。
    def seedPosts(api: PgTestSupport.Api): Unit \ IO =
        let ask = PgTestSupport.askOwner(api);
        let typeId = GraphqlTestKit.stringAt(List#{"createContentType", "id"}, ask("mutation { createContentType(input: { apiId: \"posts\", name: \"投稿\", previewUrl: \"https://site.example.com/preview/{id}\" }) { id } }"));
        discard ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"title\", name: \"題\", kind: TEXT }) { id } }");
        discard ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"body\", name: \"本文\", kind: RICH_TEXT }) { id } }")

    /// shop プロジェクトに型と entry を 1 つ作る。その entry の id を返す。
    def seedShop(): String \ Db + CmsErr + IdGen + Session =
        let shop = Projects.create(OrgId.default(), ProjectSlug.ProjectSlug("shop"), "店");
        PgTestSupport.asProject(shop, () -> {
            let items = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("items", "商品"));
            let entry = ContentEntries.create(Session.grant(), items#id, None, CmsTestKit.entryData(Nil));
            EntryId.text(entry#id)
        })

    ///
    /// search_entries を first: 1 で 2 ページ辿る。1 ページ目は next_cursor を返し、それを after に渡した 2 ページ目は残りの 1 件で next_cursor は null。
    /// after と skip を同時に渡すと INVALID。
    ///
    @Test
    def testPgMcpSearchEntriesPages(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            seedPosts(api);
            let engine = GraphqlTestKit.engineOrBug(api#schema);
            let owner = PgTestSupport.ownerCredential();
            let tool = (name, arguments) -> call(api, engine, owner, name, arguments);
            let first = tool("create_entry", obj(List#{ ("type", Value.Str("posts")), ("fields", obj(List#{ ("title", Value.Str("one")) })) }));
            let second = tool("create_entry", obj(List#{ ("type", Value.Str("posts")), ("fields", obj(List#{ ("title", Value.Str("two")) })) }));
            let page1 = tool("search_entries", obj(List#{ ("type", Value.Str("posts")), ("first", Value.Int(1)) }));
            let cursor = Value.field("next_cursor", snd(page1));
            let page2 = tool("search_entries", obj(List#{ ("type", Value.Str("posts")), ("first", Value.Int(1)), ("after", cursor) }));
            let both = tool("search_entries", obj(List#{ ("type", Value.Str("posts")), ("skip", Value.Int(1)), ("after", cursor) }));
            let idsOf = page -> Value.field("nodes", snd(page)) |> listOf |> List.map(Value.field("id"));
            (idsOf(page1), Option.nonEmpty(Value.asStr(cursor)), idsOf(page2), Value.field("next_cursor", snd(page2)),
             fst(both), Value.field("code", snd(both)),
             List#{ Value.field("id", snd(second)), Value.field("id", snd(first)) })
        });
        let (page1, hasCursor, page2, next, bothError, bothCode, created) = outcome;
        Assert.assertEq(
            expected = (List.take(1, created), true, List.drop(1, created), Value.Null, Value.Bool(true), Value.Str("INVALID")),
            (page1, hasCursor, page2, next, bothError, bothCode))

    ///
    /// 全ツールを owner で 1 度ずつ呼ぶ。Markdown の本文が doc に入り、markdown で戻る。
    ///
    ///   list_types → get_type → create_entry(body: Markdown) → search_entries → publish_check → impact(PUBLISH)
    ///     → diff_entry(DRAFT, DRAFT) → publish → diff_entry(PUBLISHED, DRAFT) → get_entry(markdown) → get_entry(PUBLISHED, text)
    ///     → update_entry → preview_url → impact(UNPUBLISH) → unpublish → restore_version(公開時のバージョン) → whoami → delete_entry → get_entry(NOT_FOUND)
    ///
    @Test
    def testPgMcpAllTools(): Unit \ {IO, Assert} =
        let markdown = "# 見出し\n\n本文";
        let outcome = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            seedPosts(api);
            let engine = GraphqlTestKit.engineOrBug(api#schema);
            let owner = PgTestSupport.ownerCredential();
            let tool = (name, arguments) -> call(api, engine, owner, name, arguments);
            let types = tool("list_types", Value.Null);
            let posts = tool("get_type", obj(List#{ ("apiId", Value.Str("posts")) }));
            let created = tool("create_entry", obj(List#{ ("type", Value.Str("posts")), ("fields", obj(List#{ ("title", Value.Str("Hello")), ("body", Value.Str(markdown)) })) }));
            let entryId = Value.field("id", snd(created)) |> Value.asStr |> Option.getWithDefault("");
            let idArg = obj(List#{ ("id", Value.Str(entryId)) });
            let searched = tool("search_entries", obj(List#{ ("type", Value.Str("posts")), ("search", Value.Str("Hello")) }));
            let checked = tool("publish_check", idArg);
            let impactPublish = tool("impact", obj(List#{ ("id", Value.Str(entryId)), ("action", Value.Str("PUBLISH")) }));
            let sameDraft = tool("diff_entry", obj(List#{ ("id", Value.Str(entryId)), ("from", obj(List#{ ("stage", Value.Str("DRAFT")) })), ("to", obj(List#{ ("stage", Value.Str("DRAFT")) })) }));
            let published = tool("publish", obj(List#{ ("id", Value.Str(entryId)), ("withDependencies", Value.Bool(false)) }));
            let afterPublish = tool("diff_entry", obj(List#{ ("id", Value.Str(entryId)), ("from", obj(List#{ ("stage", Value.Str("PUBLISHED")) })), ("to", obj(List#{ ("stage", Value.Str("DRAFT")) })) }));
            let readMarkdown = tool("get_entry", idArg);
            let readText = tool("get_entry", obj(List#{ ("id", Value.Str(entryId)), ("stage", Value.Str("PUBLISHED")), ("format", Value.Str("text")) }));
            let version = Value.field("version", snd(readMarkdown)) |> Value.asInt |> Option.getWithDefault(-1);
            let updated = tool("update_entry", obj(List#{ ("id", Value.Str(entryId)), ("fields", obj(List#{ ("title", Value.Str("Hello 2")) })), ("expectedVersion", Value.Int(version)) }));
            let preview = tool("preview_url", idArg);
            let impactUnpublish = tool("impact", obj(List#{ ("id", Value.Str(entryId)), ("action", Value.Str("UNPUBLISH")) }));
            let unpublished = tool("unpublish", idArg);
            let versionId = Value.path(List#{"versions"}, snd(readMarkdown)) |> listOf |> List.head |> Option.map(Value.field("id")) |> Option.getWithDefault(Value.Null);
            let restored = tool("restore_version", obj(List#{ ("id", Value.Str(entryId)), ("versionId", versionId), ("expectedVersion", Value.field("version", snd(unpublished))) }));
            let restoredTitle = tool("get_entry", idArg);
            let me = tool("whoami", Value.Null);
            let deleted = tool("delete_entry", idArg);
            let gone = tool("get_entry", idArg);
            List#{
                PgTestSupport.named("list_types", (fst(types), snd(types) |> listOf |> List.map(Value.field("apiId")))),
                PgTestSupport.named("get_type", (fst(posts), Value.field("apiId", snd(posts)), snd(posts) |> Value.field("fields") |> listOf |> List.map(Value.field("kind")))),
                PgTestSupport.named("create_entry", (fst(created), Value.field("stage", snd(created)), Value.field("version", snd(created)))),
                PgTestSupport.named("search_entries", (fst(searched), Value.field("count", snd(searched)), Value.path(List#{"nodes"}, snd(searched)) |> listOf |> List.map(Value.path(List#{"fields", "body"})))),
                PgTestSupport.named("publish_check", (fst(checked), Value.field("ok", snd(checked)), Value.field("violations", snd(checked)))),
                PgTestSupport.named("impact PUBLISH", (fst(impactPublish), snd(impactPublish))),
                PgTestSupport.named("diff DRAFT/DRAFT", (fst(sameDraft), snd(sameDraft))),
                PgTestSupport.named("publish", (fst(published), Value.field("stage", snd(published)))),
                PgTestSupport.named("diff PUBLISHED/DRAFT", (fst(afterPublish), snd(afterPublish))),
                PgTestSupport.named("get_entry markdown", (fst(readMarkdown), Value.path(List#{"fields", "body"}, snd(readMarkdown)), Value.path(List#{"fields", "title"}, snd(readMarkdown)))),
                PgTestSupport.named("get_entry PUBLISHED text", (fst(readText), Value.path(List#{"fields", "body"}, snd(readText)))),
                PgTestSupport.named("update_entry", (fst(updated), Value.field("stage", snd(updated)))),
                PgTestSupport.named("preview_url", (fst(preview), Value.field("token", snd(preview)) |> Value.asStr |> Option.map(String.startsWith(prefix = "pv_")), Value.field("url", snd(preview)) |> Value.asStr |> Option.map(String.contains(substr = "?preview=pv_")))),
                PgTestSupport.named("impact UNPUBLISH", (fst(impactUnpublish), snd(impactUnpublish))),
                PgTestSupport.named("unpublish", (fst(unpublished), Value.field("stage", snd(unpublished)))),
                PgTestSupport.named("get_entry versions", Value.path(List#{"versions"}, snd(readMarkdown)) |> listOf |> List.map(listed -> (Value.field("reason", listed), Value.field("version", listed), Value.field("fields", listed)))),
                PgTestSupport.named("restore_version", (fst(restored), Value.field("version", snd(restored)), Value.path(List#{"fields", "title"}, snd(restoredTitle)))),
                PgTestSupport.named("whoami", (fst(me), Value.field("kind", snd(me)), Value.field("name", snd(me)), Value.field("roles", snd(me)), Value.field("scope", snd(me)), Value.field("permissions", snd(me)))),
                PgTestSupport.named("delete_entry", (fst(deleted), Value.field("id", snd(deleted)) == Value.Str(entryId), Value.field("deleted", snd(deleted)))),
                PgTestSupport.named("get_entry after delete", (fst(gone), Value.field("code", snd(gone)))) }
        });
        let empty = Value.List(Nil);
        Assert.assertEq(
            expected = List#{
                PgTestSupport.named("list_types", (Value.Bool(false), List#{ Value.Str("posts") })),
                PgTestSupport.named("get_type", (Value.Bool(false), Value.Str("posts"), List#{ Value.Str("TEXT"), Value.Str("RICH_TEXT") })),
                PgTestSupport.named("create_entry", (Value.Bool(false), Value.Str("DRAFT"), Value.Int(1))),
                PgTestSupport.named("search_entries", (Value.Bool(false), Value.Int(1), List#{ Value.Str("見出し\n本文") })),
                PgTestSupport.named("publish_check", (Value.Bool(false), Value.Bool(true), empty)),
                PgTestSupport.named("impact PUBLISH", (Value.Bool(false), obj(List#{ ("breaks", empty), ("cascades", empty) }))),
                PgTestSupport.named("diff DRAFT/DRAFT", (Value.Bool(false), empty)),
                PgTestSupport.named("publish", (Value.Bool(false), Value.Str("PUBLISHED"))),
                PgTestSupport.named("diff PUBLISHED/DRAFT", (Value.Bool(false), empty)),
                PgTestSupport.named("get_entry markdown", (Value.Bool(false), Value.Str(markdown), Value.Str("Hello"))),
                PgTestSupport.named("get_entry PUBLISHED text", (Value.Bool(false), Value.Str("見出し\n本文"))),
                PgTestSupport.named("update_entry", (Value.Bool(false), Value.Str("CHANGED"))),
                PgTestSupport.named("preview_url", (Value.Bool(false), Some(true), Some(true))),
                PgTestSupport.named("impact UNPUBLISH", (Value.Bool(false), obj(List#{ ("breaks", empty), ("cascades", empty) }))),
                PgTestSupport.named("unpublish", (Value.Bool(false), Value.Str("DRAFT"))),
                PgTestSupport.named("get_entry versions", List#{ (Value.Str("PUBLISH"), Value.Int(1), Value.Null) }),
                PgTestSupport.named("restore_version", (Value.Bool(false), Value.Int(3), Value.Str("Hello"))),
                PgTestSupport.named("whoami", (Value.Bool(false), Value.Str("USER"), Value.Str("owner@test"), Value.List(Value.Str("OWNER") :: Nil), Value.Null,
                    Value.List(List#{ "manageApiKeys", "manageAssets", "manageMembers", "manageProject", "manageTypes", "publishEntries", "readDraft", "writeEntries" } |> List.map(Value.Str)))),
                PgTestSupport.named("delete_entry", (Value.Bool(false), true, Value.Bool(true))),
                PgTestSupport.named("get_entry after delete", (Value.Bool(true), Value.Str("NOT_FOUND"))) },
            outcome)

    /// 配列。配列でなければ空。
    def listOf(value: Value): List[Value] = match value {
        case Value.List(items) => items
        case _                 => Nil
    }

    ///
    /// 業務エラーは isError: true の content に code が入る。
    ///   read の鍵で create_entry            → FORBIDDEN（型が無くても FORBIDDEN。型の有無より権限が先）
    ///   他のプロジェクト（shop）の entry id → NOT_FOUND（entity: Entry）
    ///   古い expectedVersion で update_entry → CONFLICT で actualVersion
    ///
    @Test
    def testPgMcpBusinessErrors(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(seedShop, (api, shopEntryId) -> {
            seedPosts(api);
            let engine = GraphqlTestKit.engineOrBug(api#schema);
            let owner = PgTestSupport.ownerCredential();
            let readKey = GraphqlTestKit.stringAt(List#{"createApiKey", "key"}, PgTestSupport.askOwner(api)("mutation { createApiKey(name: \"reader\", scope: READ) { key } }"));
            let created = call(api, engine, owner, "create_entry", obj(List#{ ("type", Value.Str("posts")), ("fields", obj(List#{ ("title", Value.Str("a")) })) }));
            let entryId = Value.field("id", snd(created)) |> Value.asStr |> Option.getWithDefault("");
            let forbidden = call(api, engine, Credential.ApiKey(readKey), "create_entry", obj(List#{ ("type", Value.Str("posts")), ("fields", obj(Nil)) }));
            let forbiddenNoType = call(api, engine, Credential.ApiKey(readKey), "create_entry", obj(List#{ ("type", Value.Str("nope")), ("fields", obj(Nil)) }));
            let notFound = call(api, engine, owner, "get_entry", obj(List#{ ("id", Value.Str(shopEntryId)) }));
            let conflict = call(api, engine, owner, "update_entry", obj(List#{ ("id", Value.Str(entryId)), ("fields", obj(Nil)), ("expectedVersion", Value.Int(99)) }));
            (fst(forbidden), Value.field("code", snd(forbidden)), Value.field("code", snd(forbiddenNoType)),
             fst(notFound), Value.field("code", snd(notFound)), Value.field("entity", snd(notFound)),
             fst(conflict), Value.field("code", snd(conflict)), Value.field("actualVersion", snd(conflict)))
        });
        Assert.assertEq(
            expected = (Value.Bool(true), Value.Str("FORBIDDEN"), Value.Str("FORBIDDEN"), Value.Bool(true), Value.Str("NOT_FOUND"), Value.Str("Entry"), Value.Bool(true), Value.Str("CONFLICT"), Value.Int(1)),
            outcome)

    ///
    /// HTTP のステータス。
    ///   壊れたログインの JWT     → 401 + WWW-Authenticate
    ///   死んだ PAT               → 401
    ///   Origin が許可外          → 403
    ///   Origin 無し（tools/list）→ 200
    ///   Origin が許可済み        → 200
    ///   notifications/initialized → 202 で body 無し
    ///   知らない MCP-Protocol-Version → 400
    ///   プレビュートークン       → 400
    ///   GET                      → 405
    ///
    @Test
    def testPgMcpHttpStatuses(): Unit \ {IO, Assert} =
        let listBody = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
        let outcome = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            let engine = GraphqlTestKit.engineOrBug(api#schema);
            let viaHeaders = request -> handle(api, engine, credentialOf(request), request);
            let badJwt = viaHeaders(post(("Authorization", "Bearer not-a-jwt") :: Nil, listBody));
            let deadPat = viaHeaders(post(("Authorization", "Bearer cmspat_nope") :: Nil, callBody("list_types", Value.Null)));
            let badOrigin = viaHeaders(post(("Origin", "https://evil.example.com") :: Nil, listBody));
            let noOrigin = viaHeaders(post(Nil, listBody));
            let goodOrigin = viaHeaders(post(("Origin", "https://admin.example.com") :: Nil, listBody));
            let initialized = Graphql.runWithEngine(engine, () -> ServerTestKit.quietly(() -> Server.handle(config(), HealthFake.ok(), Credential.Missing, Ok(Authentication.anonymous()), post(Nil, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"))));
            let badVersion = viaHeaders(post(("MCP-Protocol-Version", "2099-01-01") :: Nil, listBody));
            let preview = viaHeaders(post(("X-Preview-Token", "pv_x") :: Nil, listBody));
            let get = viaHeaders({ version = "HTTP/1.1", method = "GET", path = "/mcp", headers = Nil, body = "" });
            let badJwtHeader = Graphql.runWithEngine(engine, () -> ServerTestKit.quietly(() -> Server.handle(config(), HealthFake.ok(), Credential.Invalid("JWT は無し"), Err(Rejection.Invalid("JWT は無し")), post(Nil, listBody))))#headers |> Http.findHeader("WWW-Authenticate");
            (fst(badJwt), badJwtHeader, fst(deadPat), fst(badOrigin), fst(noOrigin), fst(goodOrigin), (initialized#status, initialized#body), fst(badVersion), fst(preview), fst(get))
        });
        Assert.assertEq(
            expected = (401, Some("Bearer error=\"invalid_token\""), 401, 403, 200, 200, (202, ""), 400, 400, 405),
            outcome)

}
