///
/// 編集中の中身を利用者ごとに預かるユースケース。下書き（entry_contents）には触らない。
///
/// **自動保存を下書きに書かない理由。** 「下書きあり」は `EntryRows.toEntry` が
/// 「公開中 かつ 下書きの中身 ≠ 公開の中身」で導くので、下書きに書けば必ず公開状態が変わり、
/// ボードのカードが列を移ってチーム全員に「未公開の変更がある」と見える。
/// 閲覧のつもりで開いて 1 文字触っただけでそうなるのを避ける。
///
/// **誰の置き場かを呼ぶ側に選ばせない。** 利用者の id は引数に無く、必ず今の主体から取る
/// （`Session.currentUser()` / `Session.currentUserForRead()`）ので、他人の置き場を名指しできる形が無い。
/// DB 側も RLS（030_entry_autosaves.sql）が自分の行しか見せない。
///
/// pub の入口は `Granted[WriteEntries]` を最初の引数で受ける（自動保存はその entry を書ける人の物）。
///
mod EntryAutosaves {

    ///
    /// 編集中の中身を自分の置き場に預かる。下書きと同じ中身なら置かずに捨てて None
    /// （明示的に保存した直後に走った自動保存で「未保存の変更があります」と出さないため）。
    ///
    /// WhyNot: 中身を型の定義で削らない（`EntryValidation.prune`）し、下書きの検査（`EntryValidation.draft`）も通さない。
    /// 3 秒ごとに来る預かり物で、打っている途中の値（"1." のような数値）で失敗すると打鍵が消える。
    /// ここは配信にも一覧にも出ない預かり場で、検査は明示的な保存（`ContentEntries.update`）が持つ。
    ///
    /// WhyNot: patch として重ねない（`update` は重ねる）。画面は編集中の中身を丸ごと送るので、
    /// 重ねるとフィールドを空にした編集が預かり物に残らない。
    ///
    pub def save(proof: Granted[WriteEntries], id: EntryId, given: EntryData): Option[Autosave] \ Db + CmsErr + Tenant + Session =
        let userId = Session.currentUser();
        let existing = ContentEntries.get(Session.readDraftOfWriter(proof), id);
        let state = AutosaveRules.stateOf(existing#version, existing#version, existing#data, given);
        if (AutosaveRules.keepable(state)) {
            discard EntryAutosavesQueries.upsertAutosave({
                entryId = EntryId.text(id), userId = UserId.toInt64(userId), projectId = Tenant.currentId(),
                data = EntryRows.dataToJson(given), baseVersion = existing#version });
            Some({ entryId = id, data = given, baseVersion = existing#version, state = state, updatedAt = existing#updatedAt })
        } else {
            clearOwn(userId, id);
            None
        }

    ///
    /// 読み込み済みの entry に付く自分の預かり物。下書きと同じ中身になっていれば None。
    /// 人でない主体（API キー・匿名・プレビュー・system）は置き場を持たないので常に None。
    ///
    pub def of(_proof: Granted[WriteEntries], entry: Entry): Option[Autosave] \ DbRead + Tenant + Session =
        match Session.currentUserForRead() {
            case None         => None
            case Some(userId) =>
                EntryAutosavesQueries.findAutosave({ entryId = EntryId.text(entry#id), userId = UserId.toInt64(userId), projectId = Tenant.currentId() })
                    |> Option.map(AutosaveRows.toAutosave(entry))
                    |> Option.filter(autosave -> AutosaveRules.keepable(autosave#state))
        }

    ///
    /// 複数の entry の預かり物を 1 本の SELECT で（管理 API の一覧の先読み）。
    /// 返るのは置き場に残る（下書きと違う）物だけで、無い entry はキーごと落ちる。
    ///
    pub def ofMany(_proof: Granted[WriteEntries], entries: List[Entry]): Map[EntryId, Autosave] \ DbRead + Tenant + Session =
        match Session.currentUserForRead() {
            case None         => Map.empty()
            case Some(userId) => if (List.isEmpty(entries)) Map.empty() else fetchMany(userId, entries)
        }

    /// ofMany の本体。行を entry で引き当てて状態を付ける。
    def fetchMany(userId: UserId, entries: List[Entry]): Map[EntryId, Autosave] \ DbRead + Tenant =
        let byId = entries |> List.map(entry -> (entry#id, entry)) |> List.toMap;
        EntryAutosavesQueries.findAutosavesOf({
                entryIds = entries |> List.map(entry -> EntryId.text(entry#id)),
                userId = UserId.toInt64(userId), projectId = Tenant.currentId() })
            |> List.filterMap(row -> ofRow(byId, row))
            |> List.filter(match (_, autosave) -> AutosaveRules.keepable(autosave#state))
            |> List.toMap

    /// 1 行を (entry id, 預かり物) に。渡した entry に無い行は落とす（RLS と WHERE が守るので起きない）。
    def ofRow(byId: Map[EntryId, Entry], row: { entryId = String, userId = Int64, data = Util.Json.Json, baseVersion = Int32, updatedAt = Timestamp.Timestamp }): Option[(EntryId, Autosave)] \ DbErr =
        // WhyNot: forM のラムダに畳み込まないのは、effect（DbErr）を使う式をラムダに直に書くと JVM の VerifyError になるため
        match EntryId.parse(row#entryId) |> Option.flatMap(found -> Map.get(found, byId)) {
            case None        => None
            case Some(entry) => Some((entry#id, AutosaveRows.toAutosave(entry, row)))
        }

    ///
    /// 自分の預かり物を捨てる（画面の「破棄」）。無くても成功。
    ///
    pub def clear(_proof: Granted[WriteEntries], id: EntryId): Unit \ DbWrite + CmsErr + Tenant + Session =
        clearOwn(Session.currentUser(), id)

    /// 自分の行を消す。
    def clearOwn(userId: UserId, id: EntryId): Unit \ DbWrite + Tenant =
        discard EntryAutosavesQueries.deleteAutosave({ entryId = EntryId.text(id), userId = UserId.toInt64(userId), projectId = Tenant.currentId() })

    ///
    /// その entry の全員分を捨てる。戻す先が無くなった時（ゴミ箱へ入れた時）に `ContentEntries.delete` が呼ぶ。
    ///
    /// WhyNot: 明示的な保存・公開・取り下げでは全員分を捨てない。どれも他の人の預かり物を消す操作ではなく、
    /// 消すとその人の打鍵が黙って失われる。下書きが進んだ事は `AutosaveState.Outdated` で相手に見せる。
    /// 保存した本人の預かり物だけは、保存した中身と同じになるので次の自動保存が `SameAsDraft` で捨てる。
    ///
    pub def purge(_proof: Granted[WriteEntries], id: EntryId): Unit \ DbWrite + Tenant =
        discard EntryAutosavesQueries.deleteAutosavesOfEntry({ entryId = EntryId.text(id), projectId = Tenant.currentId() })

}
