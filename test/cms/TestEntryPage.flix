///
/// EntryPage: ページの丸めと件数の Int32 化、first + 1 件からの切り詰め、endCursor / edges。純粋。
///
mod TestEntryPage {

    /// first は省けば default、0 は 0（件数だけ）、負は 0、200 超は 200。skip は省けば 0、負は 0。
    @Test
    def testEntryPageClamp(): Unit \ Assert =
        Assert.assertEq(expected = ((20, 0), (0, 0), (0, 0), (200, 0), (20, 0), (7, 3)),
            (EntryPage.clamp(20, None, None), EntryPage.clamp(20, Some(0), None), EntryPage.clamp(20, Some(-1), None), EntryPage.clamp(20, Some(1000), None),
             EntryPage.clamp(20, None, Some(-5)), EntryPage.clamp(20, Some(7), Some(3))))

    def page(entries: List[Entry], total: Int64): EntryPage = { entries = entries, cursors = Nil, totalCount = total, hasNextPage = false }

    /// Int32 に載らない件数は上限に丸める。
    @Test
    def testEntryPageTotalCountInt32(): Unit \ Assert =
        Assert.assertEq(expected = (3, Int32.maxValue()),
            (EntryPage.totalCountInt32(page(Nil, 3i64)), EntryPage.totalCountInt32(page(Nil, 5000000000i64))))

    /// first + 1 件引いた行の切り詰め。0 件 / first 未満 / ちょうど first / first + 1 で、first を超えた分だけ落ち、超えていれば次がある。
    @Test
    def testEntryPageTrimPage(): Unit \ Assert =
        let cases = List#{
            ((3, (Nil: List[String])),               ((Nil: List[String]), false)),
            ((3, List#{"a"}),                        (List#{"a"}, false)),
            ((3, List#{"a", "b", "c"}),              (List#{"a", "b", "c"}, false)),
            ((3, List#{"a", "b", "c", "d"}),         (List#{"a", "b", "c"}, true)),
            ((0, List#{"a"}),                        ((Nil: List[String]), true))
        };
        Assert.assertEq(
            expected = cases |> List.map(match (given, outcome) -> (given, outcome)),
            cases |> List.map(match (given, _) -> { let (first, rows) = given; (given, EntryPage.trimPage(first, rows)) }))

    /// endCursor は cursors の末尾、空なら None。
    @Test
    def testEntryPageEndCursor(): Unit \ Assert =
        Assert.assertEq(expected = (Some("c2"), None),
            (EntryPage.endCursor({ cursors = List#{"c1", "c2"} | page(Nil, 2i64) }), EntryPage.endCursor(page(Nil, 0i64))))

}
