///
/// content type とフィールドの定義を読み書きするユースケース。生成された ContentTypesQueries / ContentFieldsQueries を並べる層。
/// 型に `\ DbRead` か `\ Db + CmsErr` が出る。読み書きは全部 Tenant のプロジェクトに閉じる（他のプロジェクトの id を渡しても notFound）。名前の規則は Naming、行と値の変換は ContentTypeRows、木の操作は FieldTree。
/// pub の入口は権限の証明（`Granted[ReadDraft]` / `Granted[ManageTypes]`。`Session.grant()` で作る）を最初の引数で受け、自分では判定しない。
///
/// WhyNot: 一意制約の違反を onConstraint で翻訳しないのは、Runner が Mutation 全体を 1 つの Tx に包んでいて、
/// 違反で abort した Tx の中では翻訳しても COMMIT が失敗するため。同じ Tx の中で先に読んで検査するので、
/// 制約に当たるのは同時に同じ名前を作った時だけで、それは DbErr のまま 500 にする。
///
mod ContentTypes {

    // ---- 読む ----

    ///
    /// 全 content type。apiId 順、フィールド付き。SQL は 2 本。
    ///
    pub def list(_proof: Granted[ReadDraft]): List[ContentType] \ DbRead + Tenant =
        listAll()

    /// 全 content type。権限は見ない（ユースケースの内部で使う）。
    def listAll(): List[ContentType] \ DbRead + Tenant =
        let fieldsByType = ContentFieldsQueries.listAllFields(Tenant.currentId()) |> List.map(ContentTypeRows.toFieldDef) |> FieldTree.byType;
        ContentTypesQueries.listContentTypes(Tenant.currentId())
            |> List.map(row -> ContentTypeRows.toContentType(row, Map.getWithDefault(ContentTypeRows.typeIdOf(row), Nil, fieldsByType) |> FieldTree.build))

    ///
    /// id で 1 つ。無ければ None。
    ///
    pub def find(_proof: Granted[ReadDraft], id: TypeId): Option[ContentType] \ DbRead + Tenant =
        lookup(id)

    /// id で 1 つ。権限は見ない（ユースケースの内部で使う）。
    def lookup(id: TypeId): Option[ContentType] \ DbRead + Tenant =
        ContentTypesQueries.findContentType({ id = TypeId.toInt64(id), projectId = Tenant.currentId() }) |> Option.map(row -> ContentTypeRows.toContentType(row, fieldsOf(id)))

    ///
    /// apiId で 1 つ。無ければ None。
    ///
    pub def findByApiId(_proof: Granted[ReadDraft], apiId: ApiId): Option[ContentType] \ DbRead + Tenant =
        ContentTypesQueries.findContentTypeByApiId({ projectId = Tenant.currentId(), apiId = ApiId.text(apiId) }) |> Option.map(row -> ContentTypeRows.toContentType(row, fieldsOf(ContentTypeRows.typeIdOf(row))))

    ///
    /// id で 1 つ。無ければ notFound。
    ///
    pub def get(_proof: Granted[ReadDraft], id: TypeId): ContentType \ DbRead + CmsErr + Tenant =
        load(id)

    /// id で 1 つ。無ければ notFound。権限は見ない（ユースケースの内部で使う）。
    def load(id: TypeId): ContentType \ DbRead + CmsErr + Tenant =
        lookup(id) |> CmsErr.orNotFound(Entity.ContentType, "${id}")

    ///
    /// フィールド 1 つ（children 付き）。無ければ notFound。
    ///
    pub def getField(_proof: Granted[ReadDraft], id: FieldId): FieldDef \ DbRead + CmsErr + Tenant =
        loadField(id)

    /// フィールド 1 つ。無ければ notFound。権限は見ない（ユースケースの内部で使う）。
    def loadField(id: FieldId): FieldDef \ DbRead + CmsErr + Tenant =
        let flat = ContentFieldsQueries.findField({ id = FieldId.toInt64(id), projectId = Tenant.currentId() }) |> Option.map(ContentTypeRows.toFieldDef) |> CmsErr.orNotFound(Entity.Field, "${id}");
        FieldTree.find(id, fieldsOf(flat#typeId)) |> CmsErr.orNotFound(Entity.Field, "${id}")

    // ---- content type ----

    ///
    /// content type を作る。singular / plural を省けば apiId から導く。名前の規則に合わなければ invalid。
    ///
    pub def create(_proof: Granted[ManageTypes], draft: ContentTypeDraft): ContentType \ Db + CmsErr + IdGen + Tenant + Session =
        // 名前を揃える。singular / plural が無ければ apiId から導く
        let names = buildTypeNames(draft);
        let derived = Option.isEmpty(draft#singular) and Option.isEmpty(draft#plural);
        // 既存の全型と突き合わせて名前の規則を検査する。導いた名前の違反は apiId の物にする
        let others = listAll();
        CmsErr.raiseIfAny((typeNameViolations(others, names, Nil) |> List.map(violation -> if (derived) blameApiId(violation) else violation)) ::: iconViolations(draft#icon) ::: linkPathViolations(draft#linkPath));
        // 行を作り、型の変更を知らせる
        let inserted = ContentTypesQueries.insertContentType({ +projectId = Tenant.currentId() | ContentTypeRows.typeInsert(names, draft) }) |> Rows.expectId;
        Publishing.notify(PublishingEvent.SchemaChanged(names#apiId));
        Audit.record(AuditChange.TypeCreated(names#apiId));
        load(TypeId.TypeId(inserted))

    ///
    /// 作る型の apiId / singular / plural。省かれた singular / plural は apiId から導く。
    ///
    def buildTypeNames(draft: ContentTypeDraft): Naming.TypeNames =
        {
            apiId    = draft#apiId,
            singular = draft#singular |> Option.getWithDefault(Naming.deriveSingular(draft#apiId)),
            plural   = draft#plural |> Option.getWithDefault(Naming.derivePlural(draft#apiId))
        }

    ///
    /// singular / plural を導いた時の違反は apiId のせいなので、そこへ付け替える（渡していない項目を怒られても直せない）。
    ///
    def blameApiId(violation: Violation): Violation =
        let Violation.Violation(path, message) = violation;
        if (path == "apiId") violation
        else Violation.Violation("apiId", "apiId から導いた ${path} が使えません（${message}）。singular か plural を指定してください")

    ///
    /// content type を直す。触った項目だけ UPDATE に出る。名前を変えるなら規則を検査する。
    ///
    pub def update(_proof: Granted[ManageTypes], id: TypeId, changes: ContentTypeChanges): ContentType \ Db + CmsErr + IdGen + Tenant + Session =
        let existing = load(id);
        // 変えた後の名前（触っていない項目は今の物）
        let names = {
            apiId    = existing#apiId,
            singular = changes#singular |> Option.getWithDefault(existing#singular),
            plural   = changes#plural |> Option.getWithDefault(existing#plural)
        };
        // 自分を除いた全型と突き合わせて名前の規則を検査する（生える型名は自分のフィールドまで見る）
        let others = listAll() |> List.filter(other -> other#id != id);
        CmsErr.raiseIfAny(typeNameViolations(others, names, existing#fields) ::: iconViolations(changes#icon) ::: linkPathViolations(changes#linkPath));
        // 触った項目だけ UPDATE し、型の変更を知らせる
        discard ContentTypesQueries.updateContentType({ id = TypeId.toInt64(id), projectId = Tenant.currentId() }, ContentTypeRows.typeChanges(changes));
        Publishing.notify(PublishingEvent.SchemaChanged(existing#apiId));
        Audit.record(AuditChange.TypeUpdated(existing#apiId));
        load(id)

    ///
    /// content type をフィールドごと消す。無ければ notFound。entry が残っていれば、他の型から参照されていれば invalid。
    /// ゴミ箱の entry は型と一緒に消す（残すと型が消せない）。
    ///
    pub def delete(_proof: Granted[ManageTypes], id: TypeId): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let existing = load(id);
        let remaining = EntriesQueries.countEntriesOfType({ typeId = TypeId.toInt64(id), projectId = Tenant.currentId() }) |> Rows.total;
        let referrers = ContentFieldsQueries.countFieldsTargeting({ typeId = TypeId.toInt64(id), projectId = Tenant.currentId() }) |> Rows.total;
        CmsErr.raiseIfAny(
            (if (remaining == 0i64) Nil else Violation.Violation("id", "entry が ${remaining} 件あります。先に消してください") :: Nil)
            ::: (if (referrers == 0i64) Nil else Violation.Violation("id", "他の型の REFERENCE のフィールド ${referrers} 本が参照先にしています。先にそのフィールドを消してください") :: Nil));
        discard EntriesQueries.purgeDeletedEntries({ typeId = TypeId.toInt64(id), projectId = Tenant.currentId() });
        discard ContentTypesQueries.deleteContentType({ id = TypeId.toInt64(id), projectId = Tenant.currentId() });
        Publishing.notify(PublishingEvent.SchemaChanged(existing#apiId));
        Audit.record(AuditChange.TypeDeleted(existing#apiId))

    // ---- フィールド ----

    ///
    /// フィールドを末尾に足す。apiId の規則と config の組み合わせを検査する。parent があればその子（object の子か blocks の variant）になる。
    ///
    pub def addField(_proof: Granted[ManageTypes], typeId: TypeId, draft: FieldDraft): FieldDef \ Db + CmsErr + IdGen + Tenant + Session =
        let owner = load(typeId);
        let parent = draft#parent |> Option.map(parentId -> FieldTree.find(parentId, owner#fields) |> CmsErr.orNotFound(Entity.Field, "${parentId}"));
        CmsErr.raiseIfAny(validateDraft(takenApiIds(owner#fields, None), parent, draft) ::: targetTypeExists(draft#target) ::: fieldTypeNameViolations(owner, draft));
        let position = match draft#parent {
            case Some(parentId) => ContentFieldsQueries.nextChildPosition({ parentFieldId = FieldId.toInt64(parentId), projectId = Tenant.currentId() }) |> Rows.nextPosition
            case None           => ContentFieldsQueries.nextFieldPosition({ typeId = TypeId.toInt64(typeId), projectId = Tenant.currentId() }) |> Rows.nextPosition
        };
        let inserted = ContentFieldsQueries.insertField(ContentTypeRows.fieldInsert(typeId, position, draft)) |> Rows.expectId;
        Option.forEach(target -> discard ContentFieldsQueries.setFieldTarget({ id = inserted, targetTypeId = TypeId.toInt64(target), projectId = Tenant.currentId() }), draft#target);
        Option.forEach(parentId -> discard ContentFieldsQueries.setFieldParent({ id = inserted, parentFieldId = FieldId.toInt64(parentId), projectId = Tenant.currentId() }), draft#parent);
        discard touch(typeId);
        Audit.record(AuditChange.FieldAdded(owner#apiId, "${draft#apiId}"));
        loadField(FieldId.FieldId(inserted))

    ///
    /// フィールドを直す。触った項目だけ UPDATE に出る。config は丸ごと置き換える。
    ///
    pub def updateField(_proof: Granted[ManageTypes], id: FieldId, changes: FieldChanges): FieldDef \ Db + CmsErr + IdGen + Tenant + Session =
        let existing = loadField(id);
        let taken = takenApiIds(fieldsOf(existing#typeId), Some(id));
        let config = changes#config |> Option.getWithDefault(existing#config);
        let unique = changes#unique |> Option.getWithDefault(existing#unique);
        let required = changes#required |> Option.getWithDefault(existing#required);
        CmsErr.raiseIfAny(Naming.validateFlags({ unique = unique | existing }) ::: Naming.validateChildFlags({ hasParent = Option.nonEmpty(existing#parent), required = required, unique = unique }) ::: Naming.validateConfig(taken, existing#kind, config));
        discard ContentFieldsQueries.updateField({ id = FieldId.toInt64(id), projectId = Tenant.currentId() }, ContentTypeRows.fieldChanges(changes));
        Audit.record(AuditChange.FieldUpdated(touch(existing#typeId), "${existing#apiId}"));
        loadField(id)

    ///
    /// フィールドを消す。無ければ notFound。
    ///
    pub def removeField(_proof: Granted[ManageTypes], id: FieldId): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let existing = loadField(id);
        discard ContentFieldsQueries.deleteField({ id = FieldId.toInt64(id), projectId = Tenant.currentId() });
        Audit.record(AuditChange.FieldRemoved(touch(existing#typeId), "${existing#apiId}"))

    ///
    /// ids の順に並べ直す。最上位のフィールドを過不足なく渡さなければ invalid。object / blocks の子は対象外。
    ///
    pub def reorderFields(_proof: Granted[ManageTypes], typeId: TypeId, ids: List[FieldId]): ContentType \ Db + CmsErr + IdGen + Tenant + Session =
        let owner = load(typeId);
        let current = owner#fields |> List.map(field -> field#id) |> List.toSet;
        let sameSet = List.length(ids) == Set.size(current) and List.toSet(ids) == current;
        CmsErr.raiseIfAny(if (sameSet) Nil else Violation.Violation("ids", "最上位のフィールドの id を過不足なく、重複なく渡してください") :: Nil);
        List.forEachWithIndex((index, id) -> discard ContentFieldsQueries.setFieldPosition({ id = FieldId.toInt64(id), position = index, projectId = Tenant.currentId() }), ids);
        discard touch(typeId);
        Audit.record(AuditChange.FieldsReordered(owner#apiId));
        load(typeId)

    // ---- 部品 ----

    ///
    /// 足すフィールドの純粋な検査。apiId の規則と重なり、性質の組み合わせ、参照先の指定、親との相性、config。
    ///
    def validateDraft(taken: List[ApiId], parent: Option[FieldDef], draft: FieldDraft): List[Violation] =
        Naming.validateFieldApiId(taken, draft#apiId)
            ::: Naming.validateFlags(draft)
            ::: Naming.validateTarget(draft#kind, draft#target)
            ::: Naming.validateParent(parent |> Option.map(found -> found#kind), draft#kind, draft#many)
            ::: Naming.validateChildFlags({ hasParent = Option.nonEmpty(parent), required = draft#required, unique = draft#unique })
            ::: Naming.validateConfig(taken, draft#kind, draft#config)

    ///
    /// 参照先の型が DB にある事（kind と target の組み合わせは Naming.validateTarget）。
    ///
    def targetTypeExists(target: Option[TypeId]): List[Violation] \ DbRead + Tenant = match target {
        case Some(typeId) => if (Option.isEmpty(lookup(typeId))) Violation.Violation("targetTypeId", "型 '${typeId}' がありません") :: Nil else Nil
        case None         => Nil
    }

    ///
    /// 足すフィールドが生やす型名が、全型（自分を含む）の生やす型名と重ならない事。prefix は親の入れ子の型名まで。
    ///
    def fieldTypeNameViolations(owner: ContentType, draft: FieldDraft): List[Violation] \ DbRead + Tenant =
        let ancestors = draft#parent |> Option.flatMap(parentId -> FieldTree.ancestors(parentId, owner#fields)) |> Option.getWithDefault(Nil);
        let prefix = ancestors |> List.foldLeft((acc, ancestor) -> Naming.nestedTypeName(acc, ancestor#apiId), TypeName.text(owner#singular));
        let asField = { id = FieldId.FieldId(0i64), typeId = owner#id, apiId = draft#apiId, name = draft#name, kind = draft#kind, many = draft#many, required = draft#required, unique = draft#unique, localized = draft#localized, target = draft#target, parent = draft#parent, children = Children.none(), config = draft#config, position = 0 };
        Naming.validateFieldTypeNames(List.flatMap(schemaTypeNamesOf, listAll()), prefix, asField)

    ///
    /// 型の名前の検査。名前の規則（既存の型との衝突）に通ってから、生える型名との衝突を見る（apiId が重なっていれば型名も重なるので、同じ原因を二度言わない）。
    ///
    def typeNameViolations(others: List[ContentType], names: Naming.TypeNames, fields: List[FieldDef]): List[Violation] =
        match Naming.validateType(List.map(namesOf, others), names) {
            case Nil        => Naming.validateSchemaTypeNames(List.flatMap(schemaTypeNamesOf, others), names#singular, fields)
            case violations => violations
        }

    ///
    /// 渡された時だけアイコンの識別子を検査する。省けば作る時は kind ごとの既定、直す時は今の値のまま。
    ///
    def iconViolations(icon: Option[String]): List[Violation] =
        icon |> Option.map(text -> Naming.validateIcon("icon", text)) |> Option.getWithDefault(Nil)

    def linkPathViolations(linkPath: Option[String]): List[Violation] =
        linkPath |> Option.map(text -> LinkPath.check("linkPath", text)) |> Option.getWithDefault(Nil)

    def namesOf(contentType: ContentType): Naming.TypeNames =
        { apiId = contentType#apiId, singular = contentType#singular, plural = contentType#plural }

    def schemaTypeNamesOf(contentType: ContentType): List[String] =
        Naming.schemaTypeNames(contentType#singular, contentType#fields)

    ///
    /// 型の中で既に使われている apiId（深さ問わず。子の名前も型の中で重ねない）。excluded は自分（直す時）。
    ///
    def takenApiIds(tree: List[FieldDef], excluded: Option[FieldId]): List[ApiId] =
        FieldTree.flatten(tree) |> List.filter(field -> Some(field#id) != excluded) |> List.map(field -> field#apiId)

    ///
    /// 型のフィールドの木。
    ///
    def fieldsOf(typeId: TypeId): List[FieldDef] \ DbRead + Tenant =
        ContentFieldsQueries.listFieldsOfType({ typeId = TypeId.toInt64(typeId), projectId = Tenant.currentId() }) |> List.map(ContentTypeRows.toFieldDef) |> FieldTree.build

    ///
    /// 型の updated_at を今にする。フィールドを触った時も型が変わった事にする。型の apiId を返す。
    ///
    /// WhyNot: apiId を捨てないのは、ここで既に型を読んでいるため。呼ぶ側が監査のために読み直すと、
    /// フィールドを触るたびに型とフィールドの SELECT が 2 本増える。
    ///
    def touch(typeId: TypeId): ApiId \ Db + CmsErr + IdGen + Tenant =
        discard ContentTypesQueries.touchContentType({ id = TypeId.toInt64(typeId), projectId = Tenant.currentId() });
        let apiId = load(typeId)#apiId;
        Publishing.notify(PublishingEvent.SchemaChanged(apiId));
        apiId

}
