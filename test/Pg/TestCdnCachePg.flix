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
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentEntries.create(blogs#id, Some(CmsTestKit.entryId("b1")), CmsTestKit.entryData(List#{("title", Json.JString("one"))}));
        discard ContentEntries.create(blogs#id, Some(CmsTestKit.entryId("b2")), CmsTestKit.entryData(List#{("title", Json.JString("two"))}));
        discard ContentEntries.publish(CmsTestKit.entryId("b1"), "tester", false)

    /// GET /graphql?query={ blogs { nodes { id } } }（パーセント符号化済み）。
    def get(headers: List[(String, String)]): HttpRequest =
        { version = "HTTP/1.1", method = "GET", path = "/graphql?query=%7B%20blogs%20%7B%20nodes%20%7B%20id%20%7D%20%7D%20%7D", headers = headers, body = "" }

    /// 匿名で認証して版を読み（Main.runRoute と同じ）、コンテンツ API のエンジンで処理する。(status, ETag, 本文の entry id)。
    def handle(pool: Pool, engine: Graphql.Engine, headers: List[(String, String)]): (Int32, Option[String], List[String]) \ IO =
        let (auth, version) = PgTestSupport.locateAnonymousObserved(pool, _ -> ());
        let config = { cache = Some(CacheHeaders.defaultPolicy()) | Server.defaultConfig() };
        let response = Graphql.runWithEngine(engine, () -> ServerTestKit.quietly(() -> Server.handleWithVersion(config, HealthFake.ok(), Credential.Missing, auth, version, get(headers))));
        (response#status, Http.findHeader("ETag", response#headers), idsOf(response#body))

    /// 本文の data.blogs.nodes[].id。本文が無ければ空。
    def idsOf(body: String): List[String] = match JsonValue.parse(body) {
        case Ok(parsed) => match Value.path(List#{"data", "blogs", "nodes"}, parsed) {
            case Value.List(nodes) => nodes |> List.filterMap(node -> Value.field("id", node) |> Value.asStr)
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
            discard PgTestSupport.mutateOrBug(pool, () -> ContentEntries.publish(CmsTestKit.entryId("b2"), "tester", false));
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

}
