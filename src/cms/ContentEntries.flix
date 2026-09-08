///
/// entry の下書きと公開を読み書きするユースケース。生成された EntriesQueries を並べる層。
/// 中身の検証は EntryValidation（下書きは緩く、公開は required まで）、行と値の変換は EntryRows。
///
mod ContentEntries {

    // ---- 読む ----

    ///
    /// 型の entry の一覧（管理 API）。更新が新しい順。search が空なら全件、あればどれかの値に含む物。SQL は 2 本（一覧と件数）。
    ///
    pub def list(typeId: TypeId, entryQuery: EntryQuery): EntryPage \ DbRead + Tenant + CmsErr + Session =
        Session.require(Permission.ReadDraft);
        let filter = if (entryQuery#search == "") Nil else Condition.AnyValueContains(entryQuery#search) :: Nil;
        page(typeId, Nil, Stage.Draft, { filter = filter, orderBy = Nil, first = entryQuery#first, skip = entryQuery#skip })

    ///
    /// id で 1 つ（下書きの中身）。無ければ（ゴミ箱の物も）None。
    ///
    pub def find(id: EntryId): Option[Entry] \ DbRead + Tenant + CmsErr + Session =
        Session.require(Permission.ReadDraft);
        lookup(id)

    /// id で 1 つ（下書きの中身）。権限は見ない（ユースケースの内部で使う）。
    def lookup(id: EntryId): Option[Entry] \ DbRead + Tenant =
        EntriesQueries.findEntryByStage({ id = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Draft), projectId = Tenant.currentId() }) |> Option.map(EntryRows.toEntry(Stage.Draft))

    ///
    /// id で 1 つ。無ければ notFound。
    ///
    pub def get(id: EntryId): Entry \ DbRead + CmsErr + Tenant + Session =
        Session.require(Permission.ReadDraft);
        load(id)

    /// id で 1 つ。無ければ notFound。権限は見ない（ユースケースの内部で使う）。
    def load(id: EntryId): Entry \ DbRead + CmsErr + Tenant =
        lookup(id) |> CmsErr.orNotFound(Entity.Entry, EntryId.text(id))

    // ---- コンテンツ API（stage の行を読む）----

    ///
    /// stage の行を id で 1 つ。その stage の中身が無ければ（未公開など）None。参照先は 1 段先読みする。
    ///
    pub def findByStage(owner: ContentType, id: EntryId, stage: Stage): Option[Entry] \ DbRead + Tenant + CmsErr + Session =
        match stage { case Stage.Draft => Session.requireOn(Permission.ReadDraft, Authz.entryResource(id)) case Stage.Published => () };
        EntriesQueries.findEntryByStage({ id = EntryId.text(id), stage = EntryRows.stageToDb(stage), projectId = Tenant.currentId() })
            |> Option.map(EntryRows.toEntry(stage))
            |> Option.flatMap(entry -> attachLinked(owner, stage, entry :: Nil) |> List.head)

    ///
    /// stage の行の一覧。絞り込みと並び順は EntryFilterSql が SQL にする。SQL は 2 本（一覧と件数）。
    ///
    pub def listByStage(owner: ContentType, stage: Stage, listQuery: ListQuery): EntryPage \ DbRead + Tenant + CmsErr + Session =
        requireStage(stage);
        let found = page(owner#id, owner#fields, stage, listQuery);
        { entries = attachLinked(owner, stage, found#entries) | found }

    ///
    /// singleton 用。stage の行を 1 つだけ（更新が新しい物）。件数は数えない。
    ///
    pub def firstByStage(owner: ContentType, stage: Stage): Option[Entry] \ DbRead + Tenant + CmsErr + Session =
        requireStage(stage);
        rows(owner#id, owner#fields, stage, { filter = Nil, orderBy = Nil, first = 1, skip = 0 }) |> attachLinked(owner, stage) |> List.head

    /// 下書きを読むには readDraft が要る。公開中は誰でも読める（プロジェクトが private ならキーの検査は Runner が済ませている）。
    /// 一覧の下書きは readDraft が要る（プレビュートークンでは読めない。1 件の下書きは findByStage が entry ごとに見る）。
    def requireStage(stage: Stage): Unit \ Session + CmsErr = match stage {
        case Stage.Draft     => Session.require(Permission.ReadDraft)
        case Stage.Published => ()
    }

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
    pub def create(typeId: TypeId, givenId: Option[EntryId], given: EntryData): Entry \ Db + CmsErr + IdGen + Tenant + Session =
        Session.require(Permission.WriteEntries);
        let owner = ContentTypes.get(typeId);
        let data = EntryValidation.normalize(owner#fields, given);
        CmsErr.raiseIfAny(EntryValidation.draft(owner#fields, data) ::: singletonViolations(owner));
        // WhyNot: Option.getWithDefault(IdGen.freshEntryId()) にしないのは、引数が先に評価されて id を渡した時も 1 つ消費するため
        let id = match givenId {
            case Some(chosen) => chosen
            case None        => IdGen.freshEntryId()
        };
        let taken = EntriesQueries.entryExists({ id = EntryId.text(id), projectId = Tenant.currentId() }) |> Option.nonEmpty;
        CmsErr.raiseIfAny(if (taken) Violation.Violation("id", "'${id}' は既にあります（ゴミ箱の物を含む）") :: Nil else Nil);
        discard EntriesQueries.insertEntry({ id = EntryId.text(id), typeId = TypeId.toInt64(typeId), projectId = Tenant.currentId() });
        writeContent(id, Stage.Draft, owner, data);
        load(id)

    ///
    /// 下書きを直す。patch のキーだけ上書きし、null で消す。expectedVersion が今の版と違えば conflict。
    ///
    pub def update(id: EntryId, patch: EntryData, expectedVersion: Int32): Entry \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.WriteEntries);
        let existing = load(id);
        let owner = ContentTypes.get(existing#typeId);
        writeDraft(owner, existing, EntryValidation.merge(EntryValidation.prune(owner#fields, existing#data), patch), expectedVersion)

    ///
    /// ゴミ箱へ。無ければ notFound。公開中なら公開も取り下げる（公開側から消え、一意の値も空く）。
    ///
    pub def delete(id: EntryId): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        Session.require(Permission.WriteEntries);
        let existing = load(id);
        if (existing#stage == Stage.Published) discard unpublish(id) else ();
        discard EntriesQueries.deleteLinks({ fromEntryId = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Draft), projectId = Tenant.currentId() });
        discard EntriesQueries.softDeleteEntry({ id = EntryId.text(id), projectId = Tenant.currentId() });
        notify(WebhookEvent.EntryDeleted, id, existing#typeId)

    /// entry の出来事を Webhook に積む（同じ Tx）。
    def notify(event: WebhookEvent, id: EntryId, typeId: TypeId): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        Webhooks.emitEntry(event, id, ContentTypes.get(typeId)#apiId)

    // ---- 公開 ----

    ///
    /// 下書きを公開する。required と unique と参照先の公開を検査し、draft の行を published の行へ写し、版を積む。
    /// 既に公開中なら公開側を下書きで上書きする（再公開）。
    /// 参照先が未公開なら invalid。withDependencies なら参照先を先に（再帰的に）公開する。循環は 1 度だけ辿る。
    ///
    pub def publish(id: EntryId, author: String, withDependencies: Bool): Entry \ Db + CmsErr + IdGen + Tenant + Session =
        Session.require(Permission.PublishEntries);
        publishWithin(Nil, id, author, withDependencies)

    /// 公開の本体。visited は withDependencies で辿った entry（循環を 1 度で止める）。権限は publish が見る。
    def publishWithin(visited: List[EntryId], id: EntryId, author: String, withDependencies: Bool): Entry \ Db + CmsErr + IdGen + Tenant + Session =
        let existing = load(id);
        let owner = ContentTypes.get(existing#typeId);
        let data = EntryValidation.prune(owner#fields, existing#data);
        let report = reportOf(true, owner, existing, data);
        CmsErr.raiseIfAny(report#violations);
        let pending = report#unpublishedDependencies |> List.map(dependency -> dependency#id);
        if (withDependencies)
            List.forEach(dependency -> if (List.memberOf(dependency, id :: visited)) () else discard publishWithin(id :: visited, dependency, author, true), pending)
        else
            CmsErr.raiseIfAny(pending |> List.map(dependency -> Violation.Violation("references", "参照先 '${dependency}' が未公開です（withDependencies: true で一緒に公開できます）")));
        writeContent(id, Stage.Published, owner, data);
        discard EntriesQueries.insertVersion(EntryRows.versionInsert(existing, author, VersionReason.Publish));
        discard EntriesQueries.markPublished({ id = EntryId.text(id), projectId = Tenant.currentId() });
        notify(WebhookEvent.EntryPublished, id, existing#typeId);
        load(id)

    ///
    /// 公開できるかを書き込まずに答える（dry-run）。違反を全部集め、未公開の参照先も返す。
    /// unique の検査はロックを取らない（参考値。押した瞬間の競合は publish 本体が止める）。
    ///
    pub def publishReport(id: EntryId): PublishReport \ DbRead + CmsErr + Tenant + Session =
        Session.require(Permission.ReadDraft);
        let existing = load(id);
        let owner = ContentTypes.get(existing#typeId);
        reportOf(false, owner, existing, EntryValidation.prune(owner#fields, existing#data))

    ///
    /// 公開の検査。lock なら unique の値ごとに advisory lock を取る（本番の publish）。
    ///
    def reportOf(lock: Bool, owner: ContentType, existing: Entry, data: EntryData): PublishReport \ DbRead + Tenant =
        let key = EntryId.text(existing#id);
        let missing = EntriesQueries.missingTargets({ fromEntryId = key, projectId = Tenant.currentId() }) |> List.filterMap(EntryRows.toTargetId);
        let pending = EntriesQueries.unpublishedTargets({ fromEntryId = key, projectId = Tenant.currentId() }) |> List.filterMap(EntryRows.toTargetId) |> List.filter(target -> not List.memberOf(target, missing)) |> List.sort;
        {
            violations = EntryValidation.publish(owner#fields, data) ::: uniqueViolations(lock, owner, existing)
                ::: (missing |> List.map(target -> Violation.Violation("references", "参照先 '${target}' はありません（消されています）。参照を外してください")))
                ::: assetViolations(owner, data),
            unpublishedDependencies = pending |> List.filterMap(lookup)
        }

    ///
    /// 操作の影響。取り下げ・削除で壊れる参照元（公開の中身。削除なら下書きも）と、公開で一緒に動く未公開の参照先（再帰）。
    ///
    pub def impact(id: EntryId, action: ImpactAction): Impact \ DbRead + CmsErr + Tenant + Session =
        Session.require(Permission.ReadDraft);
        discard load(id);
        match action {
            case ImpactAction.Publish   => { breaks = Nil, cascades = dependenciesOf(id :: Nil, id) |> List.filterMap(lookup) }
            case ImpactAction.Unpublish => { breaks = referrers(id, Stage.Published), cascades = Nil }
            case ImpactAction.Delete    => { breaks = referrers(id, Stage.Published) ::: referrers(id, Stage.Draft), cascades = Nil }
        }

    /// stage の中身でこの entry を参照している物。参照元は下書きの中身で返す。
    def referrers(id: EntryId, stage: Stage): List[Referrer] \ DbRead + CmsErr + Tenant + Session =
        EntriesQueries.referrerLinks({ toEntryId = EntryId.text(id), stage = EntryRows.stageToDb(stage), projectId = Tenant.currentId() })
            |> List.filterMap(row -> EntryId.parse(row#fromEntryId) |> Option.flatMap(lookup) |> Option.map(entry ->
                { entry = entry, via = ContentTypes.getField(FieldId.FieldId(row#fieldId))#apiId, stage = stage }))

    /// 未公開の参照先を深さ優先で集める（依存の順。直接の参照先は id 順。重複と循環は visited で止める）。
    def dependenciesOf(visited: List[EntryId], id: EntryId): List[EntryId] \ DbRead + Tenant =
        let missing = EntriesQueries.missingTargets({ fromEntryId = EntryId.text(id), projectId = Tenant.currentId() }) |> List.filterMap(EntryRows.toTargetId);
        let direct = EntriesQueries.unpublishedTargets({ fromEntryId = EntryId.text(id), projectId = Tenant.currentId() }) |> List.filterMap(EntryRows.toTargetId)
            |> List.filter(target -> not List.memberOf(target, missing) and not List.memberOf(target, visited)) |> List.sort;
        List.foldLeft((acc, target) -> if (List.memberOf(target, acc)) acc else acc ::: (target :: dependenciesOf(visited ::: acc ::: (target :: Nil), target)), Nil, direct)

    ///
    /// 中身が指す asset が全部このプロジェクトにあって ready か。無い・pending の物は公開できない（配信 URL が空になる）。
    ///
    def assetViolations(owner: ContentType, data: EntryData): List[Violation] \ DbRead + Tenant =
        let referenced = AssetRefs.extract(owner#fields, data);
        let ready = Assets.findMany(referenced) |> List.filter(asset -> asset#status == AssetStatus.Ready) |> List.map(asset -> asset#id);
        referenced |> List.filter(id -> not List.memberOf(id, ready))
            |> List.map(id -> Violation.Violation("assets", "asset '${id}' がありません（消されているか、アップロードが終わっていません）"))

    ///
    /// 公開を取り下げる。published の行と一意の値を消す。下書きは残る。未公開なら何もしない。
    ///
    pub def unpublish(id: EntryId): Entry \ Db + CmsErr + IdGen + Tenant + Session =
        Session.require(Permission.PublishEntries);
        let key = EntryId.text(id);
        let published = EntryRows.stageToDb(Stage.Published);
        let existing = load(id);
        let referrers = EntriesQueries.publishedReferrers({ toEntryId = key, projectId = Tenant.currentId() }) |> List.map(EntryRows.referrerText) |> List.filter(referrer -> referrer != key);
        CmsErr.raiseIfAny(referrers |> List.map(referrer -> Violation.Violation("references", "公開中の entry '${referrer}' が参照しています。先にそちらを取り下げるか、参照を外してください")));
        discard EntriesQueries.deleteLinks({ fromEntryId = key, stage = published, projectId = Tenant.currentId() });
        discard EntriesQueries.deleteContent({ entryId = key, stage = published });
        discard EntriesQueries.markUnpublished({ id = key, projectId = Tenant.currentId() });
        if (existing#stage == Stage.Published) notify(WebhookEvent.EntryUnpublished, id, existing#typeId) else ();
        load(id)

    // ---- バージョン ----

    ///
    /// entry の版。新しい順。
    ///
    pub def versions(id: EntryId): List[EntryVersion] \ DbRead + CmsErr + Tenant + Session =
        Session.require(Permission.ReadDraft);
        EntriesQueries.listVersions({ entryId = EntryId.text(id), projectId = Tenant.currentId() }) |> List.map(EntryRows.toVersion)

    ///
    /// 複数の entry の版を 1 本の SELECT でまとめて。id → 版（新しい順）。渡した id は版が無くても（他のプロジェクトの物でも）空で載る。
    /// 一覧の行ごとに versions を引く代わりに使う（管理 API の先読み）。
    ///
    pub def versionsOf(ids: List[EntryId]): Map[EntryId, List[EntryVersion]] \ DbRead + CmsErr + Tenant + Session =
        Session.require(Permission.ReadDraft);
        let empty = ids |> List.map(id -> (id, Nil)) |> List.toMap;
        if (List.isEmpty(ids)) empty else {
            let found = EntriesQueries.listVersionsOf({ entryIds = List.map(EntryId.text, ids), projectId = Tenant.currentId() })
                |> List.map(EntryRows.toVersion)
                |> Preload.groupBy(version -> version#entryId);
            Map.union(found, empty)
        }

    ///
    /// 今の下書きを版として積む。
    ///
    pub def saveVersion(id: EntryId, author: String): EntryVersion \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.WriteEntries);
        let existing = load(id);
        let inserted = EntriesQueries.insertVersion(EntryRows.versionInsert(existing, author, VersionReason.Save)) |> Rows.expectId;
        EntriesQueries.findVersion({ id = inserted, projectId = Tenant.currentId() }) |> Option.map(EntryRows.toVersion) |> CmsErr.orNotFound(Entity.Version, "${inserted}")

    ///
    /// 版の中身を下書きに戻す。版が他の entry の物なら notFound。expectedVersion は update と同じ楽観ロック。
    ///
    pub def restoreVersion(id: EntryId, versionId: VersionId, expectedVersion: Int32): Entry \ Db + CmsErr + Tenant + Session =
        Session.require(Permission.WriteEntries);
        let found = EntriesQueries.findVersion({ id = VersionId.toInt64(versionId), projectId = Tenant.currentId() }) |> Option.map(EntryRows.toVersion)
            |> Option.filter(version -> version#entryId == id)
            |> CmsErr.orNotFound(Entity.Version, "${versionId}");
        let existing = load(id);
        let owner = ContentTypes.get(existing#typeId);
        writeDraft(owner, existing, EntryValidation.prune(owner#fields, found#data), expectedVersion)

    ///
    /// 2 つのバージョンの中身の差分（fromRef → toRef）。中身の比べ方は EntryDiff。
    ///
    pub def diff(id: EntryId, fromRef: VersionRef, toRef: VersionRef): List[FieldChange] \ DbRead + CmsErr + Tenant + Session =
        Session.require(Permission.ReadDraft);
        let existing = load(id);
        diffOf(ContentTypes.get(existing#typeId), existing, fromRef, toRef)

    ///
    /// 読み込み済みの entry と型で diff。一覧の行（先読みした型）から呼ぶ用で、entry と型は引き直さない。
    ///
    pub def diffOf(owner: ContentType, existing: Entry, fromRef: VersionRef, toRef: VersionRef): List[FieldChange] \ DbRead + CmsErr + Tenant + Session =
        Session.require(Permission.ReadDraft);
        EntryDiff.diff(owner#fields, versionData(existing, fromRef), versionData(existing, toRef))

    ///
    /// バージョンの参照が指す中身。DRAFT は今の下書き、PUBLISHED は公開中の中身（未公開なら空。初回公開の差分は全部 Added になる）、
    /// versionId はそのバージョンの中身（他の entry の物なら notFound）。
    ///
    def versionData(existing: Entry, versionRef: VersionRef): EntryData \ DbRead + CmsErr + Tenant = match versionRef {
        case VersionRef.Draft     => existing#data
        case VersionRef.Published =>
            EntriesQueries.findEntryByStage({ id = EntryId.text(existing#id), stage = EntryRows.stageToDb(Stage.Published), projectId = Tenant.currentId() })
                |> Option.map(EntryRows.toEntry(Stage.Published)) |> Option.map(published -> published#data)
                |> Option.getWithDefault(Map.empty())
        case VersionRef.Version(versionId) =>
            EntriesQueries.findVersion({ id = VersionId.toInt64(versionId), projectId = Tenant.currentId() }) |> Option.map(EntryRows.toVersion)
                |> Option.filter(version -> version#entryId == existing#id) |> Option.map(version -> version#data)
                |> CmsErr.orNotFound(Entity.Version, "${versionId}")
    }

    // ---- 部品 ----

    ///
    /// 下書きの中身を置き換えて版を 1 進める。expectedVersion が今の版と違えば conflict（読んでから書くまでの間に進んだ時も）。
    ///
    def writeDraft(owner: ContentType, existing: Entry, given: EntryData, expectedVersion: Int32): Entry \ Db + CmsErr + Tenant =
        let id = existing#id;
        if (existing#version != expectedVersion) CmsErr.conflict(Entity.Entry, EntryId.text(id), expectedVersion, existing#version) else ();
        let data = EntryValidation.normalize(owner#fields, given);
        CmsErr.raiseIfAny(EntryValidation.draft(owner#fields, data));
        writeContent(id, Stage.Draft, owner, data);
        let advanced = EntriesQueries.bumpEntryVersion({ id = EntryId.text(id), expected = expectedVersion, projectId = Tenant.currentId() });
        // 0 行なら読んでから書くまでに誰かが進めた（またはゴミ箱に入った）。今の版は読み直して報告する
        if (advanced == 0) CmsErr.conflict(Entity.Entry, EntryId.text(id), expectedVersion, load(id)#version) else ();
        load(id)

    ///
    /// singleton には entry を 1 件しか作れない（コンテンツ API が 1 件しか返さないので、2 件目は見えない物になる）。
    ///
    def singletonViolations(owner: ContentType): List[Violation] \ DbRead + Tenant = match owner#kind {
        case TypeKind.Collection => Nil
        case TypeKind.Singleton  =>
            let count = EntriesQueries.countEntriesOfType({ typeId = TypeId.toInt64(owner#id), projectId = Tenant.currentId() }) |> Rows.total;
            if (count == 0i64) Nil else Violation.Violation("typeId", "SINGLETON の型には entry を 1 件しか作れません") :: Nil
    }

    ///
    /// stage の中身を入れ、entry_links をその stage の分だけ入れ直す。
    ///
    def writeContent(id: EntryId, stage: Stage, owner: ContentType, data: EntryData): Unit \ DbWrite + Tenant =
        let key = EntryId.text(id);
        let stageText = EntryRows.stageToDb(stage);
        discard EntriesQueries.upsertContent({ entryId = key, stage = stageText, data = EntryRows.dataToJson(data) });
        discard EntriesQueries.deleteLinks({ fromEntryId = key, stage = stageText, projectId = Tenant.currentId() });
        EntryLinks.extract(owner#fields, data) |> List.forEach(link ->
            discard EntriesQueries.insertLink({ projectId = Tenant.currentId(), fromEntryId = key, stage = stageText, fieldId = FieldId.toInt64(link#field#id), toEntryId = EntryId.text(link#target), position = link#position }))

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
    def uniqueViolations(lock: Bool, owner: ContentType, entry: Entry): List[Violation] \ DbRead + Tenant =
        uniqueValues(owner, entry) |> List.filterMap(match (field, value) -> {
            if (lock) discard EntriesQueries.lockUniqueValue({ typeId = TypeId.toInt64(owner#id), fieldId = FieldId.toInt64(field#id), value = value }) else ();
            EntriesQueries.findUniqueHolder({ typeId = TypeId.toInt64(owner#id), apiId = ApiId.text(field#apiId), value = value, projectId = Tenant.currentId() })
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
