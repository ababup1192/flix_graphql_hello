///
/// content type とフィールドの定義を読み書きするユースケース。生成された ContentTypesQueries / ContentFieldsQueries を並べる層。
/// 型に `\ DbRead` か `\ Db + CmsErr` が出る。名前の規則は Naming、行と値の変換は ContentModel。
///
/// WhyNot: 一意制約の違反を onConstraint で翻訳しないのは、Runner が Mutation 全体を 1 つの Tx に包んでいて、
/// 違反で abort した Tx の中では翻訳しても COMMIT が失敗するため。同じ Tx の中で先に読んで検査するので、
/// 制約に当たるのは同時に同じ名前を作った時だけで、それは DbErr のまま 500 にする。
///
mod ContentTypes {

    use GeneratedAdmin.ContentTypeInput
    use GeneratedAdmin.ContentTypePatch
    use GeneratedAdmin.FieldInput
    use GeneratedAdmin.FieldPatch
    use GeneratedAdmin.TypeKind

    // ---- 読む ----

    ///
    /// 全 content type。apiId 順、フィールド付き。SQL は 2 本。
    ///
    pub def list(): List[ContentType] \ DbRead =
        let fields = ContentFieldsQueries.listAllFields() |> List.map(fieldOrRaise);
        ContentTypesQueries.listContentTypes()
            |> List.map(row -> typeOrRaise(row, fields |> List.filter(field -> field#typeId == row#id)))

    ///
    /// id で 1 つ。無ければ None。
    ///
    pub def find(id: Int64): Option[ContentType] \ DbRead =
        ContentTypesQueries.findContentType(id) |> Option.map(row -> typeOrRaise(row, fieldsOf(id)))

    ///
    /// apiId で 1 つ。無ければ None。
    ///
    pub def findByApiId(apiId: String): Option[ContentType] \ DbRead =
        ContentTypesQueries.findContentTypeByApiId(apiId) |> Option.map(row -> typeOrRaise(row, fieldsOf(row#id)))

    ///
    /// id で 1 つ。無ければ notFound。
    ///
    pub def get(id: Int64): ContentType \ DbRead + CmsErr =
        find(id) |> orNotFound("content type", Int64.toString(id))

    ///
    /// フィールド 1 つ。無ければ notFound。
    ///
    pub def getField(id: Int64): FieldDef \ DbRead + CmsErr =
        ContentFieldsQueries.findField(id) |> Option.map(fieldOrRaise) |> orNotFound("field", Int64.toString(id))

    // ---- content type ----

    ///
    /// content type を作る。singular / plural を省けば apiId から導く。名前の規則に合わなければ invalid。
    ///
    pub def create(input: ContentTypeInput): ContentType \ Db + CmsErr =
        let names = {
            apiId    = input#apiId,
            singular = input#singular |> Option.getWithDefault(Naming.deriveSingular(input#apiId)),
            plural   = input#plural |> Option.getWithDefault(Naming.derivePlural(input#apiId))
        };
        CmsErr.raiseIfAny(Naming.validateType(list() |> List.map(namesOf), names));
        let inserted = ContentTypesQueries.insertContentType({
            apiId      = names#apiId,
            kind       = ContentModel.typeKindToDb(input#kind |> Option.getWithDefault(TypeKind.Collection)),
            name       = input#name,
            singular   = names#singular,
            plural     = names#plural,
            previewUrl = input#previewUrl |> Option.getWithDefault("")
        }) |> expectRow;
        get(inserted)

    ///
    /// content type を直す。触った項目だけ UPDATE に出る。名前を変えるなら規則を検査する。
    ///
    pub def update(id: Int64, patch: ContentTypePatch): ContentType \ Db + CmsErr =
        let existing = get(id);
        let names = {
            apiId    = existing#apiId,
            singular = patch#singular |> Option.getWithDefault(existing#singular),
            plural   = patch#plural |> Option.getWithDefault(existing#plural)
        };
        let others = list() |> List.filter(other -> other#id != existing#id) |> List.map(namesOf);
        CmsErr.raiseIfAny(Naming.validateType(others, names));
        let changes = Fragment.noChange()
            |> Fragment.setIfSome(ContentTypesTable.name(), patch#name)
            |> Fragment.setIfSome(ContentTypesTable.singular(), patch#singular)
            |> Fragment.setIfSome(ContentTypesTable.plural(), patch#plural)
            |> Fragment.setIfSome(ContentTypesTable.previewUrl(), patch#previewUrl);
        discard ContentTypesQueries.updateContentType(id, changes);
        get(id)

    ///
    /// content type をフィールドごと消す。無ければ notFound。
    ///
    pub def delete(id: Int64): Unit \ Db + CmsErr =
        discard get(id);
        discard ContentTypesQueries.deleteContentType(id)

    // ---- フィールド ----

    ///
    /// フィールドを末尾に足す。apiId の規則と config の組み合わせを検査する。
    ///
    pub def addField(typeId: Int64, input: FieldInput): FieldDef \ Db + CmsErr =
        let owner = get(typeId);
        let siblings = owner#fields |> List.map(field -> field#apiId);
        let config = ContentModel.configOfInput(input#config);
        CmsErr.raiseIfAny(Naming.validateFieldApiId(siblings, input#apiId) ::: Naming.validateConfig(siblings, input#kind, config));
        let position = ContentFieldsQueries.nextFieldPosition(typeId) |> Option.flatMap(row -> row#next) |> Option.getWithDefault(0);
        let inserted = ContentFieldsQueries.insertField({
            typeId      = typeId,
            apiId       = input#apiId,
            name        = input#name,
            kind        = ContentModel.fieldKindToDb(input#kind),
            isMany      = input#many |> Option.getWithDefault(false),
            isRequired  = input#required |> Option.getWithDefault(false),
            isUnique    = input#unique |> Option.getWithDefault(false),
            isLocalized = input#localized |> Option.getWithDefault(false),
            config      = ContentModel.configToJson(config),
            position    = position
        }) |> expectRow;
        discard ContentTypesQueries.touchContentType(typeId);
        getField(inserted)

    ///
    /// フィールドを直す。触った項目だけ UPDATE に出る。config は丸ごと置き換える。
    ///
    pub def updateField(id: Int64, patch: FieldPatch): FieldDef \ Db + CmsErr =
        let existing = getField(id);
        let siblings = fieldsOf(existing#typeId) |> List.filter(field -> field#id != existing#id) |> List.map(field -> field#apiId);
        let config = patch#config |> Option.map(given -> ContentModel.configOfInput(Some(given))) |> Option.getWithDefault(existing#config);
        CmsErr.raiseIfAny(Naming.validateConfig(siblings, existing#kind, config));
        let changes = Fragment.noChange()
            |> Fragment.setIfSome(ContentFieldsTable.name(), patch#name)
            |> Fragment.setIfSome(ContentFieldsTable.isRequired(), patch#required)
            |> Fragment.setIfSome(ContentFieldsTable.isUnique(), patch#unique)
            |> Fragment.setIfSome(ContentFieldsTable.isLocalized(), patch#localized)
            |> Fragment.setIfSome(ContentFieldsTable.config(), patch#config |> Option.map(_ -> ContentModel.configToJson(config)));
        discard ContentFieldsQueries.updateField(id, changes);
        discard ContentTypesQueries.touchContentType(existing#typeId);
        getField(id)

    ///
    /// フィールドを消す。無ければ notFound。
    ///
    pub def removeField(id: Int64): Unit \ Db + CmsErr =
        let existing = getField(id);
        discard ContentFieldsQueries.deleteField(id);
        discard ContentTypesQueries.touchContentType(existing#typeId)

    ///
    /// ids の順に並べ直す。型の全フィールドを過不足なく渡さなければ invalid。
    ///
    pub def reorderFields(typeId: Int64, ids: List[Int64]): ContentType \ Db + CmsErr =
        let owner = get(typeId);
        let current = owner#fields |> List.filterMap(field -> ContentModel.parseId(field#id));
        let sameSet = List.length(ids) == List.length(current) and List.forAll(id -> List.memberOf(id, current), ids) and List.length(List.distinct(ids)) == List.length(ids);
        CmsErr.raiseIfAny(if (sameSet) Nil else Violation.Violation("ids", "型の全フィールドの id を過不足なく、重複なく渡してください") :: Nil);
        List.forEachWithIndex((index, id) -> discard ContentFieldsQueries.setFieldPosition({ id = id, position = index }), ids);
        discard ContentTypesQueries.touchContentType(typeId);
        get(typeId)

    // ---- 部品 ----

    ///
    /// 型のフィールドを position 順で。
    ///
    def fieldsOf(typeId: Int64): List[FieldDef] \ DbRead =
        ContentFieldsQueries.listFieldsOfType(typeId) |> List.map(fieldOrRaise)

    ///
    /// 衝突の検査に使う名前の組。
    ///
    def namesOf(contentType: ContentType): Naming.TypeNames =
        { apiId = contentType#apiId, singular = contentType#singular, plural = contentType#plural }

    ///
    /// 行の変換に失敗したら DbErr（DDL の CHECK が守るので起きない）。
    ///
    def typeOrRaise(row: { id = Int64, apiId = String, kind = String, name = String, singular = String, plural = String, previewUrl = String, createdAt = Timestamp.Timestamp, updatedAt = Timestamp.Timestamp | r }, fields: List[FieldDef]): ContentType \ DbErr =
        match ContentModel.typeOfRow(row, fields) {
            case Ok(contentType) => contentType
            case Err(message)    => DbErr.other(message)
        }

    def fieldOrRaise(row: { id = Int64, typeId = Int64, apiId = String, name = String, kind = String, isMany = Bool, isRequired = Bool, isUnique = Bool, isLocalized = Bool, config = Util.Json.Json, position = Int32 | r }): FieldDef \ DbErr =
        match ContentModel.fieldOfRow(row) {
            case Ok(field)    => field
            case Err(message) => DbErr.other(message)
        }

    ///
    /// RETURNING id の行。無いのは DB かドライバの異常なので DbErr にする。
    ///
    def expectRow(row: Option[{ id = Int64 }]): Int64 \ DbErr = match row {
        case Some(found) => found#id
        case None        => DbErr.other("INSERT ... RETURNING returned no row")
    }

    def orNotFound(what: String, id: String, value: Option[a]): a \ CmsErr = match value {
        case Some(found) => found
        case None        => CmsErr.notFound(what, id)
    }

}
