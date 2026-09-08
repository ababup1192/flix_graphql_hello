///
/// CdnPurge: 送り先の読み取りと purge のリクエストの形（純粋な部分）。
///
mod TestCdnPurge {

    use Net.HttpRequest

    /// url と token が両方あって空でない時だけ有効。
    @Test
    def testTargetOfTable(): Unit \ Assert =
        let cases = List#{
            ((Some("https://api.example/purge"), Some("tok")), Some({ url = "https://api.example/purge", token = "tok" })),
            ((Some("https://api.example/purge"), None),        None),
            ((None, Some("tok")),                              None),
            ((Some(""), Some("tok")),                          None),
            ((Some("https://api.example/purge"), Some("")),    None),
            ((None, None),                                     None)
        };
        Assert.assertEq(expected = cases |> List.map(match (_, expected) -> expected |> Option.map(target -> (target#url, target#token))),
            cases |> List.map(match ((url, token), _) -> CdnPurge.targetOf(url, token) |> Option.map(target -> (target#url, target#token))))

    /// Cloudflare の purge_cache の形: POST、JSON、Bearer のトークン、本文は purge_everything、配信 id のヘッダ。
    @Test
    def testBuildRequest(): Unit \ Assert =
        let request = CdnPurge.buildRequest({ url = "https://api.cloudflare.com/client/v4/zones/z1/purge_cache", token = "tok" }, "01J");
        let header = name -> HttpRequest.headers(request) |> Map.get(name) |> Option.flatMap(List.head);
        Assert.assertEq(
            expected = ("https://api.cloudflare.com/client/v4/zones/z1/purge_cache", Some("Bearer tok"), Some("01J"), Some("{\"purge_everything\":true}")),
            (HttpRequest.url(request), header("Authorization"), header("X-Cms-Delivery"), HttpRequest.body(request)))

}
