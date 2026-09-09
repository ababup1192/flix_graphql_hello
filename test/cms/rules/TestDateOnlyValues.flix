///
/// DateOnlyValues: DATE_ONLY の値の形。保存できるのは `2026-09-09` ちょうど 1 通り。純粋。
///
mod TestDateOnlyValues {

    /// 受けるのは `2026-09-09` の形ちょうど。時刻付き・ゼロ詰めなし・桁足らず・区切り違い・前後の余白は断る。
    @Test
    def testDateOnlyValuesIsCanonicalShape(): Unit \ Assert =
        let cases = List#{
            ("2026-09-09",           true),
            ("2026-09-09T00:00:00Z", false),
            ("2026-9-9",             false),
            ("2026-09-9",            false),
            ("26-09-09",             false),
            ("2026/09/09",           false),
            ("20260909",             false),
            (" 2026-09-09",          false),
            ("2026-09-09 ",          false),
            ("",                     false)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateOnlyValues.isCanonical(text))))

    /// 桁が合っていても暦として読めない値は断る。うるう日は年で変わり、月 13・月 0・日 32・日 0・9 月 31 日は無い。
    @Test
    def testDateOnlyValuesIsCanonicalCalendar(): Unit \ Assert =
        let cases = List#{
            ("2024-02-29", true),
            ("2023-02-29", false),
            ("2000-02-29", true),
            ("1900-02-29", false),
            ("2026-13-01", false),
            ("2026-00-01", false),
            ("2026-01-32", false),
            ("2026-01-00", false),
            ("2026-09-31", false),
            ("2026-12-31", true)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateOnlyValues.isCanonical(text))))

    /// 送るべき値。時刻付きは UTC で見た日付になり、日付だけはそのまま（往復して変わらない）。読めない物は None。
    @Test
    def testDateOnlyValuesCanonical(): Unit \ Assert =
        let cases = List#{
            ("2026-09-09",                Some("2026-09-09")),
            ("2026-09-09T00:00:00Z",      Some("2026-09-09")),
            ("2026-09-09T23:59:59Z",      Some("2026-09-09")),
            ("2026-09-09T09:00:00+09:00", Some("2026-09-09")),
            ("2026-09-09T00:00:00+09:00", Some("2026-09-08")),
            ("2026-09-09T00:00:00.000Z",  Some("2026-09-09")),
            ("2026-9-9",                  None),
            ("2023-02-29",                None),
            ("someday",                   None),
            ("",                          None)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateOnlyValues.canonical(text))))

    /// 断る言い分。直せる値には直した形を載せ、読めない値には受け取った値だけを載せる。
    @Test
    def testDateOnlyValuesRejection(): Unit \ Assert =
        let cases = List#{
            ("2026-09-09T00:00:00Z", "'birthday' は日付（例: 2026-09-09）で送ってください。受け取った値: 2026-09-09T00:00:00Z → 2026-09-09"),
            ("someday",              "'birthday' は日付（例: 2026-09-09）で送ってください。受け取った値: someday")
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateOnlyValues.rejection("birthday", text))))

    /// 絞り込みの引数は保存しないので、時刻付きでも読む。日付は epoch day で比べられる。
    @Test
    def testDateOnlyValuesParseOrder(): Unit \ Assert =
        let day = text -> DateOnlyValues.parse(text) |> Option.map(Date.toEpochDay);
        Assert.assertEq(
            expected = (true, true),
            (day("2026-09-08") < day("2026-09-09"), day("2026-09-09T23:59:59Z") == day("2026-09-09")))

}
