///
/// コンテンツ API のリゾルバが使う効果の和。読むだけ。書く関数を呼べばコンパイルで落ちる。
///
pub type alias ContentEff = {SqlRead, TransientDbErr, DbErr}

///
/// content type の定義からコンテンツ API の Schema を組む。型ごとに
/// `<singular>(id, stage)`、`<plural>(where, orderBy, first, skip, stage)`（singleton は `<singular>(stage)` だけ）と、
/// `<Singular>` / `<Singular>Where` / `<Singular>WhereLeaf` / `<Singular>OrderBy` / `<Singular>Connection` が生える。
///
/// WhyNot: Where の AND / OR を再帰させないのは、input 型のフィールド一覧が値として即時に要り、自分自身を含む型を
/// 組めないため。OR / AND は 1 段（WhereLeaf のリスト）に限る。microCMS の filters も平らだったので移行には足りる。
///
mod ContentSchemaBuilder {

    ///
    /// 型の定義から Schema を組む。定義が無ければ Query は `_types: Int!`（型の数）だけ（graphql-java は空の Query を許さない）。
    ///
    pub def build(types: List[ContentType], runner: Runner[ContentEff]): Schema =
        let rootFields = types |> List.flatMap(rootFieldsOf);
        let fallback = Schema.field0("_types", Out.int32(), (_context, _root) -> Ok(List.length(types))) |> Field.withDescription("content type の数。型を作るとここに Query が生える");
        Schema.make(Schema.objectType("Query", () -> fallback :: rootFields), None, runner)

    // ---- ルートのフィールド ----

    def rootFieldsOf(owner: ContentType): List[Field[Unit, ContentEff]] = match owner#kind {
        case TypeKind.Singleton  => singletonField(owner) :: Nil
        case TypeKind.Collection => oneField(owner) :: manyField(owner) :: Nil
    }

    ///
    /// `<singular>(id: ID!, stage: Stage = PUBLISHED): <Singular>`
    ///
    def oneField(owner: ContentType): Field[Unit, ContentEff] =
        Schema.field2(queryName(owner), Schema.arg("id", GqlCodec.id()), stageArg(), Out.option(Out.obj(entryType(owner))), (_context, _root, id, stage) -> {
            let Id.Id(text) = id;
            Ok(EntryId.parse(text) |> Option.flatMap(entryId -> ContentEntries.findByStage(entryId, stageOrDefault(stage))) |> Option.filter(entry -> entry#typeId == owner#id))
        }) |> Field.withDescription("${TypeName.text(owner#singular)} を id で 1 つ。無ければ null")

    ///
    /// `<singular>(stage: Stage = PUBLISHED): <Singular>`（singleton）
    ///
    def singletonField(owner: ContentType): Field[Unit, ContentEff] =
        Schema.field1(queryName(owner), stageArg(), Out.option(Out.obj(entryType(owner))), (_context, _root, stage) ->
            Ok(ContentEntries.firstByStage(owner, stageOrDefault(stage))))
            |> Field.withDescription("${TypeName.text(owner#singular)}（1 件だけ）")

    ///
    /// `<plural>(where, orderBy, first, skip, stage): <Singular>Connection!`
    ///
    def manyField(owner: ContentType): Field[Unit, ContentEff] =
        let whereArg = Schema.arg("where", GqlCodec.option(whereCodec(owner)));
        let orderArg = Schema.arg("orderBy", GqlCodec.option(GqlCodec.list(orderByCodec(owner))));
        let firstArg = Schema.arg("first", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(20));
        let skipArg = Schema.arg("skip", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(0));
        let stage = stageArg();
        let infos = Arg.info(whereArg) :: Arg.info(orderArg) :: Arg.info(firstArg) :: Arg.info(skipArg) :: Arg.info(stage) :: Nil;
        Schema.fieldRaw(ApiId.text(owner#plural), infos, Out.obj(connectionType(owner)), (_context, _root, args) ->
            forM (
                filter  <- Arg.decode(whereArg, args);
                orderBy <- Arg.decode(orderArg, args);
                first   <- Arg.decode(firstArg, args);
                skip    <- Arg.decode(skipArg, args);
                atStage <- Arg.decode(stage, args)
            ) yield ContentEntries.listByStage(owner, stageOrDefault(atStage), {
                filter  = filter |> Option.getWithDefault(Nil),
                orderBy = orderBy |> Option.getWithDefault(Nil),
                first   = first |> Option.getWithDefault(20) |> Int32.max(1) |> Int32.min(200),
                skip    = skip |> Option.getWithDefault(0) |> Int32.max(0)
            }))
            |> Field.withDescription("${TypeName.text(owner#singular)} の一覧")

    ///
    /// 1 件クエリの名前。singular の先頭を小文字にした物（Blog → blog）。
    ///
    def queryName(owner: ContentType): String =
        let text = TypeName.text(owner#singular);
        String.toLowerCase(String.takeLeft(1, text)) + String.dropLeft(1, text)

    // ---- 型 ----

    ///
    /// `<Singular>`。共通のフィールドと、定義されたフィールド。
    ///
    def entryType(owner: ContentType): ObjectType[Entry, ContentEff] =
        Schema.objectType(TypeName.text(owner#singular), () ->
            Schema.field0("id", Out.id(), (_context, entry) -> Ok(Id.Id(EntryId.text(entry#id)))) ::
            Schema.field0("stage", Out.scalar(stageCodec()), (_context, entry) -> Ok(entry#stage)) ::
            Schema.field0("publishedAt", Out.option(Out.string()), (_context, entry) -> Ok(entry#publishedAt |> Option.map(Timestamp.toIso8601))) ::
            Schema.field0("createdAt", Out.string(), (_context, entry) -> Ok(Timestamp.toIso8601(entry#createdAt))) ::
            Schema.field0("updatedAt", Out.string(), (_context, entry) -> Ok(Timestamp.toIso8601(entry#updatedAt))) ::
            List.map(customField, owner#fields))
            |> ObjectType.withDescription(owner#name)

    ///
    /// 定義されたフィールド 1 つ。kind と many で GraphQL の型が決まり、値は中身の JSON から取り出す。
    ///
    def customField(field: FieldDef): Field[Entry, ContentEff] =
        let name = ApiId.text(field#apiId);
        let described = fieldDescription(field);
        match (field#kind, field#many) {
            case (FieldKind.Number, false)  => Schema.field0(name, Out.option(Out.float64()), (_context, entry) -> Ok(EntryValues.number(field#apiId, entry#data))) |> described
            case (FieldKind.Number, true)   => Schema.field0(name, Out.list(Out.float64()), (_context, entry) -> Ok(EntryValues.numbers(field#apiId, entry#data))) |> described
            case (FieldKind.Boolean, false) => Schema.field0(name, Out.option(Out.bool()), (_context, entry) -> Ok(EntryValues.bool(field#apiId, entry#data))) |> described
            case (FieldKind.Boolean, true)  => Schema.field0(name, Out.list(Out.bool()), (_context, entry) -> Ok(EntryValues.bools(field#apiId, entry#data))) |> described
            case (_, false)                 => Schema.field0(name, Out.option(Out.string()), (_context, entry) -> Ok(EntryValues.text(field#apiId, entry#data))) |> described
            case (_, true)                  => Schema.field0(name, Out.list(Out.string()), (_context, entry) -> Ok(EntryValues.texts(field#apiId, entry#data))) |> described
        }

    def fieldDescription(field: FieldDef): Field[Entry, ContentEff] -> Field[Entry, ContentEff] =
        if (field#name == "") (built -> built) else Field.withDescription(field#name)

    ///
    /// `<Singular>Connection { nodes, totalCount }`
    ///
    def connectionType(owner: ContentType): ObjectType[EntryPage, ContentEff] =
        Schema.objectType("${TypeName.text(owner#singular)}Connection", () ->
            Schema.field0("nodes", Out.list(Out.obj(entryType(owner))), (_context, page) -> Ok(page#entries)) ::
            Schema.field0("totalCount", Out.int32(), (_context, page) -> Ok(Int64.clampToInt32(min = 0, max = Int32.maxValue(), page#totalCount))) :: Nil)

    // ---- 引数 ----

    ///
    /// `stage: Stage = PUBLISHED`
    ///
    def stageArg(): Arg[Option[Stage]] =
        Schema.arg("stage", GqlCodec.option(stageCodec())) |> Arg.withDefaultValue(Value.Str("PUBLISHED"))

    def stageOrDefault(given: Option[Stage]): Stage = given |> Option.getWithDefault(Stage.Published)

    def stageCodec(): GqlCodec[Stage] =
        GqlCodec.enumOf("Stage", stage -> match stage { case Stage.Draft => "DRAFT" case Stage.Published => "PUBLISHED" }, Stage.Draft :: Stage.Published :: Nil)
            |> GqlCodec.describe("entry の状態。省けば公開中の物")

    ///
    /// `<Singular>OrderBy` の enum。共通のキーと、配列でないフィールド。
    ///
    def orderByCodec(owner: ContentType): GqlCodec[(SortKey, Direction)] =
        let keys = SortKey.ById :: SortKey.ByPublishedAt :: SortKey.ByUpdatedAt :: SortKey.ByCreatedAt ::
            (owner#fields |> List.filter(field -> not field#many) |> List.map(field -> SortKey.ByField(field#apiId)));
        let values = keys |> List.flatMap(key -> (key, Direction.Asc) :: (key, Direction.Desc) :: Nil);
        GqlCodec.enumOf("${TypeName.text(owner#singular)}OrderBy", orderByName, values)

    def orderByName(term: (SortKey, Direction)): String =
        let (key, direction) = term;
        let keyName = match key {
            case SortKey.ById           => "id"
            case SortKey.ByPublishedAt  => "publishedAt"
            case SortKey.ByUpdatedAt    => "updatedAt"
            case SortKey.ByCreatedAt    => "createdAt"
            case SortKey.ByField(apiId) => ApiId.text(apiId)
        };
        match direction {
            case Direction.Asc  => "${keyName}_ASC"
            case Direction.Desc => "${keyName}_DESC"
        }

    ///
    /// `<Singular>Where`。葉の条件と、OR / AND（それぞれ WhereLeaf のリスト）。
    ///
    def whereCodec(owner: ContentType): GqlCodec[Where] =
        let leaf = leafCodec(owner);
        let orArg = Schema.arg("OR", GqlCodec.option(GqlCodec.list(leaf)));
        let andArg = Schema.arg("AND", GqlCodec.option(GqlCodec.list(leaf)));
        let leaves = leafArgs(owner);
        let infos = List.map(leafInfo, leaves) ::: Arg.info(andArg) :: Arg.info(orArg) :: Nil;
        GqlCodec.inputObject("${TypeName.text(owner#singular)}Where", infos, fields ->
            forM (
                own  <- decodeLeaves(leaves, fields);
                ands <- Arg.decodeField(andArg, fields);
                ors  <- Arg.decodeField(orArg, fields)
            ) yield {
                let anded = ands |> Option.getWithDefault(Nil) |> List.flatten;
                let ored = match ors |> Option.getWithDefault(Nil) {
                    case Nil    => Nil
                    case groups => Condition.AnyOf(groups) :: Nil
                };
                own ::: anded ::: ored
            })

    ///
    /// `<Singular>WhereLeaf`。葉の条件だけ（OR / AND を持たない）。
    ///
    def leafCodec(owner: ContentType): GqlCodec[Where] =
        let leaves = leafArgs(owner);
        GqlCodec.inputObject("${TypeName.text(owner#singular)}WhereLeaf", List.map(leafInfo, leaves), fields -> decodeLeaves(leaves, fields))

    ///
    /// 葉の条件の引数 1 つ。SDL に出す情報と、入力から条件を取り出す関数の組。
    ///
    /// - info: 引数の名前と型
    /// - decode: 入力の Map から条件（無ければ空）
    ///
    type alias LeafArg = { info = ArgInfo, decode = Args -> Result[String, List[Condition]] }

    def leafInfo(leaf: LeafArg): ArgInfo = leaf#info

    def decodeLeaves(leaves: List[LeafArg], fields: Args): Result[String, Where] =
        Result.traverse(leaf -> (leaf#decode)(fields), leaves) |> Result.map(List.flatten)

    def leafArg(name: String, codec: GqlCodec[a], toConditions: a -> List[Condition]): LeafArg =
        let arg = Schema.arg(name, GqlCodec.option(codec));
        { info = Arg.info(arg), decode = fields -> Arg.decodeField(arg, fields) |> Result.map(found -> found |> Option.map(toConditions) |> Option.getWithDefault(Nil)) }

    ///
    /// 型の全フィールドの葉の条件。id は _eq / _in、フィールドは kind ごと。配列のフィールドは _isNull だけ。
    ///
    def leafArgs(owner: ContentType): List[LeafArg] =
        leafArg("id_eq", GqlCodec.id(), id -> { let Id.Id(text) = id; EntryId.parse(text) |> Option.map(Condition.IdEq) |> Option.toList }) ::
        leafArg("id_in", GqlCodec.list(GqlCodec.id()), ids -> Condition.IdIn(ids |> List.filterMap(id -> { let Id.Id(text) = id; EntryId.parse(text) })) :: Nil) ::
        List.flatMap(fieldLeafArgs, owner#fields)

    def fieldLeafArgs(field: FieldDef): List[LeafArg] =
        let apiId = field#apiId;
        let name = ApiId.text(apiId);
        let isNull = leafArg("${name}_isNull", GqlCodec.bool(), flag -> Condition.IsNull(apiId, flag) :: Nil);
        match (field#kind, field#many) {
            case (_, true) => isNull :: Nil
            case (FieldKind.Number, false) =>
                isNull ::
                leafArg("${name}_eq", GqlCodec.float64(), x -> Condition.NumberEq(apiId, x) :: Nil) ::
                leafArg("${name}_gt", GqlCodec.float64(), x -> Condition.NumberGt(apiId, x) :: Nil) ::
                leafArg("${name}_gte", GqlCodec.float64(), x -> Condition.NumberGte(apiId, x) :: Nil) ::
                leafArg("${name}_lt", GqlCodec.float64(), x -> Condition.NumberLt(apiId, x) :: Nil) ::
                leafArg("${name}_lte", GqlCodec.float64(), x -> Condition.NumberLte(apiId, x) :: Nil) :: Nil
            case (FieldKind.Boolean, false) =>
                isNull :: leafArg("${name}_eq", GqlCodec.bool(), b -> Condition.BoolEq(apiId, b) :: Nil) :: Nil
            case (_, false) =>
                isNull ::
                leafArg("${name}_eq", GqlCodec.string(), text -> Condition.TextEq(apiId, text) :: Nil) ::
                leafArg("${name}_in", GqlCodec.list(GqlCodec.string()), texts -> Condition.TextIn(apiId, texts) :: Nil) ::
                leafArg("${name}_contains", GqlCodec.string(), text -> Condition.TextContains(apiId, text) :: Nil) ::
                leafArg("${name}_startsWith", GqlCodec.string(), text -> Condition.TextStartsWith(apiId, text) :: Nil) :: Nil
        }

}

///
/// entry の中身（JSON）から kind ごとの値を取り出す。形が違う値は無い物として扱う（下書きの検証が守るので普段は起きない）。
///
mod EntryValues {

    use Util.Json.Json

    pub def text(apiId: ApiId, data: EntryData): Option[String] =
        Map.get(apiId, data) |> Option.flatMap(asText)

    pub def texts(apiId: ApiId, data: EntryData): List[String] =
        Map.get(apiId, data) |> Option.map(items(asText)) |> Option.getWithDefault(Nil)

    pub def number(apiId: ApiId, data: EntryData): Option[Float64] =
        Map.get(apiId, data) |> Option.flatMap(asNumber)

    pub def numbers(apiId: ApiId, data: EntryData): List[Float64] =
        Map.get(apiId, data) |> Option.map(items(asNumber)) |> Option.getWithDefault(Nil)

    pub def bool(apiId: ApiId, data: EntryData): Option[Bool] =
        Map.get(apiId, data) |> Option.flatMap(asBool)

    pub def bools(apiId: ApiId, data: EntryData): List[Bool] =
        Map.get(apiId, data) |> Option.map(items(asBool)) |> Option.getWithDefault(Nil)

    def items(pick: Json -> Option[a], json: Json): List[a] = match json {
        case Json.JArray(values) => values |> Vector.toList |> List.filterMap(pick)
        case _                   => Nil
    }

    def asText(json: Json): Option[String] = match json {
        case Json.JString(s) => Some(s)
        case _               => None
    }

    def asNumber(json: Json): Option[Float64] = match json {
        case Json.JNumber(n) => BigDecimal.tryToFloat64(n)
        case _               => None
    }

    def asBool(json: Json): Option[Bool] = match json {
        case Json.JBool(b) => Some(b)
        case _             => None
    }

}
