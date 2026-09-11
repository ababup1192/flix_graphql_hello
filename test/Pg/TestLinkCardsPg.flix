///
/// linkCard の OGP を実 PostgreSQL で見る。取った結果の upsert → 表から引く → 古い行の判定と取り直し（LinkCardRefresh.tick）→ 管理 API 越し。
/// HTTP は Http effect の handler を差し替える（外へは出ない）。
///
mod TestLinkCardsPg {

    use Net.Http.Http
    use Net.HttpRequest
    use Net.HttpResponse.HttpResponse

    def fullUrl(): String = "https://example.com/articles/full"
    def brokenUrl(): String = "https://example.com/articles/broken"

    def html(): String = "<html><head><title>タグの題</title><meta property=\"og:title\" content=\"OGP の題\"><meta property=\"og:description\" content=\"説明\"><meta property=\"og:image\" content=\"/og.png\"><meta property=\"og:site_name\" content=\"example\"></head></html>"

    /// 相手が決まったステータスと本文を返す handler で thunk を走らせる。
    def answering(status: Int32, body: String, thunk: Unit -> a \ ef): a \ (ef - Http) =
        run thunk() with handler Http {
            def request(req, resume) =
                resume(Ok(HttpResponse.HttpResponse({ url = HttpRequest.url(req), status = status, headers = Map#{ "content-type" => List#{ "text/html; charset=utf-8" } }, body = Net.Body.Text(body) })))
        }

    /// 既定のプロジェクトの (url, title, error)。url 順。
    def cards(pool: Pool, urls: List[String]): List[(String, Option[String], Option[String])] \ IO =
        PgTestSupport.mutateOrBug(pool, () -> LinkCards.findMany(urls)) |> List.map(card -> (card#url, card#title, card#error))

    /// 取り直しの番の url。
    def stale(pool: Pool): List[String] \ IO =
        match DbRunner.withTx(pool, None, () -> LinkCardsQueries.listStaleLinkCards(20i64)) {
            case Ok(rows)     => rows |> List.map(row -> row#url)
            case Err(failure) => bug!("stale: ${failure}")
        }

    def shift(url: String, interval: String): Unit \ IO =
        discard PgTestSupport.executeSql("UPDATE link_cards SET fetched_at = now() - interval '${interval}' WHERE url = $1", SqlValue.Str(url) :: Nil)

    ///
    /// 取った結果（成功と失敗）を upsert し、表から引く。同じ url をもう 1 度 upsert すると行は増えず中身が替わる。
    ///
    ///   full:   200 の HTML → title は og:title、image は絶対にした物、error 無し
    ///   broken: 404 → error に理由、title 無し
    ///   full を 404 で upsert し直す → error の行になる（古い title は残らない）
    ///
    @Test
    def testPgUpsertAndFind(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> ());
            let projectId = ProjectId.toInt64(ProjectId.default());
            let fetched = answering(200, html(), () -> LinkCards.fetchOver(LinkCards.userAgent("test"), fullUrl()));
            let broken = answering(404, "", () -> LinkCards.fetchOver(LinkCards.userAgent("test"), brokenUrl()));
            PgTestSupport.mutateOrBug(pool, () -> { LinkCards.store(projectId, fullUrl(), fetched); LinkCards.store(projectId, brokenUrl(), broken) });
            let first = PgTestSupport.mutateOrBug(pool, () -> LinkCards.findMany(List#{ fullUrl(), brokenUrl(), "https://example.com/none" }))
                |> List.map(card -> (card#url, card#title, card#description, card#imageUrl, card#siteName, card#error));
            PgTestSupport.mutateOrBug(pool, () -> LinkCards.store(projectId, fullUrl(), broken));
            let second = cards(pool, List#{ fullUrl(), brokenUrl() });
            (fetched |> Result.map(meta -> meta#title), first, second, PgTestSupport.countSql("SELECT count(*)::bigint AS total FROM link_cards", Nil))
        });
        Assert.assertEq(
            expected = (
                (Ok(Some("OGP の題")): Result[String, Option[String]]),
                List#{
                    (brokenUrl(), None, None, None, None, Some("ページが見つかりません（HTTP 404）")),
                    (fullUrl(), Some("OGP の題"), Some("説明"), Some("https://example.com/og.png"), Some("example"), None)
                },
                List#{
                    (brokenUrl(), None, Some("ページが見つかりません（HTTP 404）")),
                    (fullUrl(), None, Some("ページが見つかりません（HTTP 404）"))
                },
                2i64),
            outcome)

    ///
    /// 取り直しの番は、成功した行なら 7 日、失敗した行なら 1 時間。tick が番の行を取り直し、番でなくなる。
    ///
    ///   置いた直後:            番は無し
    ///   full を 8 日前に:      full だけ
    ///   broken を 2 時間前に:  full, broken（古い順）
    ///   tick（相手は 200）:    2 件取り直し → 両方 title 付きで番は無し
    ///
    @Test
    def testPgRefreshStaleRows(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withPool(pool -> {
            PgTestSupport.seed(() -> ());
            let projectId = ProjectId.toInt64(ProjectId.default());
            PgTestSupport.mutateOrBug(pool, () -> {
                LinkCards.store(projectId, fullUrl(), Ok({ title = Some("古い題"), description = None, imageUrl = None, siteName = None }));
                LinkCards.store(projectId, brokenUrl(), Err("取得に失敗しました（HTTP 500）"))
            });
            let fresh = stale(pool);
            shift(fullUrl(), "8 days");
            let afterFull = stale(pool);
            shift(brokenUrl(), "2 hours");
            let afterBoth = stale(pool);
            let refreshed = answering(200, html(), () -> ServerTestKit.quietly(() -> LinkCardRefresh.tick(pool)));
            (fresh, afterFull, afterBoth, refreshed, cards(pool, List#{ fullUrl(), brokenUrl() }), stale(pool))
        });
        Assert.assertEq(
            expected = (
                (Nil: List[String]),
                List#{ fullUrl() },
                List#{ fullUrl(), brokenUrl() },
                (Ok(2): Result[String, Int32]),
                List#{ (brokenUrl(), Some("OGP の題"), None), (fullUrl(), Some("OGP の題"), None) },
                (Nil: List[String])),
            outcome)

    ///
    /// 管理 API 越し。fetchLinkCard はプライベートアドレスを取りに行かず error だけ返し（表にも残らない）、
    /// linkCards は表にある url だけ返す。LinkCard の全フィールドを 1 度選ぶ。
    ///
    @Test
    def testPgAdminApi(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            PgTestSupport.mutateOrBug(api#pool, () -> LinkCards.store(ProjectId.toInt64(ProjectId.default()), fullUrl(), Ok({ title = Some("OGP の題"), description = Some("説明"), imageUrl = None, siteName = Some("example") })));
            let refused = ask("mutation { fetchLinkCard(url: \"http://127.0.0.1:1/secret\") { url title description imageUrl siteName fetchedAt error } }");
            let listed = ask("{ linkCards(urls: [\"${fullUrl()}\", \"https://example.com/none\"]) { url title description imageUrl siteName error } }");
            let rows = PgTestSupport.countSql("SELECT count(*)::bigint AS total FROM link_cards", Nil);
            ((GraphqlTestKit.valueAt(List#{"fetchLinkCard", "url"}, refused), GraphqlTestKit.valueAt(List#{"fetchLinkCard", "title"}, refused), GraphqlTestKit.valueAt(List#{"fetchLinkCard", "error"}, refused), snd(refused)),
             fst(listed), rows)
        });
        Assert.assertEq(
            expected = (
                (Value.Str("http://127.0.0.1:1/secret"), Value.Null, Value.Str("プライベートアドレスには取りに行きません"), None),
                Value.Obj(Map#{ "linkCards" => Value.List(Value.Obj(Map#{ "url" => Value.Str(fullUrl()), "title" => Value.Str("OGP の題"), "description" => Value.Str("説明"), "imageUrl" => Value.Null, "siteName" => Value.Str("example"), "error" => Value.Null }) :: Nil) }),
                1i64),
            outcome)

}
