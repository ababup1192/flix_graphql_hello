///
/// コンテンツ API の GET を CDN に乗せる形を実 PostgreSQL で見る。匿名の GET に ETag が付き、If-None-Match が合えば 304、
/// 公開で版が進めば同じ If-None-Match でも 200 と新しい ETag になる。
///
/// WhyNot: ソケットを開かないのは TestServerAuthPg と同じ。認証と版の読み取り（Main.runRoute の locate）は PgTestSupport.locateAnonymousObserved が同じ形で行う。
///
mod TestCdnCachePg {

    use Util.Json.Json

    /// blogs（title）に b1 を公開済みで置く。b2 は下書き。
    def seed(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentTypes.addField(Session.grant(), blogs#id, { unique = true | CmsTestKit.fieldDraft("slug", FieldKind.Slug, { sourceField = Some(CmsTestKit.apiId("title")) | FieldConfig.empty() }) });
        discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b1")), CmsTestKit.entryData(List#{("title", Json.JString("one")), ("slug", Json.JString("one"))}));
        discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b2")), CmsTestKit.entryData(List#{("title", Json.JString("two")), ("slug", Json.JString("two"))}));
        discard ContentEntries.publish(Session.grant(), CmsTestKit.entryId("b1"), "tester", false)

    /// GET /graphql?query={ blogs { nodes { id } } }（パーセント符号化済み）。
    def get(headers: List[(String, String)]): HttpRequest =
        getPath("/graphql?query=%7B%20blogs%20%7B%20nodes%20%7B%20id%20%7D%20%7D%20%7D", headers)

    def getPath(path: String, headers: List[(String, String)]): HttpRequest =
        { version = "HTTP/1.1", method = "GET", path = path, headers = headers, body = "" }

    /// GET /graphql?query=query($after: String) { blogs(after: $after) { nodes { id } pageInfo { endCursor } } }&variables={"after": …}（パーセント符号化済み）。
    /// after は base64url なので符号化せずそのまま置ける。
    def getAfter(after: Option[String]): HttpRequest =
        let variables = after |> Option.map(cursor -> "%7B%22after%22%3A%22${cursor}%22%7D") |> Option.getWithDefault("%7B%22after%22%3Anull%7D");
        getPath("/graphql?query=query(%24after%3A%20String)%20%7B%20blogs(after%3A%20%24after)%20%7B%20nodes%20%7B%20id%20%7D%20pageInfo%20%7B%20endCursor%20%7D%20%7D%20%7D&variables=${variables}", Nil)

    /// 匿名で認証して版を読み（Main.runRoute と同じ）、コンテンツ API のエンジンで処理する。(status, ETag, 本文の entry id)。
    def handle(pool: Pool, engine: Graphql.Engine, headers: List[(String, String)]): (Int32, Option[String], List[String]) \ IO =
        handleRequest(pool, engine, get(headers))

    /// リクエストを渡す版。(status, ETag, 本文の entry id)。
    def handleRequest(pool: Pool, engine: Graphql.Engine, request: HttpRequest): (Int32, Option[String], List[String]) \ IO =
        let response = handleFull(pool, engine, request);
        (response#status, Http.findHeader("ETag", response#headers), idsOf(response#body))

    /// リクエストを処理して応答そのものを返す。
    def handleFull(pool: Pool, engine: Graphql.Engine, request: HttpRequest): HttpResponse \ IO =
        let (auth, version) = PgTestSupport.locateAnonymousObserved(pool, _ -> ());
        let config = { cache = Some(CacheHeaders.defaultPolicy()) | Server.defaultConfig() };
        Graphql.runWithEngine(engine, () -> ServerTestKit.quietly(() -> Server.handleWithVersion(config, HealthFake.ok(), Credential.Missing, auth, version, request)))

    /// 本文の data.blogs.pageInfo.endCursor。無ければ None。
    def endCursorOf(body: String): Option[String] =
        JsonValue.parse(body) |> Result.toOption |> Option.flatMap(parsed -> Value.path(List#{"data", "blogs", "pageInfo", "endCursor"}, parsed) |> Value.asStr)

    /// 本文の data.blogs.nodes[].id を id 順に。本文が無ければ空（一覧の既定の並びは新しい順なので、順序は見ない）。
    def idsOf(body: String): List[String] = match JsonValue.parse(body) {
        case Ok(parsed) => match Value.path(List#{"data", "blogs", "nodes"}, parsed) {
            case Value.List(nodes) => nodes |> List.filterMap(node -> Value.field("id", node) |> Value.asStr) |> List.sort
            case _                 => Nil
        }
        case Err(_) => Nil
    }

    ///
    /// 1 回目は 200 と ETag、同じ ETag を If-None-Match に付けた 2 回目は 304 で本文無し、b2 を公開した後の 3 回目は同じ If-None-Match でも 200 と別の ETag で b2 が入る。
    /// Cache-Control は 304 にも付く。
    ///
    @Test
    def testPgCdnConditionalGet(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(seed);
            let engine = PgTestSupport.contentEngine(pool);
            let (firstStatus, firstEtag, firstIds) = handle(pool, engine, Nil);
            let ifNoneMatch = ("If-None-Match", firstEtag |> Option.getWithDefault("")) :: Nil;
            let (secondStatus, secondEtag, secondIds) = handle(pool, engine, ifNoneMatch);
            discard PgTestSupport.mutateOrBug(pool, () -> ContentEntries.publish(Session.grant(), CmsTestKit.entryId("b2"), "tester", false));
            let (thirdStatus, thirdEtag, thirdIds) = handle(pool, engine, ifNoneMatch);
            List#{
                PgTestSupport.named("first", (firstStatus, Option.nonEmpty(firstEtag), firstIds)),
                PgTestSupport.named("second", (secondStatus, secondEtag == firstEtag, secondIds)),
                PgTestSupport.named("third", (thirdStatus, thirdEtag != firstEtag and Option.nonEmpty(thirdEtag), thirdIds))
            }
        });
        Assert.assertEq(
            expected = List#{
                PgTestSupport.named("first", (200, true, List#{"b1"})),
                PgTestSupport.named("second", (304, true, (Nil: List[String]))),
                PgTestSupport.named("third", (200, true, List#{"b1", "b2"}))
            },
            outcome)

    ///
    /// after は variables に入るので ETag が変わる。同じ query で variables だけ after: null → 1 ページ目の endCursor に変えると、
    /// どちらも 200 だが ETag が違い、2 回目は b1 の次なので 0 件。
    ///
    @Test
    def testPgCdnEtagVariesByAfter(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(seed);
            let engine = PgTestSupport.contentEngine(pool);
            let first = handleFull(pool, engine, getAfter(None));
            let firstEtag = Http.findHeader("ETag", first#headers);
            let (secondStatus, secondEtag, secondIds) = handleRequest(pool, engine, getAfter(endCursorOf(first#body)));
            (first#status, idsOf(first#body), Option.nonEmpty(firstEtag), secondStatus, secondIds, Option.nonEmpty(secondEtag) and secondEtag != firstEtag)
        });
        Assert.assertEq(expected = (200, List#{"b1"}, true, 200, (Nil: List[String]), true), outcome)

    /// GET /graphql?query={ blog(id: "b1") { id } }（パーセント符号化済み）。
    def getById(): HttpRequest =
        getPath("/graphql?query=%7B%20blog(id%3A%20%22b1%22)%20%7B%20id%20%7D%20%7D", Nil)

    /// GET /graphql?query={ blog(slug: "one") { id } }（パーセント符号化済み）。
    def getBySlug(): HttpRequest =
        getPath("/graphql?query=%7B%20blog(slug%3A%20%22one%22)%20%7B%20id%20%7D%20%7D", Nil)

    /// 本文の data.blog.id。無ければ None。
    def blogIdOf(body: String): Option[String] =
        JsonValue.parse(body) |> Result.toOption |> Option.flatMap(parsed -> Value.path(List#{"data", "blog", "id"}, parsed) |> Value.asStr)

    ///
    /// id 直引きと slug 直引きは同じ b1 を返すが、query 文が違うので ETag は別になる（CDN のキャッシュが混ざらない）。
    ///
    @Test
    def testPgCdnEtagVariesBySlugArg(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(seed);
            let engine = PgTestSupport.contentEngine(pool);
            let byId = handleFull(pool, engine, getById());
            let bySlug = handleFull(pool, engine, getBySlug());
            (byId#status, blogIdOf(byId#body), bySlug#status, blogIdOf(bySlug#body),
             Option.nonEmpty(Http.findHeader("ETag", bySlug#headers)) and Http.findHeader("ETag", byId#headers) != Http.findHeader("ETag", bySlug#headers))
        });
        Assert.assertEq(expected = (200, Some("b1"), 200, Some("b1"), true), outcome)

}
