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

    // ---- コンテンツ API（stage の行を読む）----

    ///
    /// stage の行を id で 1 つ。その stage の中身が無ければ（未公開など）None。
    ///
    pub def findByStage(id: EntryId, stage: Stage): Option[Entry] \ DbRead =
        EntriesQueries.findEntryByStage({ id = EntryId.text(id), stage = EntryRows.stageToDb(stage) }) |> Option.map(EntryRows.toEntry)

    ///
    /// stage の行の一覧。絞り込みと並び順は EntryFilterSql が SQL にする。SQL は 2 本（一覧と件数）。
    ///
    pub def listByStage(owner: ContentType, stage: Stage, listQuery: ListQuery): EntryPage \ DbRead =
        let typeId = TypeId.toInt64(owner#id);
        let stageText = EntryRows.stageToDb(stage);
        let filter = EntryFilterSql.pred(listQuery#filter);
        let entries = EntriesQueries.listEntriesByStage(
            { typeId = typeId, stage = stageText, limit = Int32.toInt64(listQuery#first), offset = Int32.toInt64(listQuery#skip) },
            filter, EntryFilterSql.order(owner#fields, listQuery#orderBy)) |> List.map(EntryRows.toEntry);
        let total = EntriesQueries.countEntriesByStage({ typeId = typeId, stage = stageText }, filter) |> Option.flatMap(row -> row#total) |> Option.getWithDefault(0i64);
        { entries = entries, totalCount = total }

    ///
    /// singleton 用。stage の行を 1 つだけ（更新が新しい物）。
    ///
    pub def firstByStage(owner: ContentType, stage: Stage): Option[Entry] \ DbRead =
        listByStage(owner, stage, { filter = Nil, orderBy = Nil, first = 1, skip = 0 }) |> (page -> List.head(page#entries))

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
    /// ゴミ箱へ。無ければ notFound。公開中なら公開も取り下げる（公開側から消え、一意の値も空く）。
    ///
    pub def delete(id: EntryId): Unit \ Db + CmsErr =
        let existing = get(id);
        if (existing#stage == Stage.Published) discard unpublish(id) else ();
        discard EntriesQueries.softDeleteEntry(EntryId.text(id))

    // ---- 公開 ----

    ///
    /// 下書きを公開する。required と unique を検査し、draft の行を published の行へ写し、版を積む。
    /// 既に公開中なら公開側を下書きで上書きする（再公開）。
    ///
    pub def publish(id: EntryId, author: String): Entry \ Db + CmsErr =
        let existing = get(id);
        let owner = ContentTypes.get(existing#typeId);
        CmsErr.raiseIfAny(EntryValidation.publish(owner#fields, existing#data) ::: uniqueViolations(owner, existing));
        discard EntriesQueries.deleteUniquesOfEntry(EntryId.text(id));
        List.forEach(match (field, value) -> discard EntriesQueries.insertUnique({ typeId = TypeId.toInt64(owner#id), fieldId = FieldId.toInt64(field#id), value = value, entryId = EntryId.text(id) }), uniqueValues(owner, existing));
        discard EntriesQueries.upsertContent({ entryId = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Published), data = EntryRows.dataToJson(existing#data) });
        discard EntriesQueries.insertVersion({ entryId = EntryId.text(id), version = existing#version, data = EntryRows.dataToJson(existing#data), author = author, reason = EntryRows.reasonToDb(VersionReason.Publish) });
        discard EntriesQueries.markPublished(EntryId.text(id));
        get(id)

    ///
    /// 公開を取り下げる。published の行と一意の値を消す。下書きは残る。未公開なら何もしない。
    ///
    pub def unpublish(id: EntryId): Entry \ Db + CmsErr =
        discard get(id);
        discard EntriesQueries.deleteContent({ entryId = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Published) });
        discard EntriesQueries.deleteUniquesOfEntry(EntryId.text(id));
        discard EntriesQueries.markUnpublished(EntryId.text(id));
        get(id)

    ///
    /// unique なフィールドの (フィールド, 値の文字列)。値が無いフィールドは含めない。
    ///
    def uniqueValues(owner: ContentType, entry: Entry): List[(FieldDef, String)] =
        owner#fields |> List.filter(field -> field#unique) |> List.filterMap(field ->
            Map.get(field#apiId, entry#data) |> Option.flatMap(EntryRows.uniqueValueText) |> Option.map(value -> (field, value)))

    ///
    /// 他の公開中の entry が同じ値を持っていれば違反。自分の値は構わない（再公開）。
    ///
    def uniqueViolations(owner: ContentType, entry: Entry): List[Violation] \ DbRead =
        uniqueValues(owner, entry) |> List.filterMap(match (field, value) ->
            EntriesQueries.findUniqueOwner({ typeId = TypeId.toInt64(owner#id), fieldId = FieldId.toInt64(field#id), value = value })
                |> Option.map(row -> row#entryId)
                |> Option.filter(holder -> holder != EntryId.text(entry#id))
                |> Option.map(holder -> Violation.Violation("fields.${field#apiId}", "'${value}' は公開中の entry '${holder}' が使っています")))

    // ---- 版 ----

    ///
    /// entry の版。新しい順。
    ///
    pub def versions(id: EntryId): List[EntryVersion] \ DbRead =
        EntriesQueries.listVersions(EntryId.text(id)) |> List.map(EntryRows.toVersion)

    ///
    /// 今の下書きを版として積む。
    ///
    pub def saveVersion(id: EntryId, author: String): EntryVersion \ Db + CmsErr =
        let existing = get(id);
        let inserted = EntriesQueries.insertVersion({ entryId = EntryId.text(id), version = existing#version, data = EntryRows.dataToJson(existing#data), author = author, reason = EntryRows.reasonToDb(VersionReason.Save) })
            |> Option.map(row -> row#id);
        match inserted {
            case Some(number) => EntriesQueries.findVersion(number) |> Option.map(EntryRows.toVersion) |> CmsErr.orNotFound(Entity.Version, "${number}")
            case None         => DbErr.other("INSERT ... RETURNING returned no row")
        }

    ///
    /// 版の中身を下書きに戻す。版が他の entry の物なら notFound。expectedVersion は update と同じ楽観ロック。
    ///
    pub def restoreVersion(id: EntryId, versionId: VersionId, expectedVersion: Int32): Entry \ Db + CmsErr =
        let found = EntriesQueries.findVersion(VersionId.toInt64(versionId)) |> Option.map(EntryRows.toVersion)
            |> Option.filter(version -> version#entryId == id)
            |> CmsErr.orNotFound(Entity.Version, "${versionId}");
        let existing = get(id);
        if (existing#version != expectedVersion) CmsErr.conflict(Entity.Entry, EntryId.text(id), existing#version) else ();
        let owner = ContentTypes.get(existing#typeId);
        CmsErr.raiseIfAny(EntryValidation.draft(owner#fields, found#data));
        discard EntriesQueries.upsertContent({ entryId = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Draft), data = EntryRows.dataToJson(found#data) });
        let advanced = EntriesQueries.bumpEntryVersion({ id = EntryId.text(id), expected = expectedVersion });
        if (advanced == 0) CmsErr.conflict(Entity.Entry, EntryId.text(id), existing#version + 1) else ();
        get(id)

}
