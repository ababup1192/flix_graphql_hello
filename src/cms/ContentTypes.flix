///
/// content type とフィールドの定義を読み書きするユースケース。生成された ContentTypesQueries / ContentFieldsQueries を並べる層。
/// 型に `\ DbRead` か `\ Db + CmsErr` が出る。名前の規則は Naming、行と値の変換は ContentTypeRows、木の操作は FieldTree。
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
    pub def list(): List[ContentType] \ DbRead =
        let fieldsByType = ContentFieldsQueries.listAllFields() |> List.map(ContentTypeRows.toFieldDef)
            |> List.foldLeft((acc, field) -> Map.insertWith((newer, older) -> older ::: newer, field#typeId, field :: Nil, acc), Map.empty());
        ContentTypesQueries.listContentTypes()
            |> List.map(row -> ContentTypeRows.toContentType(row, Map.getWithDefault(TypeId.TypeId(row#id), Nil, fieldsByType) |> FieldTree.build))

    ///
    /// id で 1 つ。無ければ None。
    ///
    pub def find(id: TypeId): Option[ContentType] \ DbRead =
        ContentTypesQueries.findContentType(TypeId.toInt64(id)) |> Option.map(row -> ContentTypeRows.toContentType(row, fieldsOf(id)))

    ///
    /// apiId で 1 つ。無ければ None。
    ///
    pub def findByApiId(apiId: ApiId): Option[ContentType] \ DbRead =
        ContentTypesQueries.findContentTypeByApiId(ApiId.text(apiId)) |> Option.map(row -> ContentTypeRows.toContentType(row, fieldsOf(TypeId.TypeId(row#id))))

    ///
    /// id で 1 つ。無ければ notFound。
    ///
    pub def get(id: TypeId): ContentType \ DbRead + CmsErr =
        find(id) |> CmsErr.orNotFound(Entity.ContentType, "${id}")

    ///
    /// フィールド 1 つ（children 付き）。無ければ notFound。
    ///
    pub def getField(id: FieldId): FieldDef \ DbRead + CmsErr =
        let flat = ContentFieldsQueries.findField(FieldId.toInt64(id)) |> Option.map(ContentTypeRows.toFieldDef) |> CmsErr.orNotFound(Entity.Field, "${id}");
        FieldTree.find(id, fieldsOf(flat#typeId)) |> CmsErr.orNotFound(Entity.Field, "${id}")

    // ---- content type ----

    ///
    /// content type を作る。singular / plural を省けば apiId から導く。名前の規則に合わなければ invalid。
    ///
    pub def create(draft: ContentTypeDraft): ContentType \ Db + CmsErr =
        let names = {
            apiId    = draft#apiId,
            singular = draft#singular |> Option.getWithDefault(Naming.deriveSingular(draft#apiId)),
            plural   = draft#plural |> Option.getWithDefault(Naming.derivePlural(draft#apiId))
        };
        CmsErr.raiseIfAny(Naming.validateType(allNames(), names));
        let inserted = ContentTypesQueries.insertContentType(ContentTypeRows.typeInsert(names, draft)) |> Rows.expectId;
        get(TypeId.TypeId(inserted))

    ///
    /// content type を直す。触った項目だけ UPDATE に出る。名前を変えるなら規則を検査する。
    ///
    pub def update(id: TypeId, changes: ContentTypeChanges): ContentType \ Db + CmsErr =
        let existing = get(id);
        let names = {
            apiId    = existing#apiId,
            singular = changes#singular |> Option.getWithDefault(existing#singular),
            plural   = changes#plural |> Option.getWithDefault(existing#plural)
        };
        CmsErr.raiseIfAny(Naming.validateType(allNames() |> List.filter(other -> other#apiId != existing#apiId), names));
        discard ContentTypesQueries.updateContentType(TypeId.toInt64(id), ContentTypeRows.typeChanges(changes));
        get(id)

    ///
    /// content type をフィールドごと消す。無ければ notFound。entry が残っていれば invalid（先に entry を消す）。
    /// ゴミ箱の entry は型と一緒に消す（残すと型が消せない）。
    ///
    pub def delete(id: TypeId): Unit \ Db + CmsErr =
        discard get(id);
        let remaining = EntriesQueries.countEntriesOfType(TypeId.toInt64(id)) |> Rows.total;
        CmsErr.raiseIfAny(if (remaining == 0i64) Nil else Violation.Violation("id", "entry が ${remaining} 件あります。先に消してください") :: Nil);
        discard EntriesQueries.purgeDeletedEntries(TypeId.toInt64(id));
        discard ContentTypesQueries.deleteContentType(TypeId.toInt64(id))

    // ---- フィールド ----

    ///
    /// フィールドを末尾に足す。apiId の規則と config の組み合わせを検査する。parent があればその子（object の子か blocks の variant）になる。
    ///
    pub def addField(typeId: TypeId, draft: FieldDraft): FieldDef \ Db + CmsErr =
        let owner = get(typeId);
        let parent = draft#parent |> Option.map(parentId -> FieldTree.find(parentId, owner#fields) |> CmsErr.orNotFound(Entity.Field, "${parentId}"));
        CmsErr.raiseIfAny(validateDraft(takenApiIds(owner#fields, None), parent, draft) ::: validateTarget(draft#target));
        let position = match draft#parent {
            case Some(parentId) => ContentFieldsQueries.nextChildPosition(FieldId.toInt64(parentId)) |> Rows.next
            case None           => ContentFieldsQueries.nextFieldPosition(TypeId.toInt64(typeId)) |> Rows.next
        };
        let inserted = ContentFieldsQueries.insertField(ContentTypeRows.fieldInsert(typeId, position, draft)) |> Rows.expectId;
        Option.forEach(target -> discard ContentFieldsQueries.setFieldTarget({ id = inserted, targetTypeId = TypeId.toInt64(target) }), draft#target);
        Option.forEach(parentId -> discard ContentFieldsQueries.setFieldParent({ id = inserted, parentFieldId = FieldId.toInt64(parentId) }), draft#parent);
        touch(typeId);
        getField(FieldId.FieldId(inserted))

    ///
    /// フィールドを直す。触った項目だけ UPDATE に出る。config は丸ごと置き換える。
    ///
    pub def updateField(id: FieldId, changes: FieldChanges): FieldDef \ Db + CmsErr =
        let existing = getField(id);
        let taken = takenApiIds(fieldsOf(existing#typeId), Some(id));
        let config = changes#config |> Option.getWithDefault(existing#config);
        CmsErr.raiseIfAny(Naming.validateFlags(existing#kind, existing#many, changes#unique |> Option.getWithDefault(existing#unique)) ::: Naming.validateConfig(taken, existing#kind, config));
        discard ContentFieldsQueries.updateField(FieldId.toInt64(id), ContentTypeRows.fieldChanges(changes));
        touch(existing#typeId);
        getField(id)

    ///
    /// フィールドを消す。無ければ notFound。
    ///
    pub def removeField(id: FieldId): Unit \ Db + CmsErr =
        let existing = getField(id);
        discard ContentFieldsQueries.deleteField(FieldId.toInt64(id));
        touch(existing#typeId)

    ///
    /// ids の順に並べ直す。最上位のフィールドを過不足なく渡さなければ invalid。object / blocks の子は対象外。
    ///
    pub def reorderFields(typeId: TypeId, ids: List[FieldId]): ContentType \ Db + CmsErr =
        let owner = get(typeId);
        let current = owner#fields |> List.map(field -> field#id) |> List.toSet;
        let sameSet = List.length(ids) == Set.size(current) and List.toSet(ids) == current;
        CmsErr.raiseIfAny(if (sameSet) Nil else Violation.Violation("ids", "最上位のフィールドの id を過不足なく、重複なく渡してください") :: Nil);
        List.forEachWithIndex((index, id) -> discard ContentFieldsQueries.setFieldPosition({ id = FieldId.toInt64(id), position = index }), ids);
        touch(typeId);
        get(typeId)

    // ---- 部品 ----

    ///
    /// 足すフィールドの純粋な検査。apiId の規則と重なり、性質の組み合わせ、参照先の指定、親との相性、config。
    ///
    def validateDraft(taken: List[ApiId], parent: Option[FieldDef], draft: FieldDraft): List[Violation] =
        Naming.validateFieldApiId(taken, draft#apiId)
            ::: Naming.validateFlags(draft#kind, draft#many, draft#unique)
            ::: Naming.validateTarget(draft#kind, draft#target)
            ::: Naming.validateParent(parent |> Option.map(found -> found#kind), draft#kind)
            ::: Naming.validateConfig(taken, draft#kind, draft#config)

    ///
    /// 参照先の型がある事。
    ///
    def validateTarget(target: Option[TypeId]): List[Violation] \ DbRead = match target {
        case Some(typeId) => if (Option.isEmpty(find(typeId))) Violation.Violation("targetTypeId", "型 '${typeId}' がありません") :: Nil else Nil
        case None         => Nil
    }

    ///
    /// 型の中で既に使われている apiId（深さ問わず。子の名前も型の中で重ねない）。excluded は自分（直す時）。
    ///
    def takenApiIds(tree: List[FieldDef], excluded: Option[FieldId]): List[ApiId] =
        FieldTree.flatten(tree) |> List.filter(field -> Some(field#id) != excluded) |> List.map(field -> field#apiId)

    ///
    /// 全 content type の名前だけ（衝突の検査用）。SQL は 1 本。
    ///
    def allNames(): List[Naming.TypeNames] \ DbRead =
        ContentTypesQueries.listContentTypes() |> List.map(ContentTypeRows.toTypeNames)

    ///
    /// 型のフィールドの木。
    ///
    def fieldsOf(typeId: TypeId): List[FieldDef] \ DbRead =
        ContentFieldsQueries.listFieldsOfType(TypeId.toInt64(typeId)) |> List.map(ContentTypeRows.toFieldDef) |> FieldTree.build

    ///
    /// 型の updated_at を今にする。フィールドを触った時も型が変わった事にする。
    ///
    def touch(typeId: TypeId): Unit \ DbWrite =
        discard ContentTypesQueries.touchContentType(TypeId.toInt64(typeId))

}
