///
/// entry の下書きと公開を読み書きするユースケース。生成された EntriesQueries を並べる層。
/// 中身の検証は EntryValidation（下書きは緩く、公開は required まで）、行と値の変換は EntryRows。
///
mod ContentEntries {

    // ---- 読む ----

    ///
    /// 型の entry の一覧（管理 API）。更新が新しい順。search が空なら全件、あればどれかの値に含む物。SQL は 2 本（一覧と件数）。
    ///
    pub def list(typeId: TypeId, entryQuery: EntryQuery): EntryPage \ DbRead + Tenant =
        let filter = if (entryQuery#search == "") Nil else Condition.AnyValueContains(entryQuery#search) :: Nil;
        page(typeId, Nil, Stage.Draft, { filter = filter, orderBy = Nil, first = entryQuery#first, skip = entryQuery#skip })

    ///
    /// id で 1 つ（下書きの中身）。無ければ（ゴミ箱の物も）None。
    ///
    pub def find(id: EntryId): Option[Entry] \ DbRead + Tenant =
        EntriesQueries.findEntryByStage({ id = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Draft), projectId = Tenant.currentId() }) |> Option.map(EntryRows.toEntry(Stage.Draft))

    ///
    /// id で 1 つ。無ければ notFound。
    ///
    pub def get(id: EntryId): Entry \ DbRead + CmsErr + Tenant =
        find(id) |> CmsErr.orNotFound(Entity.Entry, EntryId.text(id))

    // ---- コンテンツ API（stage の行を読む）----

    ///
    /// stage の行を id で 1 つ。その stage の中身が無ければ（未公開など）None。参照先は 1 段先読みする。
    ///
    pub def findByStage(owner: ContentType, id: EntryId, stage: Stage): Option[Entry] \ DbRead + Tenant =
        EntriesQueries.findEntryByStage({ id = EntryId.text(id), stage = EntryRows.stageToDb(stage), projectId = Tenant.currentId() })
            |> Option.map(EntryRows.toEntry(stage))
            |> Option.flatMap(entry -> attachLinked(owner, stage, entry :: Nil) |> List.head)

    ///
    /// stage の行の一覧。絞り込みと並び順は EntryFilterSql が SQL にする。SQL は 2 本（一覧と件数）。
    ///
    pub def listByStage(owner: ContentType, stage: Stage, listQuery: ListQuery): EntryPage \ DbRead + Tenant =
        let found = page(owner#id, owner#fields, stage, listQuery);
        { entries = attachLinked(owner, stage, found#entries) | found }

    ///
    /// singleton 用。stage の行を 1 つだけ（更新が新しい物）。件数は数えない。
    ///
    pub def firstByStage(owner: ContentType, stage: Stage): Option[Entry] \ DbRead + Tenant =
        rows(owner#id, owner#fields, stage, { filter = Nil, orderBy = Nil, first = 1, skip = 0 }) |> attachLinked(owner, stage) |> List.head

    ///
    /// stage の行の 1 ページと件数。参照の先読みはしない。
    ///
    def page(typeId: TypeId, fields: List[FieldDef], stage: Stage, listQuery: ListQuery): EntryPage \ DbRead + Tenant =
        { entries = rows(typeId, fields, stage, listQuery),
          totalCount = EntriesQueries.countEntriesByStage({ typeId = TypeId.toInt64(typeId), stage = EntryRows.stageToDb(stage), projectId = Tenant.currentId() }, EntryFilterSql.predAllowingRaw(listQuery#filter)) |> Rows.total }

    ///
    /// stage の行。絞り込みと並び順は EntryFilterSql が SQL にする。
    ///
    def rows(typeId: TypeId, fields: List[FieldDef], stage: Stage, listQuery: ListQuery): List[Entry] \ DbRead + Tenant =
        EntriesQueries.listEntriesByStage(
            { typeId = TypeId.toInt64(typeId), stage = EntryRows.stageToDb(stage), limit = Int32.toInt64(listQuery#first), offset = Int32.toInt64(listQuery#skip), projectId = Tenant.currentId() },
            EntryFilterSql.predAllowingRaw(listQuery#filter), EntryFilterSql.order(fields, listQuery#orderBy)) |> List.map(EntryRows.toEntry(stage))

    // ---- 書く ----

    ///
    /// 下書きを作る。id を渡せば（移行用）それを使い、無ければ振る。中身が型に合わなければ invalid。
    /// id はゴミ箱の物とも重ねられない（PK が残っている）。
    ///
    pub def create(typeId: TypeId, given: Option[EntryId], data: EntryData): Entry \ Db + CmsErr + IdGen + Tenant =
        let owner = ContentTypes.get(typeId);
        CmsErr.raiseIfAny(EntryValidation.draft(owner#fields, data) ::: singletonViolations(owner));
        let id = given |> Option.getWithDefault(IdGen.freshEntryId());
        let taken = EntriesQueries.entryExists(EntryId.text(id)) |> Option.nonEmpty;
        CmsErr.raiseIfAny(if (taken) Violation.Violation("id", "'${id}' は既にあります（ゴミ箱の物を含む）") :: Nil else Nil);
        discard EntriesQueries.insertEntry({ id = EntryId.text(id), typeId = TypeId.toInt64(typeId), projectId = Tenant.currentId() });
        writeContent(id, Stage.Draft, owner, data);
        get(id)

    ///
    /// 下書きを直す。patch のキーだけ上書きし、null で消す。expectedVersion が今の版と違えば conflict。
    ///
    pub def update(id: EntryId, patch: EntryData, expectedVersion: Int32): Entry \ Db + CmsErr + Tenant =
        let existing = get(id);
        let owner = ContentTypes.get(existing#typeId);
        writeDraft(owner, existing, EntryValidation.merge(EntryValidation.prune(owner#fields, existing#data), patch), expectedVersion)

    ///
    /// ゴミ箱へ。無ければ notFound。公開中なら公開も取り下げる（公開側から消え、一意の値も空く）。
    ///
    pub def delete(id: EntryId): Unit \ Db + CmsErr + Tenant =
        let existing = get(id);
        if (existing#stage == Stage.Published) discard unpublish(id) else ();
        discard EntriesQueries.deleteLinks({ fromEntryId = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Draft) });
        discard EntriesQueries.softDeleteEntry(EntryId.text(id))

    // ---- 公開 ----

    ///
    /// 下書きを公開する。required と unique と参照先の公開を検査し、draft の行を published の行へ写し、版を積む。
    /// 既に公開中なら公開側を下書きで上書きする（再公開）。
    /// 参照先が未公開なら invalid。withDependencies なら参照先を先に（再帰的に）公開する。循環は 1 度だけ辿る。
    ///
    pub def publish(id: EntryId, author: String, withDependencies: Bool): Entry \ Db + CmsErr + Tenant =
        publishWithin(Nil, id, author, withDependencies)

    def publishWithin(visited: List[EntryId], id: EntryId, author: String, withDependencies: Bool): Entry \ Db + CmsErr + Tenant =
        let key = EntryId.text(id);
        let existing = get(id);
        let owner = ContentTypes.get(existing#typeId);
        let data = EntryValidation.prune(owner#fields, existing#data);
        let missing = EntriesQueries.missingTargets(key) |> List.filterMap(EntryRows.toTargetId);
        CmsErr.raiseIfAny(EntryValidation.publish(owner#fields, data) ::: uniqueViolations(owner, existing)
            ::: (missing |> List.map(target -> Violation.Violation("references", "参照先 '${target}' はありません（消されています）。参照を外してください"))));
        let pending = EntriesQueries.unpublishedTargets(key) |> List.filterMap(EntryRows.toTargetId);
        if (withDependencies)
            List.forEach(dependency -> if (List.memberOf(dependency, id :: visited)) () else discard publishWithin(id :: visited, dependency, author, true), pending)
        else
            CmsErr.raiseIfAny(pending |> List.map(dependency -> Violation.Violation("references", "参照先 '${dependency}' が未公開です（withDependencies: true で一緒に公開できます）")));
        writeContent(id, Stage.Published, owner, data);
        discard EntriesQueries.insertVersion(EntryRows.versionInsert(existing, author, VersionReason.Publish));
        discard EntriesQueries.markPublished(key);
        get(id)

    ///
    /// 公開を取り下げる。published の行と一意の値を消す。下書きは残る。未公開なら何もしない。
    ///
    pub def unpublish(id: EntryId): Entry \ Db + CmsErr + Tenant =
        let key = EntryId.text(id);
        let published = EntryRows.stageToDb(Stage.Published);
        discard get(id);
        let referrers = EntriesQueries.publishedReferrers(key) |> List.map(EntryRows.referrerText) |> List.filter(referrer -> referrer != key);
        CmsErr.raiseIfAny(referrers |> List.map(referrer -> Violation.Violation("references", "公開中の entry '${referrer}' が参照しています。先にそちらを取り下げるか、参照を外してください")));
        discard EntriesQueries.deleteLinks({ fromEntryId = key, stage = published });
        discard EntriesQueries.deleteContent({ entryId = key, stage = published });
        discard EntriesQueries.markUnpublished(key);
        get(id)

    // ---- 版 ----

    ///
    /// entry の版。新しい順。
    ///
    pub def versions(id: EntryId): List[EntryVersion] \ DbRead =
        EntriesQueries.listVersions(EntryId.text(id)) |> List.map(EntryRows.toVersion)

    ///
    /// 今の下書きを版として積む。
    ///
    pub def saveVersion(id: EntryId, author: String): EntryVersion \ Db + CmsErr + Tenant =
        let existing = get(id);
        let inserted = EntriesQueries.insertVersion(EntryRows.versionInsert(existing, author, VersionReason.Save)) |> Rows.expectId;
        EntriesQueries.findVersion({ id = inserted, projectId = Tenant.currentId() }) |> Option.map(EntryRows.toVersion) |> CmsErr.orNotFound(Entity.Version, "${inserted}")

    ///
    /// 版の中身を下書きに戻す。版が他の entry の物なら notFound。expectedVersion は update と同じ楽観ロック。
    ///
    pub def restoreVersion(id: EntryId, versionId: VersionId, expectedVersion: Int32): Entry \ Db + CmsErr + Tenant =
        let found = EntriesQueries.findVersion({ id = VersionId.toInt64(versionId), projectId = Tenant.currentId() }) |> Option.map(EntryRows.toVersion)
            |> Option.filter(version -> version#entryId == id)
            |> CmsErr.orNotFound(Entity.Version, "${versionId}");
        let existing = get(id);
        let owner = ContentTypes.get(existing#typeId);
        writeDraft(owner, existing, EntryValidation.prune(owner#fields, found#data), expectedVersion)

    // ---- 部品 ----

    ///
    /// 下書きの中身を置き換えて版を 1 進める。expectedVersion が今の版と違えば conflict（読んでから書くまでの間に進んだ時も）。
    ///
    def writeDraft(owner: ContentType, existing: Entry, data: EntryData, expectedVersion: Int32): Entry \ Db + CmsErr + Tenant =
        let id = existing#id;
        if (existing#version != expectedVersion) CmsErr.conflict(Entity.Entry, EntryId.text(id), existing#version) else ();
        CmsErr.raiseIfAny(EntryValidation.draft(owner#fields, data));
        writeContent(id, Stage.Draft, owner, data);
        let advanced = EntriesQueries.bumpEntryVersion({ id = EntryId.text(id), expected = expectedVersion });
        // 0 行なら読んでから書くまでに誰かが進めた（またはゴミ箱に入った）。今の版は読み直して報告する
        if (advanced == 0) CmsErr.conflict(Entity.Entry, EntryId.text(id), get(id)#version) else ();
        get(id)

    ///
    /// singleton には entry を 1 件しか作れない（コンテンツ API が 1 件しか返さないので、2 件目は見えない物になる）。
    ///
    def singletonViolations(owner: ContentType): List[Violation] \ DbRead = match owner#kind {
        case TypeKind.Collection => Nil
        case TypeKind.Singleton  =>
            let count = EntriesQueries.countEntriesOfType(TypeId.toInt64(owner#id)) |> Rows.total;
            if (count == 0i64) Nil else Violation.Violation("typeId", "SINGLETON の型には entry を 1 件しか作れません") :: Nil
    }

    ///
    /// stage の中身を入れ、entry_links をその stage の分だけ入れ直す。
    ///
    def writeContent(id: EntryId, stage: Stage, owner: ContentType, data: EntryData): Unit \ DbWrite =
        let key = EntryId.text(id);
        let stageText = EntryRows.stageToDb(stage);
        discard EntriesQueries.upsertContent({ entryId = key, stage = stageText, data = EntryRows.dataToJson(data) });
        discard EntriesQueries.deleteLinks({ fromEntryId = key, stage = stageText });
        EntryLinks.extract(owner#fields, data) |> List.forEach(link ->
            discard EntriesQueries.insertLink({ fromEntryId = key, stage = stageText, fieldId = FieldId.toInt64(link#field#id), toEntryId = EntryId.text(link#target), position = link#position }))

    ///
    /// 参照先を同じ stage で 1 本の SELECT で先読みし、各 entry の linked に載せる。参照が無ければ SQL を出さない。
    ///
    def attachLinked(owner: ContentType, stage: Stage, entries: List[Entry]): List[Entry] \ DbRead + Tenant =
        let targets = entries |> List.flatMap(entry -> EntryLinks.targets(owner#fields, entry#data)) |> List.distinct;
        if (List.isEmpty(targets)) entries else {
            let fetched = EntriesQueries.findEntriesByStage({ ids = List.map(EntryId.text, targets), stage = EntryRows.stageToDb(stage), projectId = Tenant.currentId() })
                |> List.map(EntryRows.toEntry(stage))
                |> Linked.of;
            entries |> List.map(entry -> { linked = fetched | entry })
        }

    ///
    /// unique なフィールドの (フィールド, 値)。一意の対象は文字列・数値・真偽値だけで、null や配列のフィールドは含めない。
    ///
    def uniqueValues(owner: ContentType, entry: Entry): List[(FieldDef, Util.Json.Json)] =
        owner#fields |> List.filter(field -> field#unique) |> List.filterMap(field ->
            Map.get(field#apiId, entry#data) |> Option.filter(isScalar) |> Option.map(value -> (field, value)))

    def isScalar(json: Util.Json.Json): Bool = match json {
        case Util.Json.Json.JString(_) => true
        case Util.Json.Json.JNumber(_) => true
        case Util.Json.Json.JBool(_)   => true
        case _                         => false
    }

    ///
    /// 他の公開中の entry が同じ値を持っていれば違反。自分の値は構わない（再公開）。
    /// 検査の前に値ごとの advisory lock を取り、同じ値を同時に公開する Tx を直列にする（後の方が先の公開を見る）。
    ///
    def uniqueViolations(owner: ContentType, entry: Entry): List[Violation] \ DbRead =
        uniqueValues(owner, entry) |> List.filterMap(match (field, value) -> {
            discard EntriesQueries.lockUniqueValue({ typeId = TypeId.toInt64(owner#id), fieldId = FieldId.toInt64(field#id), value = value });
            EntriesQueries.findUniqueHolder({ typeId = TypeId.toInt64(owner#id), apiId = ApiId.text(field#apiId), value = value })
                |> Option.map(row -> row#id)
                |> Option.filter(holder -> holder != EntryId.text(entry#id))
                |> Option.map(holder -> Violation.Violation("fields.${field#apiId}", "'${scalarText(value)}' は公開中の entry '${holder}' が使っています"))
        })

    ///
    /// メッセージに出す値。数値は 1.0 も 1 と出す（一意では同じ値なので）。
    ///
    def scalarText(json: Util.Json.Json): String = match json {
        case Util.Json.Json.JString(s) => s
        case Util.Json.Json.JNumber(n) => unsafe IO { n.stripTrailingZeros().toPlainString() }
        case Util.Json.Json.JBool(b)   => if (b) "true" else "false"
        case other                     => "${other}"
    }

}
