///
/// DateValues: DATE の値の形。保存できるのは UTC の ISO 8601 ちょうど 1 通り。純粋。
///
mod TestDateValues {

    /// 受けるのは `2026-09-09T00:00:00Z` の形ちょうど。offset 付き・ミリ秒付き・秒なし・0 詰めなし・空白の区切り・日付だけは断る。
    @Test
    def testDateValuesIsCanonicalShape(): Unit \ Assert =
        let cases = List#{
            ("2026-09-09T00:00:00Z",      true),
            ("2026-09-09T09:00:00+09:00", false),
            ("2026-09-09T00:00:00.000Z",  false),
            ("2026-09-09T00:00Z",         false),
            ("2026-9-9T0:00:00Z",         false),
            ("2026-09-09 00:00:00Z",      false),
            ("2026-09-09",                false),
            ("2026-09-09T00:00:00z",      false),
            ("2026-09-09T00:00:00",       false),
            (" 2026-09-09T00:00:00Z",     false),
            ("2026-09-09T00:00:00Z ",     false),
            ("",                          false)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateValues.isCanonical(text))))

    /// 桁が合っていても暦として読めない値は断る。うるう日は年で変わり、月・日の範囲外・24 時・うるう秒の :60 は無い。
    @Test
    def testDateValuesIsCanonicalCalendar(): Unit \ Assert =
        let cases = List#{
            ("2024-02-29T00:00:00Z", true),
            ("2023-02-29T00:00:00Z", false),
            ("2026-13-01T00:00:00Z", false),
            ("2026-00-01T00:00:00Z", false),
            ("2026-09-31T00:00:00Z", false),
            ("2026-09-00T00:00:00Z", false),
            ("2026-09-09T24:00:00Z", false),
            ("2026-09-09T23:59:59Z", true),
            ("2026-06-30T23:59:60Z", false),
            ("2026-09-09T00:60:00Z", false)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateValues.isCanonical(text))))

    /// 送るべき値。直せる物（offset 付き・ミリ秒付き・秒なし・日付だけ）は UTC の秒までの形になり、読めない物は None。
    /// 既に正しい形の物はそのまま（往復して変わらない）。
    @Test
    def testDateValuesCanonical(): Unit \ Assert =
        let cases = List#{
            ("2026-09-09T00:00:00Z",      Some("2026-09-09T00:00:00Z")),
            ("2026-09-09T09:00:00+09:00", Some("2026-09-09T00:00:00Z")),
            ("2026-09-09T00:00:00.000Z",  Some("2026-09-09T00:00:00Z")),
            ("2026-09-09T00:00:00.750Z",  Some("2026-09-09T00:00:00Z")),
            ("2026-09-09T00:00Z",         Some("2026-09-09T00:00:00Z")),
            ("2026-09-09",                Some("2026-09-09T00:00:00Z")),
            ("1969-12-31T23:59:59.500Z",  Some("1969-12-31T23:59:59Z")),
            ("2026-9-9T0:00:00Z",         None),
            ("2026-09-09 00:00:00Z",      None),
            ("2023-02-29",                None),
            ("someday",                   None),
            ("",                          None)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateValues.canonical(text))))

    /// 断る言い分。直せる値には直した形を載せ、読めない値には受け取った値だけを載せる。
    @Test
    def testDateValuesRejection(): Unit \ Assert =
        let cases = List#{
            ("2026-09-09T09:00:00+09:00",
             "'publishedOn' は UTC の日時（例: 2026-09-09T00:00:00Z）で送ってください。受け取った値: 2026-09-09T09:00:00+09:00 → 2026-09-09T00:00:00Z"),
            ("someday",
             "'publishedOn' は UTC の日時（例: 2026-09-09T00:00:00Z）で送ってください。受け取った値: someday")
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateValues.rejection("publishedOn", text))))

    /// 絞り込みの引数は保存しないので、offset 付きも日付だけも読める。offset の無い日時と桁不足は読めない。
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

    /// 日付だけの形は YYYY-MM-DD ちょうど。桁不足・時刻付き・前後の余白は違う。
    @Test
    def testDateValuesIsBareDate(): Unit \ Assert =
        let cases = List#{ ("2026-09-08", true), ("2026-9-8", false), ("2026-09-08T00:00:00Z", false), (" 2026-09-08", false), ("20260908", false) };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, DateValues.isBareDate(text))))

}
