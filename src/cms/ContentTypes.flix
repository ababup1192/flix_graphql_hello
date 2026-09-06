///
/// content type とフィールドの定義を読み書きするユースケース。生成された ContentTypesQueries / ContentFieldsQueries を並べる層。
/// 型に `\ DbRead` か `\ Db + CmsErr` が出る。名前の規則は Naming、行と値の変換は ContentTypeRows。
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
        let fields = ContentFieldsQueries.listAllFields() |> List.map(ContentTypeRows.toFieldDef);
        ContentTypesQueries.listContentTypes()
            |> List.map(row -> ContentTypeRows.toContentType(row, fields |> List.filter(field -> field#typeId == TypeId.TypeId(row#id)) |> ContentTypeRows.toTree))

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
    /// フィールド 1 つ。無ければ notFound。
    ///
    pub def getField(id: FieldId): FieldDef \ DbRead + CmsErr =
        let flat = ContentFieldsQueries.findField(FieldId.toInt64(id)) |> Option.map(ContentTypeRows.toFieldDef) |> CmsErr.orNotFound(Entity.Field, "${id}");
        ContentTypeRows.findInTree(id, fieldsOf(flat#typeId)) |> Option.getWithDefault(flat)

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
        CmsErr.raiseIfAny(Naming.validateType(list() |> List.map(Naming.namesOf), names));
        let inserted = ContentTypesQueries.insertContentType({
            apiId      = ApiId.text(names#apiId),
            kind       = ContentTypeRows.typeKindToDb(draft#kind),
            name       = draft#name,
            singular   = TypeName.text(names#singular),
            plural     = ApiId.text(names#plural),
            previewUrl = draft#previewUrl |> Option.getWithDefault("")
        }) |> expectRow;
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
        let others = list() |> List.filter(other -> other#id != id) |> List.map(Naming.namesOf);
        CmsErr.raiseIfAny(Naming.validateType(others, names));
        let assignments = Fragment.noChange()
            |> Fragment.setIfSome(ContentTypesTable.name(), changes#name)
            |> Fragment.setIfSome(ContentTypesTable.singular(), changes#singular |> Option.map(TypeName.text))
            |> Fragment.setIfSome(ContentTypesTable.plural(), changes#plural |> Option.map(ApiId.text))
            |> Fragment.setIfSome(ContentTypesTable.previewUrl(), changes#previewUrl);
        discard ContentTypesQueries.updateContentType(TypeId.toInt64(id), assignments);
        get(id)

    ///
    /// content type をフィールドごと消す。無ければ notFound。entry が残っていれば invalid（先に entry を消す）。
    /// ゴミ箱の entry は型と一緒に消す（残すと型が消せない）。
    ///
    pub def delete(id: TypeId): Unit \ Db + CmsErr =
        discard get(id);
        let remaining = ContentEntries.countOfType(id);
        CmsErr.raiseIfAny(if (remaining == 0i64) Nil else Violation.Violation("id", "entry が ${remaining} 件あります。先に消してください") :: Nil);
        discard EntriesQueries.purgeDeletedEntries(TypeId.toInt64(id));
        discard ContentTypesQueries.deleteContentType(TypeId.toInt64(id))

    // ---- フィールド ----

    ///
    /// フィールドを末尾に足す。apiId の規則と config の組み合わせを検査する。
    ///
    pub def addField(typeId: TypeId, draft: FieldDraft): FieldDef \ Db + CmsErr =
        let owner = get(typeId);
        let everyField = ContentTypeRows.flatten(owner#fields);
        let parent = draft#parent |> Option.map(parentId -> ContentTypeRows.findInTree(parentId, owner#fields) |> CmsErr.orNotFound(Entity.Field, "${parentId}"));
        let siblings = everyField |> List.map(field -> field#apiId);
        CmsErr.raiseIfAny(Naming.validateFieldApiId(siblings, draft#apiId) ::: Naming.validateFlags(draft#kind, draft#many, draft#unique) ::: Naming.validateTarget(draft#kind, draft#target) ::: Naming.validateParent(parent |> Option.map(found -> found#kind), draft#kind) ::: Naming.validateConfig(siblings, draft#kind, draft#config));
        let targetMissing = match draft#target {
            case Some(target) => Option.isEmpty(find(target))
            case None         => false
        };
        CmsErr.raiseIfAny(if (targetMissing) Violation.Violation("targetTypeId", "型 '${draft#target |> Option.map(target -> "${target}") |> Option.getWithDefault("")}' がありません") :: Nil else Nil);
        let position = match draft#parent {
            case Some(parentId) => ContentFieldsQueries.nextChildPosition(FieldId.toInt64(parentId)) |> Option.flatMap(row -> row#next) |> Option.getWithDefault(0)
            case None           => ContentFieldsQueries.nextFieldPosition(TypeId.toInt64(typeId)) |> Option.flatMap(row -> row#next) |> Option.getWithDefault(0)
        };
        let inserted = ContentFieldsQueries.insertField({
            typeId      = TypeId.toInt64(typeId),
            apiId       = ApiId.text(draft#apiId),
            name        = draft#name,
            kind        = ContentTypeRows.fieldKindToDb(draft#kind),
            isMany      = draft#many,
            isRequired  = draft#required,
            isUnique    = draft#unique,
            isLocalized = draft#localized,
            config      = FieldConfig.toJson(draft#config),
            position    = position
        }) |> expectRow;
        Option.forEach(target -> discard ContentFieldsQueries.setFieldTarget({ id = inserted, targetTypeId = TypeId.toInt64(target) }), draft#target);
        Option.forEach(parentId -> discard ContentFieldsQueries.setFieldParent({ id = inserted, parentFieldId = FieldId.toInt64(parentId) }), draft#parent);
        touch(typeId);
        getField(FieldId.FieldId(inserted))

    ///
    /// フィールドを直す。触った項目だけ UPDATE に出る。config は丸ごと置き換える。
    ///
    pub def updateField(id: FieldId, changes: FieldChanges): FieldDef \ Db + CmsErr =
        let existing = getField(id);
        let siblings = ContentTypeRows.flatten(fieldsOf(existing#typeId)) |> List.filter(field -> field#id != id) |> List.map(field -> field#apiId);
        let config = changes#config |> Option.getWithDefault(existing#config);
        CmsErr.raiseIfAny(Naming.validateFlags(existing#kind, existing#many, changes#unique |> Option.getWithDefault(existing#unique)) ::: Naming.validateConfig(siblings, existing#kind, config));
        let assignments = Fragment.noChange()
            |> Fragment.setIfSome(ContentFieldsTable.name(), changes#name)
            |> Fragment.setIfSome(ContentFieldsTable.isRequired(), changes#required)
            |> Fragment.setIfSome(ContentFieldsTable.isUnique(), changes#unique)
            |> Fragment.setIfSome(ContentFieldsTable.isLocalized(), changes#localized)
            |> Fragment.setIfSome(ContentFieldsTable.config(), changes#config |> Option.map(FieldConfig.toJson));
        discard ContentFieldsQueries.updateField(FieldId.toInt64(id), assignments);
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
    /// 型のフィールドを position 順で。
    ///
    def fieldsOf(typeId: TypeId): List[FieldDef] \ DbRead =
        ContentFieldsQueries.listFieldsOfType(TypeId.toInt64(typeId)) |> List.map(ContentTypeRows.toFieldDef) |> ContentTypeRows.toTree

    ///
    /// 型の updated_at を今にする。フィールドを触った時も型が変わった事にする。
    ///
    def touch(typeId: TypeId): Unit \ DbWrite =
        discard ContentTypesQueries.touchContentType(TypeId.toInt64(typeId))

    ///
    /// RETURNING id の行。無いのは DB かドライバの異常なので DbErr にする。
    ///
    def expectRow(row: Option[{ id = Int64 }]): Int64 \ DbErr = match row {
        case Some(found) => found#id
        case None        => DbErr.other("INSERT ... RETURNING returned no row")
    }

}
