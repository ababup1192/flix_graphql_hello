///
/// entry の下書きを読み書きするユースケース。生成された EntriesQueries を並べる層。
/// 中身の検証は EntryValidation（下書きは緩い）、行と値の変換は EntryRows。
/// 公開（published の行と参照先の検査）はステップ 5。
///
mod ContentEntries {

    // ---- 読む ----

    ///
    /// 型の entry の一覧。更新が新しい順。search が空なら全件。SQL は 2 本（一覧と件数）。
    ///
    pub def list(typeId: TypeId, page: EntryQuery): EntryPage \ DbRead =
        let owner = TypeId.toInt64(typeId);
        let needle = EntrySearch.escapeLike(page#search);
        let entries = EntriesQueries.listEntries({ typeId = owner, search = needle, limit = Int32.toInt64(page#first), offset = Int32.toInt64(page#skip) })
            |> List.map(EntryRows.toEntry);
        let total = EntriesQueries.countEntries({ typeId = owner, search = needle }) |> Option.flatMap(row -> row#total) |> Option.getWithDefault(0i64);
        { entries = entries, totalCount = total }

    ///
    /// id で 1 つ。無ければ（ゴミ箱の物も）None。
    ///
    pub def find(id: EntryId): Option[Entry] \ DbRead =
        EntriesQueries.findEntry(EntryId.text(id)) |> Option.map(EntryRows.toEntry)

    ///
    /// id で 1 つ。無ければ notFound。
    ///
    pub def get(id: EntryId): Entry \ DbRead + CmsErr =
        find(id) |> CmsErr.orNotFound(Entity.Entry, EntryId.text(id))

    ///
    /// 型の entry の数（ゴミ箱を除く）。型を消せるかの判断に使う。
    ///
    pub def countOfType(typeId: TypeId): Int64 \ DbRead =
        EntriesQueries.countEntriesOfType(TypeId.toInt64(typeId)) |> Option.flatMap(row -> row#total) |> Option.getWithDefault(0i64)

    // ---- 書く ----

    ///
    /// 下書きを作る。id を渡せば（移行用）それを使い、無ければ振る。中身が型に合わなければ invalid。
    /// id はゴミ箱の物とも重ねられない（PK が残っている）。
    ///
    pub def create(typeId: TypeId, given: Option[EntryId], data: EntryData): Entry \ Db + CmsErr + IdGen =
        let owner = ContentTypes.get(typeId);
        CmsErr.raiseIfAny(EntryValidation.draft(owner#fields, data));
        let id = given |> Option.getWithDefault(IdGen.freshEntryId());
        let taken = EntriesQueries.entryExists(EntryId.text(id)) |> Option.nonEmpty;
        CmsErr.raiseIfAny(if (taken) Violation.Violation("id", "'${id}' は既にあります（ゴミ箱の物を含む）") :: Nil else Nil);
        discard EntriesQueries.insertEntry({ id = EntryId.text(id), typeId = TypeId.toInt64(typeId) });
        discard EntriesQueries.upsertContent({ entryId = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Draft), data = EntryRows.dataToJson(data) });
        get(id)

    ///
    /// 下書きを直す。patch のキーだけ上書きし、null で消す。expectedVersion が今の版と違えば conflict。
    ///
    pub def update(id: EntryId, patch: EntryData, expectedVersion: Int32): Entry \ Db + CmsErr =
        let existing = get(id);
        if (existing#version != expectedVersion) CmsErr.conflict(Entity.Entry, EntryId.text(id), existing#version) else ();
        let owner = ContentTypes.get(existing#typeId);
        let merged = EntryValidation.merge(existing#data, patch);
        CmsErr.raiseIfAny(EntryValidation.draft(owner#fields, merged));
        discard EntriesQueries.upsertContent({ entryId = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Draft), data = EntryRows.dataToJson(merged) });
        let advanced = EntriesQueries.bumpEntryVersion({ id = EntryId.text(id), expected = expectedVersion });
        if (advanced == 0) CmsErr.conflict(Entity.Entry, EntryId.text(id), existing#version + 1) else ();
        get(id)

    ///
    /// ゴミ箱へ。無ければ notFound。
    ///
    pub def delete(id: EntryId): Unit \ Db + CmsErr =
        discard get(id);
        discard EntriesQueries.softDeleteEntry(EntryId.text(id))

}
