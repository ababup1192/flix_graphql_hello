///
/// リンクカードの取得に使う User-Agent。
///
mod TestLinkCards {

    /// プロジェクト名の日本語と記号は落とす。ヘッダに入れられる文字だけ残す。
    @Test
    def testUserAgentKeepsAsciiOnly(): Unit \ Assert =
        let cases = List#{
            ("blog", "flix-cms-linkcard/1.0 (+blog)"),
            ("Blog Example 2026", "flix-cms-linkcard/1.0 (+Blog Example 2026)"),
            ("ブログの作例", "flix-cms-linkcard/1.0"),
            ("blog ブログ", "flix-cms-linkcard/1.0 (+blog)"),
            ("a(b)c", "flix-cms-linkcard/1.0 (+abc)"),
            ("", "flix-cms-linkcard/1.0"),
            ("   ", "flix-cms-linkcard/1.0"),
            ("line\nbreak", "flix-cms-linkcard/1.0 (+linebreak)")
        };
        Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(fst >> LinkCards.userAgent))

}
