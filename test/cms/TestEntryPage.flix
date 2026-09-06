///
/// EntryPage: ページの丸めと件数の Int32 化。純粋。
///
mod TestEntryPage {

    /// first は省けば default、0 は 0（件数だけ）、負は 0、200 超は 200。skip は省けば 0、負は 0。
    @Test
    def testEntryPageClamp(): Unit \ Assert =
        Assert.assertEq(expected = ((20, 0), (0, 0), (0, 0), (200, 0), (20, 0), (7, 3)),
            (EntryPage.clamp(20, None, None), EntryPage.clamp(20, Some(0), None), EntryPage.clamp(20, Some(-1), None), EntryPage.clamp(20, Some(1000), None),
             EntryPage.clamp(20, None, Some(-5)), EntryPage.clamp(20, Some(7), Some(3))))

    /// Int32 に載らない件数は上限に丸める。
    @Test
    def testEntryPageTotalCountInt32(): Unit \ Assert =
        Assert.assertEq(expected = (3, Int32.maxValue()),
            (EntryPage.totalCountInt32({ entries = Nil, totalCount = 3i64 }), EntryPage.totalCountInt32({ entries = Nil, totalCount = 5000000000i64 })))

}
