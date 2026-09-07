///
/// DateValues: DATE の値の読み方と、書く時の形。純粋。
///
mod TestDateValues {

    /// 読める物と読めない物。うるう日は年で変わり、13 月・桁不足・offset の無い日時・空は None。日時は UTC に直して読める。
    @Test
    def testDateValuesParse(): Unit \ Assert =
        let cases = List#{
            ("2024-02-29",                Some("2024-02-29T00:00:00Z")),
            ("2023-02-29",                None),
            ("2026-13-01",                None),
            ("2026-09-31",                None),
            ("2026-9-8",                  None),
            ("2026-09-08T18:00:00+09:00", Some("2026-09-08T09:00:00Z")),
            ("2026-09-08T09:00:00Z",      Some("2026-09-08T09:00:00Z")),
            ("2026-09-08T09:00:00",       None),
            ("",                          None)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateValues.parse(text) |> Option.map(Timestamp.toIso8601))))

    /// 日付だけは UTC の 0 時の日時になり、時刻付きは offset ごとそのまま。日付の形でない物もそのまま。
    /// 形だけ見るので、13 月のような読めない日付にも 0 時が付く（読めない事は parse が言う）。
    @Test
    def testDateValuesNormalize(): Unit \ Assert =
        let cases = List#{
            ("2026-09-08",                "2026-09-08T00:00:00Z"),
            ("2026-09-08T18:00:00+09:00", "2026-09-08T18:00:00+09:00"),
            ("2026-09-08T09:00:00Z",      "2026-09-08T09:00:00Z"),
            ("2026-13-01",                "2026-13-01T00:00:00Z"),
            ("2026-9-8",                  "2026-9-8"),
            ("someday",                   "someday")
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateValues.normalize(text))))

    /// 日付だけの形は YYYY-MM-DD ちょうど。桁不足・時刻付き・前後の余白は違う。
    @Test
    def testDateValuesIsBareDate(): Unit \ Assert =
        let cases = List#{ ("2026-09-08", true), ("2026-9-8", false), ("2026-09-08T00:00:00Z", false), (" 2026-09-08", false), ("20260908", false) };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateValues.isBareDate(text))))

}
