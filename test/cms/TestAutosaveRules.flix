///
/// AutosaveRules: 自動保存の中身と下書きを見て、持つ意味があるか・そのまま戻せるかを決める。純粋。
///
mod TestAutosaveRules {

    use Util.Json.Json

    def data(pairs: List[(String, Json)]): EntryData = CmsTestKit.entryData(pairs)

    def title(text: String): EntryData = data(List#{ ("title", Json.JString(text)) })

    ///
    /// (下書きの version, 基にした version, 下書きの中身, 自動保存の中身) → 状態。
    ///
    ///   中身が同じ                 → SameAsDraft（版が揃っていてもずれていても）
    ///   中身が違い版が揃っている   → Restorable
    ///   中身が違い版がずれている   → Outdated（読んでから書くまでに誰かが下書きを保存した）
    ///
    @Test
    def testStateOf(): Unit \ Assert =
        let cases = List#{
            ((3, 3, title("a"), title("a")), AutosaveState.SameAsDraft),
            ((5, 3, title("a"), title("a")), AutosaveState.SameAsDraft),
            ((3, 3, title("a"), title("b")), AutosaveState.Restorable),
            ((5, 3, title("a"), title("b")), AutosaveState.Outdated),
            ((3, 5, title("a"), title("b")), AutosaveState.Outdated),
            ((1, 1, data(Nil), title("b")), AutosaveState.Restorable),
            ((1, 1, title("a"), data(Nil)), AutosaveState.Restorable),
            ((1, 1, data(Nil), data(Nil)), AutosaveState.SameAsDraft)
        };
        Assert.assertEq(
            expected = cases,
            cases |> List.map(match (given, _) -> {
                let (draftVersion, baseVersion, draft, saved) = given;
                (given, AutosaveRules.stateOf(draftVersion, baseVersion, draft, saved))
            }))

    ///
    /// キーの並びは中身の等値に関わらない（Map なので）。同じ組を逆順に書いても SameAsDraft。
    ///
    @Test
    def testStateOfIgnoresKeyOrder(): Unit \ Assert =
        let left = data(List#{ ("title", Json.JString("a")), ("body", Json.JString("b")) });
        let right = data(List#{ ("body", Json.JString("b")), ("title", Json.JString("a")) });
        Assert.assertEq(expected = AutosaveState.SameAsDraft, AutosaveRules.stateOf(1, 1, left, right))

    ///
    /// 画面に出すのは下書きと違う物だけ。SameAsDraft は None（明示的な保存の直後に走った
    /// 自動保存で「未保存の変更があります」と出さない）。
    ///
    @Test
    def testKeepable(): Unit \ Assert =
        let cases = List#{
            (AutosaveState.SameAsDraft, false),
            (AutosaveState.Restorable, true),
            (AutosaveState.Outdated, true)
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (state, _) -> (state, AutosaveRules.keepable(state))))

}
