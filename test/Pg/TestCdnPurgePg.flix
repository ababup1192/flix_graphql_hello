///
/// CDN の purge の outbox を実 PostgreSQL で見る。公開で版が進んだプロジェクトの purge が tick で 1 行積まれて送られ、
/// 版が進まなければ次の tick では積まれない。送り先が無ければ何も積まれない。HTTP は Http effect の handler を差し替える。
///
mod TestCdnPurgePg {

    use Util.Json.Json
    use Net.Http.Http
    use Net.HttpRequest
    use Net.HttpResponse.HttpResponse

    def target(): PurgeTarget = { url = "https://api.cloudflare.com/client/v4/zones/z1/purge_cache", token = "tok" }

    /// blogs に b1 を作って公開する（版が進む）。
    def seed(): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
        discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b1")), CmsTestKit.entryData(List#{("title", Json.JString("one"))}));
        discard ContentEntries.publish(Session.grant(), CmsTestKit.entryId("b1"), "tester", false)

    /// 積んで送る（BackgroundJobs.tick の purge の部分と同じ順）。相手は決まったステータスを返し、受けたリクエストを記録する。
    def enqueueAndTick(status: Int32, received: Ref[List[HttpRequest], Static], pool: Pool): (Result[String, Int32], Result[String, Int32]) \ IO =
        let queued = CdnPurge.enqueue(pool);
        let sent = run ServerTestKit.quietly(() -> CdnPurge.tick(pool, target())) with handler Http {
            def request(req, resume) = {
                Ref.put(req :: Ref.get(received), received);
                resume(Ok(HttpResponse.HttpResponse({ url = HttpRequest.url(req), status = status, headers = Map.empty(), body = Net.Body.Text("") })))
            }
        };
        (queued, sent)

    /// 既定のプロジェクトの purge の行（版, status, attempts）。
    def purges(pool: Pool): List[(Int64, String, Int32)] \ IO =
        match DbRunner.withTx(pool, None, () -> CdnPurgesQueries.listPurges(ProjectId.toInt64(ProjectId.default()))) {
            case Ok(rows)     => rows |> List.map(row -> (row#contentVersion, row#status, row#attempts))
            case Err(failure) => bug!("purges: ${failure}")
        }

    def header(name: String, req: HttpRequest): String =
        HttpRequest.headers(req) |> Map.get(name) |> Option.flatMap(List.head) |> Option.getWithDefault("")

    ///
    /// seed で版が 3 に進んでいる。
    ///   1 回目: 1 件積まれ（v3）、送られて delivered。リクエストは purge の url に Bearer と purge_everything
    ///   2 回目: 版が進んでいないので積まれず、送る物も無い
    ///   b1 を取り下げて（v4）3 回目: もう 1 件積まれて送られる
    ///
    @Test
    def testPgCdnPurgeOutbox(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(seed);
            let received = Ref.fresh(Static, Nil);
            let first = enqueueAndTick(200, received, pool);
            let afterFirst = purges(pool);
            let second = enqueueAndTick(200, received, pool);
            discard PgTestSupport.mutateOrBug(pool, () -> ContentEntries.unpublish(Session.grant(), CmsTestKit.entryId("b1")));
            let third = enqueueAndTick(200, received, pool);
            let afterThird = purges(pool);
            let lastRequest = Ref.get(received) |> List.head |> Option.map(req -> (HttpRequest.url(req), header("Authorization", req), HttpRequest.body(req)));
            List#{
                PgTestSupport.named("first", first),
                PgTestSupport.named("afterFirst", afterFirst),
                PgTestSupport.named("second", second),
                PgTestSupport.named("third", third),
                PgTestSupport.named("afterThird", afterThird),
                PgTestSupport.named("lastRequest", lastRequest),
                PgTestSupport.named("requestCount", List.length(Ref.get(received)))
            }
        });
        let count = (n: Int32) -> (Ok(n): Result[String, Int32]);
        Assert.assertEq(
            expected = List#{
                PgTestSupport.named("first", (count(1), count(1))),
                PgTestSupport.named("afterFirst", List#{ (3i64, "delivered", 1) }),
                PgTestSupport.named("second", (count(0), count(0))),
                PgTestSupport.named("third", (count(1), count(1))),
                PgTestSupport.named("afterThird", List#{ (3i64, "delivered", 1), (4i64, "delivered", 1) }),
                PgTestSupport.named("lastRequest", Some(("https://api.cloudflare.com/client/v4/zones/z1/purge_cache", "Bearer tok", Some("{\"purge_everything\":true}")))),
                PgTestSupport.named("requestCount", 2)
            },
            outcome)

    ///
    /// 送り先が無い（環境変数無し）なら、BackgroundJobs.tick を回しても purge は積まれない。相手が 500 なら pending に戻って attempts 1。
    ///
    @Test
    def testPgCdnPurgeDisabledAndRetry(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(seed);
            let failures = ServerTestKit.quietly(() -> BackgroundJobs.tick(pool, BackgroundJobs.createState(15i64, None, OutboundHttp.newClient(), Scheduler.defaultConfig())));
            let whileDisabled = purges(pool);
            let received = Ref.fresh(Static, Nil);
            let failed = enqueueAndTick(500, received, pool);
            (failures, whileDisabled, failed, purges(pool))
        });
        Assert.assertEq(
            expected = ((Nil: List[String]), (Nil: List[(Int64, String, Int32)]), ((Ok(1): Result[String, Int32]), (Ok(1): Result[String, Int32])), List#{ (3i64, "pending", 1) }),
            outcome)

}
