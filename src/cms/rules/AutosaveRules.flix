///
/// 自動保存の中身と下書きを突き合わせて、持つ意味があるか・そのまま戻せるかを決める規則。純粋。
/// 書く側（置くか捨てるか）と読む側（画面に出すか）が同じ判断を使う。
///
mod AutosaveRules {

    ///
    /// 下書きと自動保存の中身が同じか、違うならそのまま戻せるか。
    ///
    /// WhyNot: 時刻（updated_at）で新しい方を選ばない。明示的な保存と自動保存は別の Tx で走り、
    /// 3 秒の周期の中では時刻の前後が編集の前後と一致しない。版（entries.version）なら
    /// 「下書きが進んだか」がそのまま読める。
    ///
    pub def stateOf(draftVersion: Int32, baseVersion: Int32, draft: EntryData, saved: EntryData): AutosaveState =
        if (draft == saved) AutosaveState.SameAsDraft
        else if (baseVersion == draftVersion) AutosaveState.Restorable
        else AutosaveState.Outdated

    ///
    /// 置き場に残す（画面に出す）か。
    ///
    pub def keepable(state: AutosaveState): Bool = match state {
        case AutosaveState.SameAsDraft => false
        case AutosaveState.Restorable  => true
        case AutosaveState.Outdated    => true
    }

}
