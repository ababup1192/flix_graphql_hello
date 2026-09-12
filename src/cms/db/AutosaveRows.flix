///
/// entry_autosaves の行とドメインの値のあいだの変換。状態は読んだ時の下書きと突き合わせて決める。
///
mod AutosaveRows {

    ///
    /// 行から預かり物へ。下書きとの突き合わせ（state）は読んだ側が `EntryAutosaves.attach` でする。
    ///
    pub def toStored(row: { data = Util.Json.Json, baseVersion = Int32, updatedAt = Timestamp.Timestamp | r }): StoredAutosave \ DbErr =
        { data = EntryRows.dataFromJson(row#data), baseVersion = row#baseVersion, updatedAt = row#updatedAt }

}
