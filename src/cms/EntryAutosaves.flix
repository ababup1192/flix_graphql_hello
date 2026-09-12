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
    pub def save(proof: Granted[WriteEntries], id: EntryId, given: EntryData): Option[EntryAutosave] \ Db + CmsErr + Tenant + Session =
        let userId = Session.currentUser();
        let existing = ContentEntries.get(Session.readDraftOfWriter(proof), id);
        let stored = { data = given, baseVersion = existing#version, updatedAt = existing#updatedAt };
        match attach(existing, stored) {
            case Some(autosave) => {
                discard EntryAutosavesQueries.upsertAutosave({
                    entryId = EntryId.text(id), userId = UserId.toInt64(userId), projectId = Tenant.currentId(),
                    data = EntryRows.dataToJson(given), baseVersion = existing#version });
                Some(autosave)
            }
            case None => { clearOwn(userId, id); None }
        }

    ///
    /// 預かり物を下書きと突き合わせて、画面に出す形にする。同じ中身なら None。純粋。
    ///
    pub def attach(entry: Entry, stored: StoredAutosave): Option[EntryAutosave] =
        let state = AutosaveRules.stateOf(entry#version, stored#baseVersion, entry#data, stored#data);
        if (AutosaveRules.keepable(state))
            Some({ entryId = entry#id, data = stored#data, baseVersion = stored#baseVersion, state = state, updatedAt = stored#updatedAt })
        else None

    ///
    /// 自分の預かり物（下書きと突き合わせる前の生の物）。人でない主体（API キー・匿名・プレビュー・system）は
    /// 置き場を持たないので常に None（forbidden にはしない。entry を読むだけで落ちるため）。
    ///
    pub def stored(_proof: Granted[WriteEntries], id: EntryId): Option[StoredAutosave] \ DbRead + Tenant + Session =
        match Session.currentUserForRead() {
            case None         => None
            case Some(userId) =>
                EntryAutosavesQueries.findAutosave({ entryId = EntryId.text(id), userId = UserId.toInt64(userId), projectId = Tenant.currentId() })
                    |> Option.map(AutosaveRows.toStored)
        }

    ///
    /// 複数の entry の預かり物を 1 本の SELECT で（管理 API の一覧の先読み）。
    /// 渡した id は預かり物が無くても None で載る（写しが「引いた」と「まだ引いていない」を区別できるように）。
    ///
    pub def storedOf(_proof: Granted[WriteEntries], ids: List[EntryId]): Map[EntryId, Option[StoredAutosave]] \ DbRead + Tenant + Session =
        let empty = ids |> List.map(id -> (id, None)) |> List.toMap;
        match Session.currentUserForRead() {
            case None         => empty
            case Some(userId) => if (List.isEmpty(ids)) empty else Map.union(fetchMany(userId, ids), empty)
        }

    /// storedOf の本体。行を id で引き当てる。
    def fetchMany(userId: UserId, ids: List[EntryId]): Map[EntryId, Option[StoredAutosave]] \ DbRead + Tenant =
        EntryAutosavesQueries.findAutosavesOf({
                entryIds = ids |> List.map(EntryId.text),
                userId = UserId.toInt64(userId), projectId = Tenant.currentId() })
            |> List.filterMap(rowEntry)
            |> List.toMap

    /// 1 行を (entry id, 預かり物)。id の規則に合わない行は落とす（PK が entries.id なので起きない）。
    def rowEntry(row: { entryId = String, userId = Int64, data = Util.Json.Json, baseVersion = Int32, updatedAt = Timestamp.Timestamp }): Option[(EntryId, Option[StoredAutosave])] \ DbErr =
        // WhyNot: Option.map のラムダに畳み込まないのは、effect（DbErr）を使う式をラムダに直に書くと JVM の VerifyError になるため
        match EntryId.parse(row#entryId) {
            case None     => None
            case Some(id) => Some((id, Some(AutosaveRows.toStored(row))))
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
    /// WhyNot: 明示的な保存・公開・取り下げでは全員分を捨てない。どれも他の人の預かり物を無効にする操作ではなく、
    /// 消すとその人の打鍵が黙って失われる。下書きが進んだ事は `AutosaveState.Outdated` で相手に見せる。
    /// 保存した本人の預かり物は、保存した中身と同じになるので次の自動保存が `SameAsDraft` で捨てる。
    ///
    pub def purge(_proof: Granted[WriteEntries], id: EntryId): Unit \ DbWrite + Tenant =
        discard EntryAutosavesQueries.deleteAutosavesOfEntry({ entryId = EntryId.text(id), projectId = Tenant.currentId() })

}
