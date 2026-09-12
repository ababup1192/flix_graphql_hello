///
/// entry_autosaves の行とドメインの値のあいだの変換。状態は読んだ時の下書きと突き合わせて決める。
///
mod AutosaveRows {

    ///
    /// 行と、同じ entry の下書きから Autosave を組む。
    ///
    pub def toAutosave(entry: Entry, row: { entryId = String, data = Util.Json.Json, baseVersion = Int32, updatedAt = Timestamp.Timestamp | r }): Autosave \ DbErr =
        let data = EntryRows.dataFromJson(row#data);
        {
            entryId     = entry#id,
            data        = data,
            baseVersion = row#baseVersion,
            state       = AutosaveRules.stateOf(entry#version, row#baseVersion, entry#data, data),
            updatedAt   = row#updatedAt
        }

}
