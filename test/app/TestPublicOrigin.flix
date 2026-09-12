///
/// CMS_PUBLIC_ORIGIN の読み方。画面はこの後ろにパスを繋ぐので、末尾の `/` と空白は落とし、空なら None。
///
mod TestPublicOrigin {

    /// 無い・空・空白だけなら None。末尾の `/` は 1 つ落とす。前後の空白は落とす。
    @Test
    def testPublicOriginOfTable(): Unit \ Assert =
        let table = List#{
            (None, None),
            (Some(""), None),
            (Some("   "), None),
            (Some("https://cms.example.com"), Some("https://cms.example.com")),
            (Some("https://cms.example.com/"), Some("https://cms.example.com")),
            (Some("  https://cms.example.com/  "), Some("https://cms.example.com")),
            (Some("http://localhost:8080"), Some("http://localhost:8080")),
            (Some("/"), None)
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match (raw, _) -> publicOriginOf(raw)))

}
