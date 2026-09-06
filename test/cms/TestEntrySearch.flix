///
/// EntrySearch: LIKE のエスケープ。
///

/// % と _ と \ はそのままの文字として当たるようにエスケープされ、他は変わらない。
@Test
def testEntrySearchEscapeLike(): Unit \ Assert =
    Assert.assertEq(expected = ("100\\%", "a\\_b", "c:\\\\d", "flix"),
        (EntrySearch.escapeLike("100%"), EntrySearch.escapeLike("a_b"), EntrySearch.escapeLike("c:\\d"), EntrySearch.escapeLike("flix")))
