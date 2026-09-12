///
/// 編集中の中身の、利用者ごとの置き場（entry_autosaves の 1 行）。
///
/// 下書き（entry_contents の draft の行）とは別の表で、書いても entries.version も
/// changedSincePublish も動かない。読めるのは置いた本人だけ。
///
/// - entryId: どの entry の物か
/// - data: 預かった中身（そのまま。型の定義で削らない）
/// - baseVersion: 預かった時の entries.version
/// - state: 下書きと突き合わせた状態
/// - updatedAt: 最後に預かった時刻
///
pub type alias Autosave = {
    entryId = EntryId,
    data = EntryData,
    baseVersion = Int32,
    state = AutosaveState,
    updatedAt = Timestamp.Timestamp
}

///
/// 自動保存と下書きの関係。判定は `AutosaveRules.stateOf`。
///
pub enum AutosaveState with Eq, Order, ToString {
    /// 下書きと同じ中身。持つ意味が無いので置き場から消す（画面にも出さない）
    case SameAsDraft
    /// 下書きと違い、預かった時から下書きが進んでいない。そのまま戻せる
    case Restorable
    /// 下書きと違い、預かった後に下書きが進んだ（他の人か他のタブが保存した）。戻すと相手の保存を潰す
    case Outdated
}
