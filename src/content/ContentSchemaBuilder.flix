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
    /// 型の定義から Schema を組む。`_types: Int!`（型の数）は常に生やす（graphql-java は空の Query を許さないので、型が無くても組める）。
    ///
    pub def build(types: List[ContentType], runner: Runner[ContentEff]): Schema =
        // 型を生やせないフィールド（空の OBJECT / BLOCKS）を落とした定義で組む
        let buildable = types |> List.map(owner -> { fields = withShape(owner#fields) | owner });
        // 型ごとの Query のフィールド（singleton は 1 つ、collection は 1 件と一覧）
        let rootFields = buildable |> List.flatMap(rootFieldsOf(buildable));
        let typeCount = Schema.field0("_types", Out.int32(), (_context, _root) -> Ok(List.length(types))) |> Field.withDescription("content type の数。型を作るとここに Query が生える");
        Schema.make(Schema.objectType("Query", () -> typeCount :: rootFields), None, runner)

    ///
    /// 型を生やせるフィールドだけ残す。子の無い OBJECT と、子（variant）の無い BLOCKS は落とす。
    ///
    /// WhyNot: 空の型を生やさないのは、graphql-java が `type X {}` / `union X =` を受け付けず、親を作ってから子を足す
    /// 途中の 1 フィールドでコンテンツ API 全体が組めなくなるため。子を足せば次の組み直しで生える。
    ///
    def withShape(fields: List[FieldDef]): List[FieldDef] =
        fields |> List.filterMap(field -> match field#kind {
            case FieldKind.Object => withShape(Children.toList(field#children)) |> nonEmptyChildren(field)
            case FieldKind.Blocks => withShape(Children.toList(field#children)) |> nonEmptyChildren(field)
            case _                => Some(field)
        })

    def nonEmptyChildren(field: FieldDef, children: List[FieldDef]): Option[FieldDef] =
        if (List.isEmpty(children)) None else Some({ children = Children.Children(children) | field })

    // ---- ルートのフィールド ----

    def rootFieldsOf(all: List[ContentType], owner: ContentType): List[Field[Unit, ContentEff]] = match owner#kind {
        case TypeKind.Singleton  => singletonField(all, owner) :: Nil
        case TypeKind.Collection => oneField(all, owner) :: manyField(all, owner) :: Nil
    }

    ///
    /// `<singular>(id: ID!, stage: Stage = PUBLISHED): <Singular>`
    ///
    def oneField(all: List[ContentType], owner: ContentType): Field[Unit, ContentEff] =
        Schema.field2(queryName(owner), Schema.arg("id", GqlCodec.id()), stageArg(), Out.option(Out.obj(entryType(all, owner))), (_context, _root, id, stage) -> {
            let Id.Id(text) = id;
            Ok(EntryId.parse(text) |> Option.flatMap(entryId -> findOne(owner, entryId, stageOrDefault(stage))) |> Option.filter(entry -> entry#typeId == owner#id))
        }) |> Field.withDescription("${TypeName.text(owner#singular)} を id で 1 つ。無ければ null")

    /// stage の行を 1 つ。下書きはその entry を対象にした readDraft の証明（プレビュートークンはその entry だけ通る）。
    def findOne(owner: ContentType, entryId: EntryId, stage: Stage): Option[Entry] \ DbRead + CmsErr + Tenant + Session =
        ContentEntries.findByStage(owner, entryId, accessTo(Some(entryId), stage))

    ///
    /// stage の読み方。公開中は証明が要らず、下書きは readDraft の証明を作る（対象の entry があればそれに対する物。一覧は対象無しなのでプレビュートークンでは読めない）。
    ///
    def accessTo(target: Option[EntryId], stage: Stage): ContentEntries.StageAccess \ Session + CmsErr = match stage {
        case Stage.Published => ContentEntries.StageAccess.Published
        case Stage.Draft     => ContentEntries.StageAccess.Draft(Session.grantOn(target |> Option.map(Authz.entryResource) |> Option.getWithDefault(Authz.anyResource())))
    }

    ///
    /// `<singular>(stage: Stage = PUBLISHED): <Singular>`（singleton）
    ///
    def singletonField(all: List[ContentType], owner: ContentType): Field[Unit, ContentEff] =
        Schema.field1(queryName(owner), stageArg(), Out.option(Out.obj(entryType(all, owner))), (_context, _root, stage) ->
            Ok(firstOne(owner, stageOrDefault(stage))))
            |> Field.withDescription("${TypeName.text(owner#singular)}（1 件だけ）")

    /// singleton の 1 件。
    def firstOne(owner: ContentType, stage: Stage): Option[Entry] \ DbRead + CmsErr + Tenant + Session =
        ContentEntries.firstByStage(owner, accessTo(None, stage))

    ///
    /// `<plural>(where, orderBy, first, skip, stage): <Singular>Connection!`
    ///
    def manyField(all: List[ContentType], owner: ContentType): Field[Unit, ContentEff] =
        // 引数の定義。SDL に出す物（infos）と、入力を読む物（Arg.decode）を同じ値から出す
        let whereArg = Schema.arg("where", GqlCodec.option(whereCodec(owner)));
        let orderArg = Schema.arg("orderBy", GqlCodec.option(GqlCodec.list(orderByCodec(owner))));
        let firstArg = Schema.arg("first", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(20));
        let skipArg = Schema.arg("skip", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(0));
        let stage = stageArg();
        let infos = Arg.info(whereArg) :: Arg.info(orderArg) :: Arg.info(firstArg) :: Arg.info(skipArg) :: Arg.info(stage) :: Nil;
        Schema.fieldRaw(ApiId.text(owner#plural), infos, Out.obj(connectionType(all, owner)), (_context, _root, args) ->
            // 引数を復号し、ページの上限に収めて一覧を引く
            forM (
                filter  <- Arg.decode(whereArg, args);
                orderBy <- Arg.decode(orderArg, args);
                first   <- Arg.decode(firstArg, args);
                skip    <- Arg.decode(skipArg, args);
                atStage <- Arg.decode(stage, args)
            ) yield {
                let (limit, offset) = EntryPage.clamp(20, first, skip);
                ContentEntries.listByStage(owner, accessTo(None, stageOrDefault(atStage)), {
                    filter  = filter |> Option.getWithDefault(Nil),
                    orderBy = orderBy |> Option.getWithDefault(Nil),
                    first   = limit,
                    skip    = offset
                })
            })
            |> Field.withDescription("${TypeName.text(owner#singular)} の一覧")

    ///
    /// 1 件クエリの名前。singular の先頭を小文字にした物（Blog → blog）。規則は Naming が持つ（衝突の検査と同じ物を使う）。
    ///
    def queryName(owner: ContentType): String = Naming.lowerFirst(TypeName.text(owner#singular))

    // ---- 型 ----

    ///
    /// `<Singular>`。共通のフィールドと、定義されたフィールド。
    ///
    def entryType(all: List[ContentType], owner: ContentType): ObjectType[Entry, ContentEff] =
        Schema.objectType(TypeName.text(owner#singular), () ->
            Schema.field0("id", Out.id(), (_context, entry) -> Ok(Id.Id(EntryId.text(entry#id)))) ::
            Schema.field0("stage", Out.scalar(stageCodec()), (_context, entry) -> Ok(entry#stage)) ::
            Schema.field0("publishedAt", Out.option(Out.string()), (_context, entry) -> Ok(entry#publishedAt |> Option.map(Timestamp.toIso8601))) ::
            Schema.field0("createdAt", Out.string(), (_context, entry) -> Ok(Timestamp.toIso8601(entry#createdAt))) ::
            Schema.field0("updatedAt", Out.string(), (_context, entry) -> Ok(Timestamp.toIso8601(entry#updatedAt))) ::
            List.map(customField(all, TypeName.text(owner#singular)), owner#fields))
            |> ObjectType.withDescription(owner#name)

    ///
    /// 定義されたフィールド 1 つ。kind と many で GraphQL の型が決まり、値は中身の JSON から取り出す。
    /// Select は型ごとの enum、Reference は参照先の型（先読みした linked に無ければ同じ stage で引く）。
    ///
    def customField(all: List[ContentType], prefix: String, field: FieldDef): Field[Entry, ContentEff] =
        let name = ApiId.text(field#apiId);
        let described = fieldDescription(field);
        let apiId = field#apiId;
        match field#kind {
            case FieldKind.Object  => valueField(name, field#many, Out.obj(nestedType(all, prefix, field)),
                entry -> EntryValue.object(apiId, entry#data) |> Option.map(nestedEntry(entry)),
                entry -> EntryValue.objects(apiId, entry#data) |> List.map(nestedEntry(entry))) |> described
            case FieldKind.Blocks  => Schema.field0(name, Out.list(blocksUnion(all, prefix, field)), (_context, entry) -> Ok(EntryValue.blocks(field, entry#data) |> List.map(match (variant, inner) -> (variant, nestedEntry(entry, inner))))) |> described
            case FieldKind.Number  => valueField(name, field#many, Out.float64(), entry -> EntryValue.number(apiId, entry#data), entry -> EntryValue.numbers(apiId, entry#data)) |> described
            case FieldKind.Boolean => valueField(name, field#many, Out.bool(), entry -> EntryValue.bool(apiId, entry#data), entry -> EntryValue.bools(apiId, entry#data)) |> described
            case FieldKind.Select  =>
                let known = text -> List.memberOf(text, field#config#options);
                valueField(name, field#many, Out.scalar(selectCodec(prefix, field)),
                    entry -> EntryValue.text(apiId, entry#data) |> Option.filter(known),
                    entry -> EntryValue.texts(apiId, entry#data) |> List.filter(known)) |> described
            case FieldKind.Reference => match targetOf(all, field) {
                case Some(target) => valueField(name, field#many, Out.obj(entryType(all, target)),
                    entry -> EntryValue.text(apiId, entry#data) |> Option.flatMap(EntryId.parse) |> Option.flatMap(resolveLink(target, entry)),
                    entry -> EntryValue.texts(apiId, entry#data) |> List.filterMap(EntryId.parse) |> List.filterMap(resolveLink(target, entry))) |> described
                case None         => valueField(name, field#many, Out.id(),
                    entry -> EntryValue.text(apiId, entry#data) |> Option.map(Id.Id),
                    entry -> EntryValue.texts(apiId, entry#data) |> List.map(Id.Id)) |> described
            }
            case FieldKind.Asset => valueField(name, field#many, Out.obj(assetType()),
                entry -> EntryValue.text(apiId, entry#data) |> Option.flatMap(AssetId.parse) |> Option.flatMap(readyAsset),
                entry -> EntryValue.texts(apiId, entry#data) |> List.filterMap(AssetId.parse) |> List.filterMap(readyAsset)) |> described
            case FieldKind.RichText => valueField(name, field#many, Out.obj(richTextType()),
                entry -> Map.get(apiId, entry#data) |> Option.filter(RichText.isDoc),
                entry -> Map.get(apiId, entry#data) |> Option.map(EntryValue.items(json -> if (RichText.isDoc(json)) Some(json) else None)) |> Option.getWithDefault(Nil)) |> described
            case _ => valueField(name, field#many, Out.string(), entry -> EntryValue.text(apiId, entry#data), entry -> EntryValue.texts(apiId, entry#data)) |> described
        }

    ///
    /// asset。ready の物だけ返す（pending や消えた物は null / 配列から落ちる）。
    ///
    /// WhyNot: 参照（Linked）のように先読みしないのは、1 entry の asset は数個で、まとめ読みの効果より複雑さが勝つため。
    /// 一覧で重くなったら Linked と同じ形に寄せる。
    ///
    def readyAsset(id: AssetId): Option[Asset] \ ContentEff =
        Assets.findMany(id :: Nil) |> List.find(asset -> asset#status == AssetStatus.Ready)

    ///
    /// `Asset { id url fileName mime size width height alt }`。全型で共通の 1 つ。
    ///
    def assetType(): ObjectType[Asset, ContentEff] =
        Schema.objectType("Asset", () ->
            Schema.field0("id", Out.id(), (_context, asset) -> Ok(Id.Id(AssetId.text(asset#id)))) ::
            Schema.field0("url", Out.string(), (_context, asset) -> Ok(ObjectStore.publicUrl(asset#key))) ::
            Schema.field0("fileName", Out.string(), (_context, asset) -> Ok(asset#fileName)) ::
            Schema.field0("mime", Out.string(), (_context, asset) -> Ok(asset#mime)) ::
            Schema.field0("size", Out.int32(), (_context, asset) -> Ok(EntryPage.countToInt32(asset#size))) ::
            Schema.field0("width", Out.option(Out.int32()), (_context, asset) -> Ok(asset#width)) ::
            Schema.field0("height", Out.option(Out.int32()), (_context, asset) -> Ok(asset#height)) ::
            Schema.field0("alt", Out.string(), (_context, asset) -> Ok(asset#alt)) :: Nil)
            |> ObjectType.withDescription("画像やファイル。url で配信する")

    ///
    /// `RichText { json html text }`。source は doc の JSON。html の image は ready な asset の配信 URL を埋め、無い物は出さない。
    ///
    def richTextType(): ObjectType[Util.Json.Json, ContentEff] =
        Schema.objectType("RichText", () ->
            Schema.field0("json", Out.json(), (_context, doc) -> Ok(JsonValue.fromJson(doc))) ::
            Schema.field0("html", Out.string(), (_context, doc) -> Ok(RichText.toHtml(imageRefs(doc), doc))) ::
            Schema.field0("text", Out.string(), (_context, doc) -> Ok(RichText.toText(doc))) ::
            Schema.field0("headings", Out.list(Out.obj(headingType())), (_context, doc) -> Ok(RichText.headings(doc))) ::
            Schema.field1("excerpt", excerptLengthArg(), Out.string(), (_context, doc, length) -> Ok(RichText.excerpt(length |> Option.getWithDefault(120), doc))) ::
            Schema.field0("wordCount", Out.int32(), (_context, doc) -> Ok(RichText.wordCount(doc))) ::
            Schema.field0("readingTimeMinutes", Out.int32(), (_context, doc) -> Ok(RichText.readingTimeMinutes(doc))) :: Nil)
            |> ObjectType.withDescription("構造化した本文。json は ProseMirror の doc、html はその描画（見出しに id 付き）、text は平文、headings は目次用、excerpt / wordCount / readingTimeMinutes は一覧向けの派生値")

    /// `excerpt(length: Int = 120)`
    def excerptLengthArg(): Arg[Option[Int32]] =
        Schema.arg("length", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(120)) |> Arg.withDescription("抜粋の文字数")

    ///
    /// `Heading { level text id }`。id は html の見出しと同じ。
    ///
    def headingType(): ObjectType[RichText.Heading, ContentEff] =
        Schema.objectType("Heading", () ->
            Schema.field0("level", Out.int32(), (_context, heading) -> Ok(heading#level)) ::
            Schema.field0("text", Out.string(), (_context, heading) -> Ok(heading#text)) ::
            Schema.field0("id", Out.string(), (_context, heading) -> Ok(heading#id)) :: Nil)
            |> ObjectType.withDescription("本文の見出し。id は html の見出しに付いた物と同じ")

    def imageRefs(doc: Util.Json.Json): Map[AssetId, RichText.ImageRef] \ ContentEff =
        Assets.findMany(RichText.assetIds(doc))
            |> List.filter(asset -> asset#status == AssetStatus.Ready)
            |> List.map(asset -> (asset#id, { url = ObjectStore.publicUrl(asset#key), width = asset#width, height = asset#height }))
            |> List.toMap

    ///
    /// 値を返すフィールド。単数なら `T`（無ければ null）、配列なら `[T!]!`。取り出し方だけ kind ごとに渡す。
    ///
    def valueField(name: String, many: Bool, out: Out[a, ContentEff], one: Entry -> Option[a] \ ContentEff, all: Entry -> List[a] \ ContentEff): Field[Entry, ContentEff] =
        if (many) Schema.field0(name, Out.list(out), (_context, entry) -> Ok(all(entry)))
        else Schema.field0(name, Out.option(out), (_context, entry) -> Ok(one(entry)))

    ///
    /// 参照先の型。定義に無ければ None（型が消えた直後など。その時は id だけ返す）。
    ///
    def targetOf(all: List[ContentType], field: FieldDef): Option[ContentType] =
        field#target |> Option.flatMap(target -> List.find(candidate -> candidate#id == target, all))

    ///
    /// 参照先 1 つ。先読みした linked にあればそれ、無ければ同じ stage で引く（2 段目以降）。
    ///
    def resolveLink(target: ContentType, entry: Entry, id: EntryId): Option[Entry] \ ContentEff =
        (match Linked.get(id, entry#linked) {
            case Some(found) => Some(found)
            case None        => findOne(target, id, entry#contentStage)
        }) |> Option.filter(found -> found#typeId == target#id)

    ///
    /// Object の入れ子の型。`<prefix><Field>`（Blog + related → BlogRelated）。子の型名はさらに続く（BlogRelatedLink）。
    /// source は中身を子の分に差し替えた Entry（linked と contentStage を引き継ぐので、中の参照も同じ stage で引ける）。
    ///
    def nestedType(all: List[ContentType], prefix: String, field: FieldDef): ObjectType[Entry, ContentEff] =
        let name = Naming.nestedTypeName(prefix, field#apiId);
        Schema.objectType(name, () -> List.map(customField(all, name), Children.toList(field#children)))
            |> ObjectType.withDescription(field#name)

    ///
    /// Blocks の union。`<prefix><Field>` = variant ごとの `<prefix><Field><Variant>`。値は (variant, 中身の Entry)。
    ///
    def blocksUnion(all: List[ContentType], prefix: String, field: FieldDef): Out[(FieldDef, Entry), ContentEff] =
        let name = Naming.nestedTypeName(prefix, field#apiId);
        let variants = Children.toList(field#children) |> List.map(variant -> (variant#apiId, nestedType(all, name, variant)));
        Out.union(name, variants |> List.map(match (_, objectType) -> Out.member(objectType)), (context, block) -> {
            let (variant, inner) = block;
            match List.find(match (apiId, _) -> apiId == variant#apiId, variants) {
                case Some((_, objectType)) => Out.taggedObj(objectType, context, inner)
                case None                  => JavaValue.boxedNull()
            }
        })

    ///
    /// 入れ子の source。中身だけ差し替える。
    ///
    def nestedEntry(entry: Entry, inner: EntryData): Entry =
        { data = inner | entry }

    ///
    /// Select の enum。`<prefix><Field>`（Blog + category → BlogCategory）。値は config.options。
    ///
    def selectCodec(prefix: String, field: FieldDef): GqlCodec[String] =
        GqlCodec.enumOf(Naming.nestedTypeName(prefix, field#apiId), option -> option, field#config#options)

    def fieldDescription(field: FieldDef): Field[Entry, ContentEff] -> Field[Entry, ContentEff] =
        if (field#name == "") (built -> built) else Field.withDescription(field#name)

    ///
    /// `<Singular>Connection { nodes, totalCount }`
    ///
    def connectionType(all: List[ContentType], owner: ContentType): ObjectType[EntryPage, ContentEff] =
        Schema.objectType("${TypeName.text(owner#singular)}Connection", () ->
            Schema.field0("nodes", Out.list(Out.obj(entryType(all, owner))), (_context, page) -> Ok(page#entries)) ::
            Schema.field0("totalCount", Out.int32(), (_context, page) -> Ok(EntryPage.totalCountInt32(page))) :: Nil)

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
            (owner#fields |> List.filter(field -> not field#many and not List.memberOf(field#kind, FieldKind.Reference :: FieldKind.Object :: FieldKind.Blocks :: FieldKind.Asset :: FieldKind.RichText :: Nil)) |> List.map(field -> SortKey.ByField(field#apiId)));
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
        // 葉の引数と、それを束ねる OR / AND の引数
        let leaves = leafArgs(owner);
        let leaf = leafCodec(owner, leaves);
        let orArg = Schema.arg("OR", GqlCodec.option(GqlCodec.list(leaf)));
        let andArg = Schema.arg("AND", GqlCodec.option(GqlCodec.list(leaf)));
        let infos = List.map(leafInfo, leaves) ::: Arg.info(andArg) :: Arg.info(orArg) :: Nil;
        GqlCodec.inputObject("${TypeName.text(owner#singular)}Where", infos, fields ->
            // 入力から条件の一覧にする。自分の葉 → AND（平らに繋ぐ）→ OR（1 つの AnyOf）の順
            forM (
                own  <- decodeLeaves(leaves, fields);
                ands <- Arg.decodeField(andArg, fields);
                ors  <- Arg.decodeField(orArg, fields)
            ) yield own ::: (ands |> Option.getWithDefault(Nil) |> List.flatten) ::: orConditions(ors))

    ///
    /// OR の入力を条件にする。無ければ空、空の並びなら Never、あれば AnyOf 1 つ。
    ///
    /// WhyNot: OR: [] を「条件無し」にしないのは、どれにも合わない集合の OR は偽であり、全件に広がると絞り込みのつもりが漏れになるため
    ///
    def orConditions(ors: Option[List[Where]]): List[Condition] = match ors {
        case None         => Nil
        case Some(Nil)    => Condition.Never :: Nil
        case Some(groups) => Condition.AnyOf(groups) :: Nil
    }

    ///
    /// `<Singular>WhereLeaf`。葉の条件だけ（OR / AND を持たない）。葉は Where と同じ物を受け取る（同一である事を構造で保つ）。
    ///
    def leafCodec(owner: ContentType, leaves: List[LeafArg]): GqlCodec[Where] =
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
    /// 型の全フィールドの葉の条件。id は _eq / _in、フィールドは kind ごと（DATE は _eq と範囲。値は ISO 8601 の文字列）。
    /// 配列は _isNull と（文字列・SELECT・REFERENCE・ASSET なら）_contains。OBJECT / BLOCKS / RICH_TEXT は _isNull だけ。
    ///
    def leafArgs(owner: ContentType): List[LeafArg] =
        idLeaf("id_eq", EntryId.parse, Condition.IdEq) ::
        idsLeaf("id_in", EntryId.parse, Condition.IdIn) ::
        List.flatMap(fieldLeafArgs(TypeName.text(owner#singular)), owner#fields)

    def fieldLeafArgs(prefix: String, field: FieldDef): List[LeafArg] =
        let name = ApiId.text(field#apiId);
        let isNull = leafArg("${name}_isNull", GqlCodec.bool(), flag -> Condition.IsNull(field#apiId, flag) :: Nil);
        isNull :: (if (field#many) arrayLeafArgs(prefix, field) else scalarLeafArgs(prefix, field))

    ///
    /// 配列のフィールドの葉。要素の一致（_contains）だけ。SELECT の配列は選択肢 1 つを含むか。NUMBER / BOOLEAN / DATE / OBJECT / BLOCKS / RICH_TEXT の配列は _isNull のみ。
    ///
    def arrayLeafArgs(prefix: String, field: FieldDef): List[LeafArg] =
        let apiId = field#apiId;
        let name = "${ApiId.text(apiId)}_contains";
        match field#kind {
            case FieldKind.Object    => Nil
            case FieldKind.Blocks    => Nil
            case FieldKind.RichText  => Nil
            case FieldKind.Number    => Nil
            case FieldKind.Boolean   => Nil
            case FieldKind.Date      => Nil
            case FieldKind.Reference => idLeaf(name, EntryId.parse, found -> Condition.ArrayContains(apiId, EntryId.text(found))) :: Nil
            case FieldKind.Asset     => idLeaf(name, AssetId.parse, found -> Condition.ArrayContains(apiId, AssetId.text(found))) :: Nil
            case FieldKind.Select    => leafArg(name, selectCodec(prefix, field), text -> Condition.ArrayContains(apiId, text) :: Nil) :: Nil
            case _                   => leafArg(name, GqlCodec.string(), text -> Condition.ArrayContains(apiId, text) :: Nil) :: Nil
        }

    ///
    /// 単数のフィールドの葉。kind ごとに _eq / _in / 範囲 / 部分一致。OBJECT / BLOCKS / RICH_TEXT は _isNull のみ。
    ///
    def scalarLeafArgs(prefix: String, field: FieldDef): List[LeafArg] =
        let apiId = field#apiId;
        let name = ApiId.text(apiId);
        match field#kind {
            case FieldKind.Object    => Nil
            case FieldKind.Blocks    => Nil
            case FieldKind.RichText  => Nil
            case FieldKind.Asset     => idLeaf("${name}_id_eq", AssetId.parse, found -> Condition.TextEq(apiId, AssetId.text(found))) :: Nil
            case FieldKind.Reference =>
                idLeaf("${name}_id_eq", EntryId.parse, found -> Condition.TextEq(apiId, EntryId.text(found))) ::
                idsLeaf("${name}_id_in", EntryId.parse, found -> Condition.TextIn(apiId, List.map(EntryId.text, found))) :: Nil
            case FieldKind.Select    => equalityLeaves(name, apiId, selectCodec(prefix, field))
            case FieldKind.Number    => numberLeaves(name, apiId)
            case FieldKind.Date      => dateLeaves(name, apiId)
            case FieldKind.Boolean   => leafArg("${name}_eq", GqlCodec.bool(), b -> Condition.BoolEq(apiId, b) :: Nil) :: Nil
            case _                   => equalityLeaves(name, apiId, GqlCodec.string()) ::: searchLeaves(name, apiId)
        }

    /// `_eq` / `_in`。SELECT なら enum の codec、文字列なら String。
    def equalityLeaves(name: String, apiId: ApiId, codec: GqlCodec[String]): List[LeafArg] =
        leafArg("${name}_eq", codec, text -> Condition.TextEq(apiId, text) :: Nil) ::
        leafArg("${name}_in", GqlCodec.list(codec), texts -> Condition.TextIn(apiId, texts) :: Nil) :: Nil

    /// `_contains` / `_startsWith`。文字列だけ。
    def searchLeaves(name: String, apiId: ApiId): List[LeafArg] =
        leafArg("${name}_contains", GqlCodec.string(), text -> Condition.TextContains(apiId, text) :: Nil) ::
        leafArg("${name}_startsWith", GqlCodec.string(), text -> Condition.TextStartsWith(apiId, text) :: Nil) :: Nil

    /// `_eq` と範囲の 4 つ。
    def numberLeaves(name: String, apiId: ApiId): List[LeafArg] =
        leafArg("${name}_eq", GqlCodec.float64(), x -> Condition.NumberEq(apiId, x) :: Nil) ::
        leafArg("${name}_gt", GqlCodec.float64(), x -> Condition.NumberGt(apiId, x) :: Nil) ::
        leafArg("${name}_gte", GqlCodec.float64(), x -> Condition.NumberGte(apiId, x) :: Nil) ::
        leafArg("${name}_lt", GqlCodec.float64(), x -> Condition.NumberLt(apiId, x) :: Nil) ::
        leafArg("${name}_lte", GqlCodec.float64(), x -> Condition.NumberLte(apiId, x) :: Nil) :: Nil

    ///
    /// DATE の `_eq` と範囲の 4 つ。値は ISO 8601 の日時か日付（"2026-09-08" は UTC の 0 時）。読めない文字列は Never（何にも合わない）に倒す。
    ///
    def dateLeaves(name: String, apiId: ApiId): List[LeafArg] =
        dateLeaf("${name}_eq", at -> Condition.DateEq(apiId, at)) ::
        dateLeaf("${name}_gt", at -> Condition.DateGt(apiId, at)) ::
        dateLeaf("${name}_gte", at -> Condition.DateGte(apiId, at)) ::
        dateLeaf("${name}_lt", at -> Condition.DateLt(apiId, at)) ::
        dateLeaf("${name}_lte", at -> Condition.DateLte(apiId, at)) :: Nil

    def dateLeaf(name: String, make: Timestamp.Timestamp -> Condition): LeafArg =
        leafArg(name, GqlCodec.string(), text -> (DateValues.parse(text) |> Option.map(make) |> Option.getWithDefault(Condition.Never)) :: Nil)

    ///
    /// ID を 1 つ受ける葉。規則（parse）に合わない id は Never（何にも合わない）に倒す。
    ///
    def idLeaf(name: String, parse: String -> Option[a], make: a -> Condition): LeafArg =
        leafArg(name, GqlCodec.id(), id -> (parsedId(parse, id) |> Option.map(make) |> Option.getWithDefault(Condition.Never)) :: Nil)

    ///
    /// ID の並びを受ける葉。全部規則外なら空の並び（Never 相当）、混ざっていれば合う物だけ。
    ///
    def idsLeaf(name: String, parse: String -> Option[a], make: List[a] -> Condition): LeafArg =
        leafArg(name, GqlCodec.list(GqlCodec.id()), ids -> make(List.filterMap(parsedId(parse), ids)) :: Nil)

    def parsedId(parse: String -> Option[a], id: Id): Option[a] =
        let Id.Id(text) = id;
        parse(text)

}
