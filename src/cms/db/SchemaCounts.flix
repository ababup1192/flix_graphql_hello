///
/// スキーマの変更に当たる entry を数える。SQL を呼ぶだけで、判定はしない。
///
/// **数えるのは影響が空でない時だけ。** `$.**` の jsonpath は索引に乗らず、その型の
/// entry × stage を全部見る（150,000 件で 1 本 ~17ms の実測）。変更が無いのに数えると、
/// スキーマを触るたびにその代金を払う事になる。
///
mod SchemaCounts {

    ///
    /// 変更に出てくるフィールドを 1 本ずつ数える。同じフィールドが複数の変更に出ても 1 回だけ数える。
    ///
    pub def forChanges(changes: List[SchemaChange]): (List[FieldCount], List[TypeCount]) \ DbRead + Tenant =
        let fields = changes |> List.filterMap(fieldOf)
            |> List.map(field -> ((field#typeId, field#apiId), field)) |> List.toMap |> Map.valuesOf;
        let types = changes |> List.filterMap(typeOf) |> List.distinct;
        (fields |> List.map(count(changes)), types |> List.map(countType))

    /// 変更が指すフィールド。型ごとの変更には無い。
    def fieldOf(change: SchemaChange): Option[FieldDef] = match change {
        case SchemaChange.FieldRemoved(field)           => Some(field)
        case SchemaChange.FieldAdded(field)             => Some(field)
        case SchemaChange.FieldRequired(field)          => Some(field)
        case SchemaChange.FieldUnique(field)            => Some(field)
        case SchemaChange.FieldConfigNarrowed(field, _) => Some(field)
        case _                                          => None
    }

    def typeOf(change: SchemaChange): Option[TypeId] = match change {
        case SchemaChange.TypeRemoved(owner) => Some(owner#id)
        case _                               => None
    }

    ///
    /// フィールド 1 本の数え上げ。要る数だけを引く（unique を立てていないなら重複は数えない）。
    ///
    def count(changes: List[SchemaChange], field: FieldDef): FieldCount \ DbRead + Tenant =
        let owner = TypeId.toInt64(field#typeId);
        let tenant = Tenant.currentId();
        let key = ApiId.text(field#apiId);
        let path = pathOf(field#apiId);
        let byStage = SchemaImpactQueries.countFieldValues({ typeId = owner, path = path, projectId = tenant })
            |> List.map(row -> (row#stage, Rows.total(Some(row)))) |> List.toMap;
        {
            typeId = field#typeId,
            apiId = field#apiId,
            draft = Map.getWithDefault("draft", 0i64, byStage),
            published = Map.getWithDefault("published", 0i64, byStage),
            missingPublished =
                if (tightens(changes, field, isRequired)) SchemaImpactQueries.countMissingPublished({ typeId = owner, path = path, projectId = tenant }) |> Rows.total else 0i64,
            outsideConfig = match narrowed(changes, field) {
                case Some(Narrowing.Options(kept))             => SchemaImpactQueries.countOutsideOptions({ typeId = owner, apiId = key, options = kept, projectId = tenant }) |> Rows.total
                case Some(Narrowing.MaxLength(limit))          => SchemaImpactQueries.countOverLength({ typeId = owner, path = valuePath(field#apiId), limit = limit, projectId = tenant }) |> Rows.total
                case Some(Narrowing.Range(low, high, integer)) => SchemaImpactQueries.countOutsideRange({ typeId = owner, path = valuePath(field#apiId), low = low, high = high, integer = integer, projectId = tenant }) |> Rows.total
                case None                                      => 0i64
            },
            duplicatePublished =
                if (tightens(changes, field, isUnique)) SchemaImpactQueries.countDuplicatePublished({ typeId = owner, apiId = key, projectId = tenant }) |> Rows.total else 0i64
        }

    def countType(typeId: TypeId): TypeCount \ DbRead + Tenant =
        { typeId = typeId, entries = EntriesQueries.countEntriesOfType({ typeId = TypeId.toInt64(typeId), projectId = Tenant.currentId() }) |> Rows.total }

    ///
    /// フィールドの値を指す jsonpath。入れ子の子も拾うので `$.**`。
    ///
    /// 述語は `EntryValidation.hasValue` の写し（null・空文字・空の配列を値なしと見る）。
    /// ずれていないかは TestSchemaImpactPg が突き合わせる。
    ///
    pub def pathOf(apiId: ApiId): String =
        let key = ApiId.text(apiId);
        "$.**.\"${key}\" ? ((@.type() == \"string\" && @ != \"\") || (@.type() == \"array\" && @.size() > 0) || @.type() == \"number\" || @.type() == \"boolean\" || @.type() == \"object\")"

    def tightens(changes: List[SchemaChange], field: FieldDef, pick: SchemaChange -> Option[FieldDef]): Bool =
        changes |> List.exists(change -> pick(change) |> Option.map(found -> found#id == field#id) |> Option.getWithDefault(false))

    def isRequired(change: SchemaChange): Option[FieldDef] = match change {
        case SchemaChange.FieldRequired(field) => Some(field)
        case _                                 => None
    }

    def isUnique(change: SchemaChange): Option[FieldDef] = match change {
        case SchemaChange.FieldUnique(field) => Some(field)
        case _                               => None
    }

    ///
    /// config を締めた変更なら、どこをどこまで締めたか。締め方の判定は SchemaDiff が持つ。
    ///
    def narrowed(changes: List[SchemaChange], field: FieldDef): Option[Narrowing] =
        changes |> List.findMap(change -> match change {
            case SchemaChange.FieldConfigNarrowed(now, was) => if (now#id == field#id) SchemaDiff.narrowing(was, now#config) else None
            case _                                          => None
        })

    ///
    /// フィールドの値そのものを指す jsonpath（型は問わない）。長さや範囲は SQL 側で見る。
    ///
    def valuePath(apiId: ApiId): String = "$.**.\"${ApiId.text(apiId)}\""

}
