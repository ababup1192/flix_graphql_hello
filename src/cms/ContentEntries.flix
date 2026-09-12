///
/// entry の下書きと公開を読み書きするユースケース。生成された EntriesQueries を並べる層。
/// 中身の検証は EntryValidation（下書きは緩く、公開は required まで）、行と値の変換は EntryRows。
/// pub の入口は権限の証明（`Granted[ReadDraft]` / `Granted[WriteEntries]` / `Granted[PublishEntries]`。`Session.grant()` で作る）を最初の引数で受け、自分では判定しない。
///
mod ContentEntries {

    ///
    /// コンテンツ API がどの stage を読むか。公開中は誰でも読める（プロジェクトが private ならキーの検査は認証が済ませている）ので証明が要らず、
    /// 下書きは readDraft の証明を載せる（1 件なら `Session.grantOn(entryResource)` でプレビュートークンも通る）。
    ///
    pub enum StageAccess {
        case Published
        case Draft(Granted[ReadDraft])
    }

    /// 読む stage。
    pub def stageOf(access: StageAccess): Stage = match access {
        case StageAccess.Published => Stage.Published
        case StageAccess.Draft(_)  => Stage.Draft
    }

    // ---- 読む ----

    ///
    /// 型の entry の一覧（管理 API）。既定は更新が新しい順。search が空なら全件、あればどれかの値に含む物。SQL は 2 本（一覧と件数）。
    /// fields は並び順のキーがフィールドの時に式を決める物（型の定義。フィールドで並べないなら空でよい）。
    ///
    pub def list(_proof: Granted[ReadDraft], typeId: TypeId, fields: List[FieldDef], entryQuery: EntryQuery): EntryPage \ DbRead + Tenant =
        let search = if (entryQuery#search == "") Nil else Condition.AnyValueContains(entryQuery#search) :: Nil;
        page(typeId, fields, Stage.Draft, { filter = search ::: entryQuery#filter, orderBy = entryQuery#orderBy, first = entryQuery#first, start = entryQuery#start })

    ///
    /// id で 1 つ（下書きの中身）。無ければ（ゴミ箱の物も）None。
    ///
    pub def find(_proof: Granted[ReadDraft], id: EntryId): Option[Entry] \ DbRead + Tenant =
        lookup(id)

    /// id で 1 つ（下書きの中身）。権限は見ない（ユースケースの内部で使う）。
    def lookup(id: EntryId): Option[Entry] \ DbRead + Tenant =
        EntriesQueries.findEntryByStage({ id = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Draft), projectId = Tenant.currentId() }) |> Option.map(EntryRows.toEntry(Stage.Draft))

    ///
    /// id の並びで複数。無い id は落ちる。並びは ids の順（SQL の順ではない。呼ぶ側が「新しい順」のような意味を付けているため）。
    ///
    pub def findMany(_proof: Granted[ReadDraft], ids: List[EntryId]): List[Entry] \ DbRead + Tenant =
        if (List.isEmpty(ids)) Nil else {
            let found = EntriesQueries.findEntriesByStage({ ids = List.map(EntryId.text, ids), stage = EntryRows.stageToDb(Stage.Draft), projectId = Tenant.currentId() })
                |> List.map(EntryRows.toEntry(Stage.Draft))
                |> List.map(entry -> (entry#id, entry)) |> List.toMap;
            ids |> List.filterMap(id -> Map.get(id, found))
        }

    ///
    /// id で 1 つ。無ければ notFound。
    ///
    pub def get(_proof: Granted[ReadDraft], id: EntryId): Entry \ DbRead + CmsErr + Tenant =
        load(id)

    /// id で 1 つ。無ければ notFound。権限は見ない（ユースケースの内部で使う）。
    def load(id: EntryId): Entry \ DbRead + CmsErr + Tenant =
        lookup(id) |> CmsErr.orNotFound(Entity.Entry, EntryId.text(id))

    // ---- コンテンツ API（stage の行を読む）----

    ///
    /// stage の行を id で 1 つ。その stage の中身が無ければ（未公開など）None。参照先は 1 段先読みする。
    ///
    pub def findByStage(owner: ContentType, id: EntryId, access: StageAccess): Option[Entry] \ DbRead + Tenant =
        let stage = stageOf(access);
        EntriesQueries.findEntryByStage({ id = EntryId.text(id), stage = EntryRows.stageToDb(stage), projectId = Tenant.currentId() })
            |> Option.map(EntryRows.toEntry(stage))
            |> Option.flatMap(entry -> attachLinked(owner, stage, entry :: Nil) |> List.head)

    ///
    /// stage の行の一覧。絞り込みと並び順は EntryFilterSql が SQL にする。SQL は 2 本（一覧と件数）。
    ///
    pub def listByStage(owner: ContentType, access: StageAccess, listQuery: ListQuery): EntryPage \ DbRead + Tenant =
        let stage = stageOf(access);
        let found = page(owner#id, owner#fields, stage, listQuery);
        { entries = attachLinked(owner, stage, found#entries) | found }

    ///
    /// singleton 用。stage の行を 1 つだけ（更新が新しい物）。件数は数えない。
    ///
    pub def firstByStage(owner: ContentType, access: StageAccess): Option[Entry] \ DbRead + Tenant =
        let stage = stageOf(access);
        rows(owner#id, owner#fields, stage, { filter = Nil, orderBy = Nil, first = 1, start = PageStart.Offset(0) }) |> attachLinked(owner, stage) |> List.head

    ///
    /// stage の行の 1 ページと件数。参照の先読みはしない。first + 1 件引いて「次があるか」を決め、各 entry の位置（cursor）を付ける。
    ///
    def page(typeId: TypeId, fields: List[FieldDef], stage: Stage, listQuery: ListQuery): EntryPage \ DbRead + Tenant =
        let (entries, hasNextPage) = EntryPage.trimPage(listQuery#first, rows(typeId, fields, stage, listQuery));
        { entries = entries,
          cursors = entries |> List.map(entry -> Cursor.encode(Cursor.ofEntry(fields, listQuery#orderBy, entry))),
          totalCount = EntriesQueries.countEntriesByStage({ typeId = TypeId.toInt64(typeId), stage = EntryRows.stageToDb(stage), projectId = Tenant.currentId() }, EntryFilterSql.predAllowingRaw(listQuery#filter)) |> Rows.total,
          hasNextPage = hasNextPage }

    ///
    /// stage の行を first + 1 件まで。絞り込み・並び順・cursor の続きは EntryFilterSql が SQL にする。after なら offset は 0。
    ///
    def rows(typeId: TypeId, fields: List[FieldDef], stage: Stage, listQuery: ListQuery): List[Entry] \ DbRead + Tenant =
        let offset = match listQuery#start {
            case PageStart.Offset(skip) => skip
            case PageStart.After(_)     => 0
        };
        EntriesQueries.listEntriesByStage(
            { typeId = TypeId.toInt64(typeId), stage = EntryRows.stageToDb(stage), limit = Int32.toInt64(listQuery#first + 1), offset = Int32.toInt64(offset), projectId = Tenant.currentId() },
            EntryFilterSql.predWithStart(fields, listQuery), EntryFilterSql.order(fields, listQuery#orderBy)) |> List.map(EntryRows.toEntry(stage))

    // ---- 書く ----

    ///
    /// 下書きを作る。id を渡せば（移行用）それを使い、無ければ振る。中身が型に合わなければ invalid。
    /// id はゴミ箱の物とも重ねられない（PK が残っている）。
    ///
    pub def create(proof: Granted[WriteEntries], typeId: TypeId, givenId: Option[EntryId], given: EntryData): Entry \ Db + CmsErr + IdGen + Tenant =
        // 型を引き、下書きの規則（と singleton の件数）で検査する
        let owner = ContentTypes.get(Session.readDraftOfWriter(proof), typeId);
        CmsErr.raiseIfAny(EntryValidation.draft(owner#fields, given) ::: singletonViolations(owner));
        // id を決める。渡されていればそれ、無ければ振る
        // WhyNot: Option.getWithDefault(IdGen.freshEntryId()) にしないのは、引数が先に評価されて id を渡した時も 1 つ消費するため
        let id = match givenId {
            case Some(chosen) => chosen
            case None        => IdGen.freshEntryId()
        };
        ensureIdFree(id);
        // entry の行を作り、下書きの中身を置く
        discard EntriesQueries.insertEntry({ id = EntryId.text(id), typeId = TypeId.toInt64(typeId), projectId = Tenant.currentId() });
        writeContent(id, Stage.Draft, owner, given);
        load(id)

    ///
    /// その id の entry が無い事（ゴミ箱の物を含む）。あれば invalid。
    ///
    def ensureIdFree(id: EntryId): Unit \ DbRead + CmsErr + Tenant =
        let taken = EntriesQueries.entryExists({ id = EntryId.text(id), projectId = Tenant.currentId() }) |> Option.nonEmpty;
        CmsErr.raiseIfAny(if (taken) Violation.Violation("id", "'${id}' は既にあります（ゴミ箱の物を含む）") :: Nil else Nil)

    ///
    /// 下書きを直す。patch のキーだけ上書きし、null で消す。expectedVersion が今の版と違えば conflict。
    ///
    pub def update(proof: Granted[WriteEntries], id: EntryId, patch: EntryData, expectedVersion: Int32): Entry \ Db + CmsErr + Tenant =
        let existing = load(id);
        let owner = ContentTypes.get(Session.readDraftOfWriter(proof), existing#typeId);
        // 今の下書き（型に無いキーは落とす）に patch を重ね、版の照合と検査は writeDraft
        writeDraft(owner, existing, EntryValidation.merge(EntryValidation.prune(owner#fields, existing#data), patch), expectedVersion)

    ///
    /// ゴミ箱へ。無ければ notFound。公開中なら公開も取り下げる（公開側から消え、一意の値も空く）ので、
    /// 公開中の物には取り下げの証明も要る。無ければ（writer が公開中の物を消そうとした）forbidden(publishEntries)。
    /// 呼ぶ側は `Session.tryGrant()` で持てるだけ渡す。
    ///
    pub def delete(proof: Granted[WriteEntries], unpublishing: Option[Granted[PublishEntries]], id: EntryId): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let existing = load(id);
        if (existing#stage == Stage.Published) discard unpublish(unpublishing |> CmsErr.orForbidden(Permission.PublishEntries), id) else ();
        discard EntriesQueries.deleteLinks({ fromEntryId = EntryId.text(id), stage = EntryRows.stageToDb(Stage.Draft), projectId = Tenant.currentId() });
        discard EntriesQueries.softDeleteEntry({ id = EntryId.text(id), projectId = Tenant.currentId() });
        // 戻す先が無くなったので、預かっていた編集中の中身を全員分捨てる（論理削除なので外部キーの CASCADE は効かない）
        EntryAutosaves.purge(proof, id);
        let owner = ContentTypes.get(Session.readDraftOfWriter(proof), existing#typeId);
        Publishing.notify(PublishingEvent.EntryDeleted(id, owner#apiId, EntryValue.slugOf(owner, existing#data)));
        Audit.record(AuditChange.EntryDeleted(id, owner#apiId, existing#version))

    /// 出来事に載せる型の apiId。
    def apiIdOf(reader: Granted[ReadDraft], typeId: TypeId): ApiId \ DbRead + CmsErr + Tenant =
        ContentTypes.get(reader, typeId)#apiId

    // ---- 公開 ----

    ///
    /// 下書きを公開する。required と unique と参照先の公開を検査し、draft の行を published の行へ写し、版を積む。
    /// 既に公開中なら公開側を下書きで上書きする（再公開）。
    /// 参照先が未公開なら invalid。withDependencies なら参照先を先に（再帰的に）公開する。循環は 1 度だけ辿る。
    ///
    pub def publish(proof: Granted[PublishEntries], id: EntryId, author: String, withDependencies: Bool): Entry \ Db + CmsErr + IdGen + Tenant =
        publishWithin(proof, Nil, id, author, withDependencies)

    ///
    /// 予約からの公開。公開の本体は `publish` と同じで、版の author は "scheduler"。監査に entry.published を積む（主体は system、予約の時刻付き）。
    ///
    /// WhyNot: 手での公開（`publish`）では積まない。版が author を持っていて、監査に二重に持つと片方だけ残る形が作れてしまう。
    /// この判断は版が append-only（`029_entry_versions_append_only.sql`。書き換え・削除ができず、content type を消しても残る）
    /// である事が前提。版の policy を緩めるなら、この判断も一緒に見直す。
    /// 予約の実行は版の author が "scheduler" になり誰の予約かが版から読めないので、こちらだけ積む。
    ///
    pub def publishScheduled(proof: Granted[PublishEntries], id: EntryId, scheduledFor: Timestamp.Timestamp, withDependencies: Bool): Entry \ Db + CmsErr + IdGen + Tenant + Session =
        let published = publishWithin(proof, Nil, id, "scheduler", withDependencies);
        Audit.record(AuditChange.EntryPublishedBySchedule(id, apiIdOf(Session.readDraftOfPublisher(proof), published#typeId), published#version, scheduledFor));
        published

    /// 公開の本体。visited は withDependencies で辿った entry（循環を 1 度で止める）。
    def publishWithin(proof: Granted[PublishEntries], visited: List[EntryId], id: EntryId, author: String, withDependencies: Bool): Entry \ Db + CmsErr + IdGen + Tenant =
        // 下書きを読み、公開の規則で検査する（unique は advisory lock 付き）
        let existing = load(id);
        let owner = ContentTypes.get(Session.readDraftOfPublisher(proof), existing#typeId);
        let data = EntryValidation.prune(owner#fields, existing#data);
        let report = reportOf(true, owner, existing, data);
        CmsErr.raiseIfAny(report#violations);
        // 未公開の参照先を先に公開するか、invalid で止める
        let pending = report#unpublishedDependencies |> List.map(dependency -> dependency#id);
        publishDependencies(proof, visited, id, author, withDependencies, pending);
        // published の行を書き、版を積み、entry を公開中にする
        commitPublished(owner, existing, data, author);
        Publishing.notify(PublishingEvent.EntryPublished(id, owner#apiId, EntryValue.slugOf(owner, data)));
        load(id)

    ///
    /// 未公開の参照先の扱い。withDependencies なら（この entry を visited に足して）先に再帰的に公開し、でなければ invalid。
    ///
    def publishDependencies(proof: Granted[PublishEntries], visited: List[EntryId], id: EntryId, author: String, withDependencies: Bool, pending: List[EntryId]): Unit \ Db + CmsErr + IdGen + Tenant =
        if (withDependencies)
            List.forEach(dependency -> if (List.memberOf(dependency, id :: visited)) () else discard publishWithin(proof, id :: visited, dependency, author, true), pending)
        else
            CmsErr.raiseIfAny(pending |> List.map(dependency -> Violation.Violation("references", "参照先 '${dependency}' が未公開です（withDependencies: true で一緒に公開できます）")))

    ///
    /// 検査を通った中身を published の行へ写し、版を積み、entry を公開中にする。
    ///
    def commitPublished(owner: ContentType, existing: Entry, data: EntryData, author: String): Unit \ DbWrite + Tenant =
        writeContent(existing#id, Stage.Published, owner, data);
        discard EntriesQueries.insertVersion(EntryRows.versionInsert(existing, author, VersionReason.Publish));
        discard EntriesQueries.markPublished({ id = EntryId.text(existing#id), projectId = Tenant.currentId() })

    ///
    /// 公開できるかを書き込まずに答える（dry-run）。違反を全部集め、未公開の参照先も返す。
    /// unique の検査はロックを取らない（参考値。押した瞬間の競合は publish 本体が止める）。
    ///
    pub def publishReport(proof: Granted[ReadDraft], id: EntryId): PublishReport \ DbRead + CmsErr + Tenant =
        let existing = load(id);
        let owner = ContentTypes.get(proof, existing#typeId);
        // publish 本体と同じ検査を、ロック無しで
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

    // ---- 公開計画 ----

    ///
    /// 公開計画（dry-run）。ids と（withDependencies なら）未公開の参照先を依存が先の順に並べ、1 つずつの publishReport を付ける。書き込まない。
    /// 無い id は notFound。
    ///
    pub def publishPlan(proof: Granted[ReadDraft], ids: List[EntryId], withDependencies: Bool): PublishPlan \ DbRead + CmsErr + Tenant =
        planOf(proof, ids, withDependencies)

    ///
    /// 計画を作り、通るならその順で全部公開する。1 つでも通らなければ invalid で、何も公開しない（呼ぶ側の Tx が全部戻す）。
    /// 違反の path は entry id を頭に付ける（"b1.fields.title"）。
    ///
    pub def publishMany(proof: Granted[PublishEntries], ids: List[EntryId], author: String, withDependencies: Bool): List[Entry] \ Db + CmsErr + IdGen + Tenant =
        let plan = planOf(Session.readDraftOfPublisher(proof), ids, withDependencies);
        CmsErr.raiseIfAny(plan#violations ::: (plan#steps |> List.flatMap(step -> step#report#violations |> List.map(prefixed(step#entry#id)))));
        // 計画の順なら参照先は先に公開済みなので、1 件ずつの publish（withDependencies 無し）で通る
        plan#steps |> List.map(step -> publish(proof, step#entry#id, author, false))

    /// 違反の path に entry id を付ける。
    def prefixed(id: EntryId, violation: Violation): Violation =
        let Violation.Violation(path, message) = violation;
        Violation.Violation("${EntryId.text(id)}.${path}", message)

    /// 計画の本体。entry ごとの dry-run を集め（withDependencies なら未公開の参照先も辿る）、順は PublishOrder が決める。
    def planOf(reader: Granted[ReadDraft], ids: List[EntryId], withDependencies: Bool): PublishPlan \ DbRead + CmsErr + Tenant =
        let reports = collectReports(reader, withDependencies, Map.empty(), ids);
        let dependencies = reports |> Map.map(match (_, report) -> report#unpublishedDependencies |> List.map(dependency -> dependency#id));
        let ordered = PublishOrder.plan(ids, withDependencies, dependencies);
        {
            steps = ordered#steps |> List.filterMap(match (id, reason) -> Map.get(id, reports) |> Option.map(match (entry, report) -> { entry = entry, reason = reason, report = report })),
            violations = ordered#violations
        }

    /// ids の entry ごとの dry-run を seen に足す。withDependencies なら未公開の参照先も辿る（見た物は 2 度引かない）。
    def collectReports(reader: Granted[ReadDraft], withDependencies: Bool, seen: Map[EntryId, (Entry, PublishReport)], ids: List[EntryId]): Map[EntryId, (Entry, PublishReport)] \ DbRead + CmsErr + Tenant =
        List.foldLeft((acc, id) -> if (Map.memberOf(id, acc)) acc else {
            let existing = load(id);
            let owner = ContentTypes.get(reader, existing#typeId);
            let report = reportOf(false, owner, existing, EntryValidation.prune(owner#fields, existing#data));
            let next = Map.insert(id, (existing, report), acc);
            if (withDependencies) collectReports(reader, withDependencies, next, report#unpublishedDependencies |> List.map(dependency -> dependency#id)) else next
        }, seen, ids)

    ///
    /// 操作の影響。取り下げ・削除で壊れる参照元（公開の中身。削除なら下書きも）と、公開で一緒に動く未公開の参照先（再帰）。
    ///
    pub def impact(_proof: Granted[ReadDraft], id: EntryId, action: ImpactAction): Impact \ DbRead + CmsErr + Tenant =
        // 無ければ notFound
        discard load(id);
        // 操作ごとに、壊れる参照元（breaks）と一緒に動く参照先（cascades）を集める
        match action {
            case ImpactAction.Publish   => { breaks = Nil, cascades = dependenciesOf(id :: Nil, id) |> List.filterMap(lookup) }
            case ImpactAction.Unpublish => { breaks = referrers(id, Stage.Published), cascades = Nil }
            case ImpactAction.Delete    => { breaks = referrers(id, Stage.Published) ::: referrers(id, Stage.Draft), cascades = Nil }
        }

    ///
    /// stage の中身でこの entry を参照している物。参照元は下書きの中身で返す。
    ///
    /// WhyNot: via を FieldId から引き直さないのは、索引が apiId を持つようになったため
    /// （参照元 1 件ごとにフィールドの SELECT が 1 本増えていた）。
    ///
    def referrers(id: EntryId, stage: Stage): List[Referrer] \ DbRead + Tenant =
        EntriesQueries.referrerLinks({ toEntryId = EntryId.text(id), stage = EntryRows.stageToDb(stage), projectId = Tenant.currentId() })
            |> List.filterMap(row -> forM (
                    entry <- EntryId.parse(row#fromEntryId) |> Option.flatMap(lookup);
                    via   <- ApiId.parse(row#fieldApiId)
                ) yield { entry = entry, via = via, stage = stage })

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
    pub def unpublish(proof: Granted[PublishEntries], id: EntryId): Entry \ Db + CmsErr + IdGen + Tenant + Session =
        let existing = load(id);
        // 公開中の他の entry が参照していれば取り下げられない
        CmsErr.raiseIfAny(publishedReferrerViolations(id));
        // published の行（参照・中身・印）を消す
        deletePublished(id);
        // 公開中だった時だけ出来事（Webhook と監査）になる
        if (existing#stage == Stage.Published) {
            let owner = ContentTypes.get(Session.readDraftOfPublisher(proof), existing#typeId);
            Publishing.notify(PublishingEvent.EntryUnpublished(id, owner#apiId, EntryValue.slugOf(owner, existing#data)));
            Audit.record(AuditChange.EntryUnpublished(id, owner#apiId, existing#version))
        } else ();
        load(id)

    ///
    /// 公開中の中身でこの entry を参照している他の entry ごとの違反。自分自身の参照は数えない。
    ///
    def publishedReferrerViolations(id: EntryId): List[Violation] \ DbRead + Tenant =
        let key = EntryId.text(id);
        EntriesQueries.publishedReferrers({ toEntryId = key, projectId = Tenant.currentId() })
            |> List.map(EntryRows.referrerText)
            |> List.filter(referrer -> referrer != key)
            |> List.map(referrer -> Violation.Violation("references", "公開中の entry '${referrer}' が参照しています。先にそちらを取り下げるか、参照を外してください"))

    ///
    /// published の行を消す。参照（entry_links）、中身、entry の公開中の印の順。
    ///
    def deletePublished(id: EntryId): Unit \ DbWrite + Tenant =
        let key = EntryId.text(id);
        let published = EntryRows.stageToDb(Stage.Published);
        discard EntriesQueries.deleteLinks({ fromEntryId = key, stage = published, projectId = Tenant.currentId() });
        discard EntriesQueries.deleteContent({ entryId = key, stage = published, projectId = Tenant.currentId() });
        discard EntriesQueries.markUnpublished({ id = key, projectId = Tenant.currentId() })

    // ---- バージョン ----

    ///
    /// entry の版。新しい順。
    ///
    pub def versions(_proof: Granted[ReadDraft], id: EntryId): List[EntryVersion] \ DbRead + Tenant =
        EntriesQueries.listVersions({ entryId = EntryId.text(id), projectId = Tenant.currentId() }) |> List.map(EntryRows.toVersion)

    ///
    /// 複数の entry の版を 1 本の SELECT でまとめて。id → 版（新しい順）。渡した id は版が無くても（他のプロジェクトの物でも）空で載る。
    /// 一覧の行ごとに versions を引く代わりに使う（管理 API の先読み）。
    ///
    pub def versionsOf(_proof: Granted[ReadDraft], ids: List[EntryId]): Map[EntryId, List[EntryVersion]] \ DbRead + Tenant =
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
    pub def saveVersion(_proof: Granted[WriteEntries], id: EntryId, author: String): EntryVersion \ Db + CmsErr + Tenant =
        let existing = load(id);
        let inserted = EntriesQueries.insertVersion(EntryRows.versionInsert(existing, author, VersionReason.Save)) |> Rows.expectId;
        EntriesQueries.findVersion({ id = inserted, projectId = Tenant.currentId() }) |> Option.map(EntryRows.toVersion) |> CmsErr.orNotFound(Entity.Version, "${inserted}")

    ///
    /// 版の中身を下書きに戻す。版が他の entry の物なら notFound。expectedVersion は update と同じ楽観ロック。
    ///
    pub def restoreVersion(proof: Granted[WriteEntries], id: EntryId, versionId: VersionId, expectedVersion: Int32): Entry \ Db + CmsErr + Tenant =
        let found = EntriesQueries.findVersion({ id = VersionId.toInt64(versionId), projectId = Tenant.currentId() }) |> Option.map(EntryRows.toVersion)
            |> Option.filter(version -> version#entryId == id)
            |> CmsErr.orNotFound(Entity.Version, "${versionId}");
        let existing = load(id);
        let owner = ContentTypes.get(Session.readDraftOfWriter(proof), existing#typeId);
        writeDraft(owner, existing, EntryValidation.prune(owner#fields, found#data), expectedVersion)

    ///
    /// 2 つのバージョンの中身の差分（fromRef → toRef）。中身の比べ方は EntryDiff。
    ///
    pub def diff(proof: Granted[ReadDraft], id: EntryId, fromRef: VersionRef, toRef: VersionRef): List[FieldChange] \ DbRead + CmsErr + Tenant =
        let existing = load(id);
        diffOf(proof, ContentTypes.get(proof, existing#typeId), existing, fromRef, toRef)

    ///
    /// 読み込み済みの entry と型で diff。一覧の行（先読みした型）から呼ぶ用で、entry と型は引き直さない。
    ///
    pub def diffOf(_proof: Granted[ReadDraft], owner: ContentType, existing: Entry, fromRef: VersionRef, toRef: VersionRef): List[FieldChange] \ DbRead + CmsErr + Tenant =
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
        CmsErr.raiseIfAny(EntryValidation.draft(owner#fields, given));
        writeContent(id, Stage.Draft, owner, given);
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
        discard EntriesQueries.upsertContent({ entryId = key, stage = stageText, data = EntryRows.dataToJson(data), projectId = Tenant.currentId() });
        discard EntriesQueries.deleteLinks({ fromEntryId = key, stage = stageText, projectId = Tenant.currentId() });
        EntryLinks.extract(owner#fields, data) |> List.forEach(link ->
            discard EntriesQueries.insertLink({ projectId = Tenant.currentId(), fromEntryId = key, stage = stageText, fieldApiId = ApiId.text(link#field#apiId), toEntryId = EntryId.text(link#target), position = link#position }))

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
