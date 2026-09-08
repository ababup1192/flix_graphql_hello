///
/// CacheHeaders: コンテンツ API の GET に付ける ETag と Cache-Control、If-None-Match の照合。純粋な関数だけ。
///
mod TestCacheHeaders {

    def requestOf(queryText: String, variables: Map[String, Value], operationName: Option[String]): GraphqlRequest =
        { queryText = queryText, variables = variables, operationName = operationName }

    /// ETag は weak で、版と「query + variables（JSON） + operationName」の SHA-256 の先頭 16 桁。版が進むか文書が変われば変わる。
    /// 期待値は `printf '{ x }\n{}\n' | shasum -a 256` のように手で取った物。
    @Test
    def testEtagOfTable(): Unit \ Assert =
        let cases = List#{
            ((7i64,  requestOf("{ x }", Map.empty(), None)),                                                           "W/\"v7-672ea399e2973a3a\""),
            ((8i64,  requestOf("{ x }", Map.empty(), None)),                                                           "W/\"v8-672ea399e2973a3a\""),
            ((7i64,  requestOf("query Q($f: Int) { blogs(first: $f) { id } }", Map#{ "f" => Value.Int(2) }, Some("Q"))), "W/\"v7-313954d9540dc20b\"")
        };
        Assert.assertEq(expected = cases |> List.map(snd),
            cases |> List.map(match ((version, request), _) -> CacheHeaders.etagOf(version, request)))

    /// If-None-Match の照合: 無ければ外れ、同じ物・* ・複数の中の 1 つは当たり、weak の印の有無は問わない、違う物は外れ。
    @Test
    def testMatchesTable(): Unit \ Assert =
        let etag = "W/\"v7-672ea399e2973a3a\"";
        let cases = List#{
            (None,                                                     false),
            (Some("W/\"v7-672ea399e2973a3a\""),                        true),
            (Some("\"v7-672ea399e2973a3a\""),                          true),
            (Some("*"),                                                true),
            (Some("W/\"v6-672ea399e2973a3a\", W/\"v7-672ea399e2973a3a\""), true),
            (Some("W/\"v6-672ea399e2973a3a\",\"v5-672ea399e2973a3a\""),    false),
            (Some("W/\"v7-0000000000000000\""),                        false),
            (Some(""),                                                 false)
        };
        Assert.assertEq(expected = cases |> List.map(snd),
            cases |> List.map(match (ifNoneMatch, _) -> CacheHeaders.matches(ifNoneMatch, etag)))

    /// Cache-Control の文字列は s-maxage / max-age / stale-while-revalidate の順で public。
    @Test
    def testCacheControl(): Unit \ Assert =
        Assert.assertEq(
            expected = "public, s-maxage=10, max-age=0, stale-while-revalidate=60",
            CacheHeaders.cacheControl(CacheHeaders.defaultPolicy()))

    /// 環境変数からの読み取り: 無ければ既定（10 / 0 / 60）、数字なら使う、数字でなければ既定、s-maxage と max-age が両方 0 なら None（no-store）。
    @Test
    def testPolicyOfTable(): Unit \ Assert =
        let cases = List#{
            ((None, None, None),                      Some({ sMaxAge = 10, maxAge = 0, staleWhileRevalidate = 60 })),
            ((Some("30"), Some("5"), Some("120")),    Some({ sMaxAge = 30, maxAge = 5, staleWhileRevalidate = 120 })),
            ((Some("x"), Some("y"), Some("z")),       Some({ sMaxAge = 10, maxAge = 0, staleWhileRevalidate = 60 })),
            ((Some("0"), Some("0"), Some("60")),      None),
            ((Some("0"), Some("15"), None),           Some({ sMaxAge = 0, maxAge = 15, staleWhileRevalidate = 60 })),
            ((Some("-1"), Some("-1"), Some("-1")),    None)
        };
        Assert.assertEq(expected = cases |> List.map(match (_, expected) -> expected |> Option.map(CacheHeaders.cacheControl)),
            cases |> List.map(match ((sMaxAge, maxAge, swr), _) -> CacheHeaders.policyOf(sMaxAge, maxAge, swr) |> Option.map(CacheHeaders.cacheControl)))

}
