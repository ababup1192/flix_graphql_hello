///
/// content type の定義からコンテンツ API の Schema を組む。型ごとに
/// `<singular>(id, stage)`、`<plural>(where, orderBy, first, skip, after, stage)`（singleton は `<singular>(stage)` だけ）と、
/// `<Singular>` / `<Singular>Where` / `<Singular>WhereLeaf` / `<Singular>OrderBy` / `<Singular>Connection` / `<Singular>Edge` が生える。PageInfo は共通。
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
    /// `<singular>(id: ID, slug: String, stage: Stage = PUBLISHED): <Singular>`。
    /// `slug` は unique な SLUG のフィールドを 1 つだけ持つ型にだけ生える。
    ///
    /// WhyNot: id を `ID!` のままにできないのは、id と slug のどちらか 1 つを受けるため。
    /// WhyNot: field2 でなく fieldRaw なのは、引数 3 つの field3 が無く、足すと manyField と 2 通りの書き方に割れるため。
    ///
    def oneField(all: List[ContentType], owner: ContentType): Field[Unit, ContentEff] =
        // 引数の定義。slug は出せる型でだけ SDL に出す（出さない型には引数ごと生えない）
        let idArg = Schema.arg("id", GqlCodec.option(GqlCodec.id())) |> Arg.withDescription("entry の id。slug と同時には渡せない");
        let slugArg = Schema.arg("slug", GqlCodec.option(GqlCodec.string())) |> Arg.withDescription("unique な slug の値。id と同時には渡せない。この引数は unique な slug フィールドを 1 つだけ持つ型にだけ出る");
        let lookupSlug = slugLookupOf(owner);
        let slugInfos = match lookupSlug { case Some(_) => Arg.info(slugArg) :: Nil case None => Nil };
        let stage = stageArg();
        let infos = Arg.info(idArg) :: (slugInfos ::: Arg.info(stage) :: Nil);
        Schema.fieldRaw(queryName(owner), infos, Out.option(Out.obj(entryType(all, owner))), (_context, _root, args) ->
            // 引数を復号し、id か slug のどちらか 1 つで 1 件引く
            forM (
                id      <- Arg.decode(idArg, args);
                slug    <- Arg.decode(slugArg, args);
                atStage <- Arg.decode(stage, args)
            ) yield lookupOne(owner, lookupSlug, id, slug, stageOrDefault(atStage)))
            |> Field.withDescription(oneDescription(owner, lookupSlug))

    def oneDescription(owner: ContentType, lookupSlug: Option[ApiId]): String =
        let byId = "${TypeName.text(owner#singular)} を id で 1 つ。無ければ null";
        match lookupSlug {
            case None        => byId
            case Some(apiId) => "${byId}。slug（${ApiId.text(apiId)}）でも引ける（id と slug はどちらか 1 つ）"
        }

    ///
    /// slug で引ける型の SLUG のフィールド。SLUG のフィールドが 1 つだけ、かつ unique で配列でない型に限る。
    ///
    /// WhyNot: unique でない SLUG や 2 つ以上ある SLUG で引数を出さないのは、値が 1 件に決まらず、
    /// 下書き（照合は公開時だけ）では同じ値の entry が普通に並ぶため。SDL に出ている＝1 件に決まる、を守る。
    ///
    def slugLookupOf(owner: ContentType): Option[ApiId] =
        match owner#fields |> List.filter(field -> field#kind == FieldKind.Slug) {
            case field :: Nil => if (field#unique and not field#many) Some(field#apiId) else None
            case _            => None
        }

    ///
    /// 1 件の引き方。id だけなら id で、slug だけなら slug で。両方 null も両方指定も invalid。
    ///
    def lookupOne(owner: ContentType, lookupSlug: Option[ApiId], id: Option[Id], slug: Option[String], stage: Stage): Option[Entry] \ DbRead + CmsErr + Tenant + Session =
        match (id, slug) {
            case (Some(Id.Id(text)), None) => EntryId.parse(text) |> Option.flatMap(entryId -> findOne(owner, entryId, stage)) |> Option.filter(entry -> entry#typeId == owner#id)
            case (None, Some(value))       => findOneBySlug(owner, lookupSlug, value, stage)
            case _                         => CmsErr.invalid(Violation.Violation("id", "id か slug のどちらか 1 つを指定してください") :: Nil)
        }

    ///
    /// slug で 1 件。2 件以上あれば invalid（下書きで重複している事を隠さない）。
    ///
    def findOneBySlug(owner: ContentType, lookupSlug: Option[ApiId], value: String, stage: Stage): Option[Entry] \ DbRead + CmsErr + Tenant + Session =
        let apiId = lookupSlug |> CmsErr.orInvalid("slug", "この型は slug で引けません");
        // 2 件取って重複を見る。並びは id で決め打ちして結果を決定的にする
        let found = ContentEntries.listByStage(owner, accessTo(None, stage),
            { filter = Condition.TextEq(apiId, value) :: Nil, orderBy = (SortKey.ById, Direction.Asc) :: Nil, first = 2, start = PageStart.Offset(0) });
        match found#entries {
            case Nil          => None
            case entry :: Nil => Some(entry)
            case _            => CmsErr.invalid(Violation.Violation("slug", "slug '${value}' の ${TypeName.text(owner#singular)} が複数あります。id で指定してください") :: Nil)
        }

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
    /// `<plural>(where, orderBy, first, skip, after, stage): <Singular>Connection!`
    ///
    def manyField(all: List[ContentType], owner: ContentType): Field[Unit, ContentEff] =
        // 引数の定義。SDL に出す物（infos）と、入力を読む物（Arg.decode）を同じ値から出す
        let whereArg = Schema.arg("where", GqlCodec.option(whereCodec(owner)))
            |> Arg.withDescription("絞り込み。フィールド名_演算子 の形。複数書くと AND。OR は OR: [{...}, {...}]（1 段だけ）");
        let orderArg = Schema.arg("orderBy", GqlCodec.option(GqlCodec.list(orderByCodec(owner))))
            |> Arg.withDescription("並び順。先頭が優先。省くと updatedAt の新しい順。同じ値は id の昇順");
        let firstArg = Schema.arg("first", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(20))
            |> Arg.withDescription("返す件数の上限。既定 20、最大 200（超える値は 200 に丸める）。0 なら totalCount だけ");
        let skipArg = Schema.arg("skip", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(0))
            |> Arg.withDescription("先頭から飛ばす件数。after と同時には使えない");
        let afterArg = Schema.arg("after", GqlCodec.option(GqlCodec.string()))
            |> Arg.withDescription("前のページの pageInfo.endCursor。orderBy と対で意味を持つので、並び順を変えたら先頭から読み直す。skip と同時には使えない");
        let stage = stageArg();
        let infos = Arg.info(whereArg) :: Arg.info(orderArg) :: Arg.info(firstArg) :: Arg.info(skipArg) :: Arg.info(afterArg) :: Arg.info(stage) :: Nil;
        Schema.fieldRaw(ApiId.text(owner#plural), infos, Out.obj(connectionType(all, owner)), (_context, _root, args) ->
            // 引数を復号し、ページの上限に収めて一覧を引く
            forM (
                filter  <- Arg.decode(whereArg, args);
                orderBy <- Arg.decode(orderArg, args);
                first   <- Arg.decode(firstArg, args);
                skip    <- Arg.decode(skipArg, args);
                after   <- Arg.decode(afterArg, args);
                atStage <- Arg.decode(stage, args)
            ) yield listPage(owner, stageOrDefault(atStage), filter |> Option.getWithDefault(Nil), orderBy |> Option.getWithDefault(Nil), EntryPage.clamp(20, first, skip), after))
            |> Field.withDescription("${TypeName.text(owner#singular)} の一覧")

    /// 一覧の 1 ページ。after は orderBy と対で復号し、skip との同時指定と壊れた cursor は invalid。
    def listPage(owner: ContentType, stage: Stage, filter: Where, orderBy: OrderBy, page: (Int32, Int32), after: Option[String]): EntryPage \ DbRead + CmsErr + Tenant + Session =
        let (first, skip) = page;
        let start = Cursor.pageStart(orderBy, skip, after) |> CmsErr.okOrInvalid;
        ContentEntries.listByStage(owner, accessTo(None, stage), { filter = filter, orderBy = orderBy, first = first, start = start })

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
            (Schema.field0("id", Out.id(), (_context, entry) -> Ok(Id.Id(EntryId.text(entry#id)))) |> Field.withDescription("entry の id。1 件のクエリの id と where の id_eq / id_in に渡す")) ::
            (Schema.field0("stage", Out.scalar(stageCodec()), (_context, entry) -> Ok(entry#stage)) |> Field.withDescription("読んだ内容の stage（PUBLISHED / DRAFT）")) ::
            (Schema.field0("publishedAt", Out.option(Out.string()), (_context, entry) -> Ok(entry#publishedAt |> Option.map(Timestamp.toIso8601))) |> Field.withDescription("公開した時刻（ISO 8601、UTC）。公開中でなければ null")) ::
            (Schema.field0("createdAt", Out.string(), (_context, entry) -> Ok(Timestamp.toIso8601(entry#createdAt))) |> Field.withDescription("作った時刻（ISO 8601、UTC）")) ::
            (Schema.field0("updatedAt", Out.string(), (_context, entry) -> Ok(Timestamp.toIso8601(entry#updatedAt))) |> Field.withDescription("最後に更新した時刻（ISO 8601、UTC）")) ::
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
            // 本文は doc だけでなく、それを持つ entry も source に持つ。**本文が指しているコンテンツの
            // path を出すのに、先読みした linked が要る。**
            case FieldKind.RichText => valueField(name, field#many, Out.obj(richTextType(all)),
                entry -> Map.get(apiId, entry#data) |> Option.filter(RichText.isDoc) |> Option.map(doc -> (doc, entry)),
                entry -> Map.get(apiId, entry#data) |> Option.map(EntryValue.items(json -> if (RichText.isDoc(json)) Some(json) else None)) |> Option.getWithDefault(Nil) |> List.map(doc -> (doc, entry))) |> described
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
    /// `Asset { id url fileName mime size width height alt focalPoint crop }`。全型で共通の 1 つ。
    ///
    def assetType(): ObjectType[Asset, ContentEff] =
        Schema.objectType("Asset", () ->
            (Schema.field0("id", Out.id(), (_context, asset) -> Ok(Id.Id(AssetId.text(asset#id)))) |> Field.withDescription("asset の id。where の <フィールド>_id_eq / _contains に渡す")) ::
            (Schema.field0("url", Out.string(), (_context, asset) -> Ok(ObjectStore.publicUrl(asset#key))) |> Field.withDescription("配信 URL。そのまま img の src や a の href に置ける")) ::
            (Schema.field0("fileName", Out.string(), (_context, asset) -> Ok(asset#fileName)) |> Field.withDescription("アップロード時のファイル名（パスと制御文字を除いた物）")) ::
            (Schema.field0("mime", Out.string(), (_context, asset) -> Ok(asset#mime)) |> Field.withDescription("MIME タイプ（例 image/png）")) ::
            (Schema.field0("size", Out.int32(), (_context, asset) -> Ok(EntryPage.countToInt32(asset#size))) |> Field.withDescription("バイト数")) ::
            (Schema.field0("width", Out.option(Out.int32()), (_context, asset) -> Ok(asset#width)) |> Field.withDescription("画像の幅（px）。画像でなければ null")) ::
            (Schema.field0("height", Out.option(Out.int32()), (_context, asset) -> Ok(asset#height)) |> Field.withDescription("画像の高さ（px）。画像でなければ null")) ::
            (Schema.field0("alt", Out.string(), (_context, asset) -> Ok(asset#alt)) |> Field.withDescription("代替テキスト。未設定なら空文字")) ::
            (Schema.field0("focalPoint", Out.option(Out.obj(focalPointType())), (_context, asset) -> Ok(asset#presentation#focalPoint)) |> Field.withDescription("主役の位置。0〜1 の割合（左上が 0,0）。未設定なら null（中央として扱う）。object-position や切り出しの中心に使う")) ::
            (Schema.field0("crop", Out.option(Out.obj(cropRectType())), (_context, asset) -> Ok(asset#presentation#crop)) |> Field.withDescription("切り抜き枠。0〜1 の割合（左上が 0,0）。未設定なら null（全体として扱う）。画像 CDN の切り出しや CSS の clip に使う")) :: Nil)
            |> ObjectType.withDescription("画像やファイル。url で配信する。focalPoint / crop は割合の数値で、画像そのものは加工していない")

    /// `FocalPoint { x y }`。
    def focalPointType(): ObjectType[FocalPoint, ContentEff] =
        Schema.objectType("FocalPoint", () ->
            (Schema.field0("x", Out.float64(), (_context, point) -> Ok(point#x)) |> Field.withDescription("横。0 が左端、1 が右端")) ::
            (Schema.field0("y", Out.float64(), (_context, point) -> Ok(point#y)) |> Field.withDescription("縦。0 が上端、1 が下端")) :: Nil)
            |> ObjectType.withDescription("注目点。画像の中で主役になる位置。0〜1 の割合で、左上が (0, 0)")

    /// `CropRect { left top width height }`。
    def cropRectType(): ObjectType[CropRect, ContentEff] =
        Schema.objectType("CropRect", () ->
            (Schema.field0("left", Out.float64(), (_context, crop) -> Ok(crop#left)) |> Field.withDescription("枠の左端。0〜1 の割合")) ::
            (Schema.field0("top", Out.float64(), (_context, crop) -> Ok(crop#top)) |> Field.withDescription("枠の上端。0〜1 の割合")) ::
            (Schema.field0("width", Out.float64(), (_context, crop) -> Ok(crop#width)) |> Field.withDescription("枠の幅。0 より大きく、left + width は 1 以下")) ::
            (Schema.field0("height", Out.float64(), (_context, crop) -> Ok(crop#height)) |> Field.withDescription("枠の高さ。0 より大きく、top + height は 1 以下")) :: Nil)
            |> ObjectType.withDescription("切り抜き枠。画像の中で見せる矩形。0〜1 の割合で、左上が (0, 0)")

    ///
    /// `RichText { json html text links }`。source は (doc, その doc を持つ entry)。
    /// html の image は ready な asset の配信 URL を埋め、無い物は出さない。
    ///
    def richTextType(all: List[ContentType]): ObjectType[(Util.Json.Json, Entry), ContentEff] =
        Schema.objectType("RichText", () ->
            (Schema.field0("json", Out.json(), (_context, src) -> Ok(JsonValue.fromJson(fst(src)))) |> Field.withDescription("ProseMirror の doc（TipTap 互換）。自分で描く時に使う。画像は asset の id、entry へのリンクは entryId を持つ")) ::
            (Schema.field0("html", Out.string(), (_context, src) -> Ok(RichText.toHtml(imageRefs(fst(src)), linkPaths(all, src), cardRefs(fst(src)), fst(src)))) |> Field.withDescription("HTML。見出しに id（headings と同じ）、画像は asset の配信 URL、外部リンクは target=\"_blank\"、entry へのリンクは型の linkPath から作った href（linkPath が無ければ #entry:ID）。文字はエスケープ済み")) ::
            (Schema.field0("markdown", Out.string(), (_context, src) -> Ok(Markdown.toMarkdown(fst(src)))) |> Field.withDescription("Markdown。画像は asset:ID、entry へのリンクは entry:ID のまま出るので、assets と links で解く")) ::
            (Schema.field0("text", Out.string(), (_context, src) -> Ok(RichText.toText(fst(src)))) |> Field.withDescription("平文。装飾と画像を除き、ブロックの区切りは改行")) ::
            (Schema.field0("assets", Out.list(Out.obj(assetType())), (_context, src) -> Ok(docAssets(fst(src)))) |> Field.withDescription("本文が指している asset（アップロードが完了した物だけ）")) ::
            (Schema.field0("headings", Out.list(Out.obj(headingType())), (_context, src) -> Ok(RichText.headings(fst(src)))) |> Field.withDescription("見出しの一覧（出現順）。目次に使う")) ::
            (Schema.field0("links", Out.list(Out.obj(richTextLinkType())), (_context, src) -> Ok(richTextLinks(all, src))) |> Field.withDescription("本文が指している entry。消えた entry は含まない")) ::
            (Schema.field1("excerpt", excerptLengthArg(), Out.string(), (_context, src, length) -> Ok(RichText.excerpt(length |> Option.getWithDefault(120), fst(src)))) |> Field.withDescription("抜粋。平文の改行を空白にして先頭 length 文字（既定 120）。切れたら末尾に …")) ::
            (Schema.field0("wordCount", Out.int32(), (_context, src) -> Ok(RichText.wordCount(fst(src)))) |> Field.withDescription("語数。ひらがな・カタカナ・漢字・ハングルは 1 文字 1 語、それ以外は空白区切りの語")) ::
            (Schema.field0("readingTimeMinutes", Out.int32(), (_context, src) -> Ok(RichText.readingTimeMinutes(fst(src)))) |> Field.withDescription("読了時間（分）。日本語など 500 文字/分、それ以外 200 語/分で切り上げ。最低 1")) :: Nil)
            |> ObjectType.withDescription("構造化した本文。json は ProseMirror の doc、html はその描画（見出しに id 付き）、markdown は CMS の方言を含む Markdown（画像は asset:ID、コンテンツへのリンクは entry:ID。assets と links で解く）、text は平文、assets は本文が指している asset、headings は目次用、links は本文が指しているコンテンツ、excerpt / wordCount / readingTimeMinutes は一覧向けの派生値")

    ///
    /// 本文が指しているコンテンツ 1 つ。`json` を自分で描くサイトが、entryId から href を作るのに使う。
    ///
    def richTextLinkType(): ObjectType[(EntryId, ApiId, Option[String]), ContentEff] =
        Schema.objectType("RichTextLink", () ->
            (Schema.field0("id", Out.id(), (_context, src) -> { let (id, _, _) = src; Ok(Id.Id(EntryId.text(id))) }) |> Field.withDescription("指している entry の id。json の entryId / markdown の entry:ID と同じ値")) ::
            (Schema.field0("apiId", Out.string(), (_context, src) -> { let (_, apiId, _) = src; Ok(ApiId.text(apiId)) }) |> Field.withDescription("指している entry の型の apiId")) ::
            (Schema.field0("path", Out.option(Out.string()), (_context, src) -> { let (_, _, path) = src; Ok(path) }) |> Field.withDescription("型の linkPath から作ったパス。linkPath が無ければ null")) :: Nil)
            |> ObjectType.withDescription("本文が指しているコンテンツ。path は型の linkPath から作った物で、linkPath が無ければ null")

    ///
    /// 本文が指しているコンテンツ（id, 型の apiId, path）。
    ///
    /// **引き直さない。** 参照先は `attachLinked` が 1 本の SELECT で先読みしていて、本文の
    /// リンクも `EntryLinks.extract` に入っている。消えた指し先は落ちる。
    ///
    def richTextLinks(all: List[ContentType], src: (Util.Json.Json, Entry)): List[(EntryId, ApiId, Option[String])] =
        let (doc, entry) = src;
        RichText.linkedEntryIds(doc) |> List.filterMap(id ->
            Linked.get(id, entry#linked) |> Option.flatMap(target ->
                all |> List.find(owner -> owner#id == target#typeId) |> Option.map(owner ->
                    (id, owner#apiId, LinkPath.of(owner#linkPath, EntryId.text(id), EntryValue.slugOf(owner, target#data))))))

    /// 本文のリンクに出す href。型に linkPath が無い物は入れない（`#entry:{id}` のままになる）。
    def linkPaths(all: List[ContentType], src: (Util.Json.Json, Entry)): Map[EntryId, String] =
        richTextLinks(all, src) |> List.filterMap(match (id, _, path) -> path |> Option.map(found -> (id, found))) |> List.toMap

    /// `excerpt(length: Int = 120)`
    def excerptLengthArg(): Arg[Option[Int32]] =
        Schema.arg("length", GqlCodec.option(GqlCodec.int32())) |> Arg.withDefaultValue(Value.Int(120)) |> Arg.withDescription("抜粋の文字数")

    ///
    /// `Heading { level text id }`。id は html の見出しと同じ。
    ///
    def headingType(): ObjectType[RichText.Heading, ContentEff] =
        Schema.objectType("Heading", () ->
            (Schema.field0("level", Out.int32(), (_context, heading) -> Ok(heading#level)) |> Field.withDescription("見出しの深さ（1 〜 4）")) ::
            (Schema.field0("text", Out.string(), (_context, heading) -> Ok(heading#text)) |> Field.withDescription("見出しの平文")) ::
            (Schema.field0("id", Out.string(), (_context, heading) -> Ok(heading#id)) |> Field.withDescription("html の見出しに付いた id。目次のリンク先（#id）に使う")) :: Nil)
            |> ObjectType.withDescription("本文の見出し。id は html の見出しに付いた物と同じ")

    /// linkCard の OGP（表にある物だけ。取りには行かない）。無い url・失敗した url は URL だけの a になる。
    def cardRefs(doc: Util.Json.Json): Map[String, RichText.CardRef] \ DbRead + Tenant =
        LinkCards.cardsOf(RichText.linkCardUrls(doc))

    ///
    /// 本文が指している asset（ready の物だけ）。`markdown` の `asset:ID` を解くのに使う。
    ///
    /// WhyNot: 画像 1 つずつ引かないのは、doc の asset の id をまとめて 1 本の SELECT にするため（html と同じ引き方）。
    ///
    def docAssets(doc: Util.Json.Json): List[Asset] \ ContentEff =
        Assets.findMany(RichText.assetIds(doc)) |> List.filter(asset -> asset#status == AssetStatus.Ready)

    def imageRefs(doc: Util.Json.Json): Map[AssetId, RichText.ImageRef] \ ContentEff =
        docAssets(doc)
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
    /// `<Singular>Connection { nodes, edges { cursor node }, pageInfo { hasNextPage endCursor }, totalCount }`。GitHub の GraphQL API と同じ形。
    ///
    def connectionType(all: List[ContentType], owner: ContentType): ObjectType[EntryPage, ContentEff] =
        Schema.objectType("${TypeName.text(owner#singular)}Connection", () ->
            (Schema.field0("nodes", Out.list(Out.obj(entryType(all, owner))), (_context, page) -> Ok(page#entries)) |> Field.withDescription("そのページの entry")) ::
            (Schema.field0("edges", Out.list(Out.obj(edgeType(all, owner))), (_context, page) -> Ok(EntryPage.edges(page))) |> Field.withDescription("Relay 形。cursor を after に渡せる。nodes と同じ entry")) ::
            (Schema.field0("pageInfo", Out.obj(pageInfoType()), (_context, page) -> Ok(EntryPage.pageInfo(page))) |> Field.withDescription("次のページがあるか（hasNextPage）と、その cursor（endCursor）")) ::
            (Schema.field0("totalCount", Out.int32(), (_context, page) -> Ok(EntryPage.totalCountInt32(page))) |> Field.withDescription("絞り込み後の総件数（ページに関係なく）")) :: Nil)
            |> ObjectType.withDescription("一覧の 1 ページ。nodes か edges のどちらかを読む。次のページは pageInfo.endCursor を after に渡す（orderBy と対。skip とは同時に渡せない）")

    ///
    /// `<Singular>Edge { cursor, node }`。
    ///
    def edgeType(all: List[ContentType], owner: ContentType): ObjectType[EntryEdge, ContentEff] =
        Schema.objectType("${TypeName.text(owner#singular)}Edge", () ->
            (Schema.field0("cursor", Out.string(), (_context, edge) -> Ok(edge#cursor)) |> Field.withDescription("この entry の位置。after に渡すとこの次から読める")) ::
            (Schema.field0("node", Out.obj(entryType(all, owner)), (_context, edge) -> Ok(edge#node)) |> Field.withDescription("entry")) :: Nil)
            |> ObjectType.withDescription("一覧の 1 件と、その位置（cursor）")

    ///
    /// `PageInfo { hasNextPage, endCursor }`。全型で共通の 1 つ。
    ///
    def pageInfoType(): ObjectType[PageInfo, ContentEff] =
        Schema.objectType("PageInfo", () ->
            (Schema.field0("hasNextPage", Out.bool(), (_context, info) -> Ok(info#hasNextPage)) |> Field.withDescription("次のページがあるか")) ::
            (Schema.field0("endCursor", Out.option(Out.string()), (_context, info) -> Ok(info#endCursor)) |> Field.withDescription("このページの最後の entry の cursor。次のページを読む時に after に渡す。ページが空なら null")) :: Nil)
            |> ObjectType.withDescription("ページの続き。hasNextPage なら endCursor を after に渡して次を読む")

    // ---- 引数 ----

    ///
    /// `stage: Stage = PUBLISHED`
    ///
    def stageArg(): Arg[Option[Stage]] =
        Schema.arg("stage", GqlCodec.option(stageCodec())) |> Arg.withDefaultValue(Value.Str("PUBLISHED"))
            |> Arg.withDescription("PUBLISHED（既定）は公開中の内容。DRAFT は下書きも含む。DRAFT は API キー（READ_DRAFT）かプレビュートークンが要る（一覧はプレビュートークンでは読めない）")

    def stageOrDefault(given: Option[Stage]): Stage = given |> Option.getWithDefault(Stage.Published)

    def stageCodec(): GqlCodec[Stage] =
        GqlCodec.enumOf("Stage", stage -> match stage { case Stage.Draft => "DRAFT" case Stage.Published => "PUBLISHED" }, Stage.Draft :: Stage.Published :: Nil)
            |> GqlCodec.describe("entry の状態。省けば公開中の物")
            |> GqlCodec.describeValue(Stage.Published, "公開中の内容。認証無しで読める（public なプロジェクト）")
            |> GqlCodec.describeValue(Stage.Draft, "下書きの内容（未公開の entry も含む）。API キー（READ_DRAFT）かプレビュートークンが要る")

    ///
    /// `<Singular>OrderBy` の enum。共通のキーと、配列でないフィールド。
    ///
    def orderByCodec(owner: ContentType): GqlCodec[(SortKey, Direction)] =
        let keys = SortKey.ById :: SortKey.ByPublishedAt :: SortKey.ByUpdatedAt :: SortKey.ByCreatedAt ::
            (owner#fields |> List.filter(field -> not field#many and not List.memberOf(field#kind, FieldKind.Reference :: FieldKind.Object :: FieldKind.Blocks :: FieldKind.Asset :: FieldKind.RichText :: Nil)) |> List.map(field -> SortKey.ByField(field#apiId)));
        let values = keys |> List.flatMap(key -> (key, Direction.Asc) :: (key, Direction.Desc) :: Nil);
        GqlCodec.enumOf("${TypeName.text(owner#singular)}OrderBy", orderByName, values)
            |> GqlCodec.describe("並び順のキーと向き。省くと updatedAt_DESC。同じ値は id の昇順で安定する")
            |> GqlCodec.describeValues(orderByDescription(owner), values)

    def orderByName(term: (SortKey, Direction)): String =
        let (key, direction) = term;
        "${SortKey.toText(key)}_${Direction.toText(direction)}"

    ///
    /// OrderBy の値の説明。時刻のキーは新しい順 / 古い順、それ以外は昇順 / 降順。NULL を取りうるキー（publishedAt とフィールド）は向きに関わらず末尾。
    ///
    def orderByDescription(owner: ContentType, term: (SortKey, Direction)): String =
        let (key, direction) = term;
        let newestFirst = match direction { case Direction.Desc => "新しい順" case Direction.Asc => "古い順" };
        let descending = match direction { case Direction.Desc => "降順" case Direction.Asc => "昇順" };
        match key {
            case SortKey.ById           => "id の${descending}"
            case SortKey.ByUpdatedAt    => "updatedAt の${newestFirst}（既定）"
            case SortKey.ByCreatedAt    => "createdAt の${newestFirst}"
            case SortKey.ByPublishedAt  => "publishedAt の${newestFirst}。未公開（null）は末尾"
            case SortKey.ByField(apiId) =>
                let label = owner#fields |> List.find(field -> field#apiId == apiId) |> Option.map(field -> field#name) |> Option.filter(String.nonEmpty) |> Option.getWithDefault(ApiId.text(apiId));
                "${label}（${ApiId.text(apiId)}）の${descending}。値が無い entry は末尾"
        }

    ///
    /// `<Singular>Where`。葉の条件と、OR / AND（それぞれ WhereLeaf のリスト）。
    ///
    def whereCodec(owner: ContentType): GqlCodec[Where] =
        // 葉の引数と、それを束ねる OR / AND の引数
        let leaves = leafArgs(owner);
        let leaf = leafCodec(owner, leaves);
        let orArg = Schema.arg("OR", GqlCodec.option(GqlCodec.list(leaf)))
            |> Arg.withDescription("どれか 1 つに合えば良い条件の一覧。直に書いた条件とは AND。入れ子は 1 段（中に AND / OR は書けない）。空の一覧は何にも合わない");
        let andArg = Schema.arg("AND", GqlCodec.option(GqlCodec.list(leaf)))
            |> Arg.withDescription("全部に合う条件の一覧。直に書いた条件と同じ意味（束ねて書くための物）。入れ子は 1 段（中に AND / OR は書けない）");
        let infos = List.map(leafInfo, leaves) ::: Arg.info(andArg) :: Arg.info(orArg) :: Nil;
        GqlCodec.inputObject("${TypeName.text(owner#singular)}Where", infos, fields ->
            // 入力から条件の一覧にする。自分の葉 → AND（平らに繋ぐ）→ OR（1 つの AnyOf）の順
            forM (
                own  <- decodeLeaves(leaves, fields);
                ands <- Arg.decodeField(andArg, fields);
                ors  <- Arg.decodeField(orArg, fields)
            ) yield own ::: (ands |> Option.getWithDefault(Nil) |> List.flatten) ::: orConditions(ors))
            |> GqlCodec.describe("絞り込み。フィールド名_演算子 の形で、複数書くと AND。OR は 1 段だけ")

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
            |> GqlCodec.describe("AND / OR の中に書く条件。Where と同じフィールドで、AND / OR だけ持たない")

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

    /// 葉の条件に SDL の description を付ける。
    def describeLeaf(text: String, leaf: LeafArg): LeafArg =
        { info = { description = Some(text) | leaf#info } | leaf }

    /// 日時の引数の値の形。DATE のフィールドとシステムの日時で同じ。
    def dateValueHint(): String = "値は ISO 8601 の日時（例 2026-09-01T00:00:00Z、offset 付きも可）か日付（2026-09-01 は UTC の 0 時）。読めない値は何にも合わない"

    /// 日付の引数の値の形。
    def dateOnlyValueHint(): String = "値は日付（例 2026-09-01）。時刻付きは UTC で見た日付として読む。読めない値は何にも合わない"

    /// 範囲の演算子の日本語。
    def rangeText(op: RangeOp): String = match op {
        case RangeOp.Gt  => "より後（より大きい）"
        case RangeOp.Gte => "以後（以上）"
        case RangeOp.Lt  => "より前（より小さい）"
        case RangeOp.Lte => "以前（以下）"
    }

    ///
    /// 型の全フィールドの葉の条件。id は _eq / _in、フィールドは kind ごと（DATE は _eq と範囲。値は ISO 8601 の文字列）。
    /// 配列は _isNull と（文字列・SELECT・REFERENCE・ASSET なら）_contains。OBJECT / BLOCKS / RICH_TEXT は _isNull だけ。
    ///
    def leafArgs(owner: ContentType): List[LeafArg] =
        (idLeaf("id_eq", EntryId.parse, Condition.IdEq) |> describeLeaf("entry の id が一致")) ::
        (idsLeaf("id_in", EntryId.parse, Condition.IdIn) |> describeLeaf("entry の id が一覧のどれかに一致")) ::
        systemDateLeaves() :::
        List.flatMap(fieldLeafArgs(TypeName.text(owner#singular)), owner#fields)

    ///
    /// システムの日時（createdAt / updatedAt / publishedAt）の範囲の葉。`publishedAt_gte` の形で、前回の同期からの差分を引くための物。
    /// 名前は SortKey の組み込みと同じで、Naming が予約しているのでフィールドの apiId とはぶつからない。
    ///
    def systemDateLeaves(): List[LeafArg] =
        SystemDate.all() |> List.flatMap(key ->
            RangeOp.all() |> List.map(op ->
                dateLeaf("${SystemDate.toText(key)}_${RangeOp.toText(op)}", at -> Condition.SystemDateCmp(key, op, at))
                    |> describeLeaf("${SystemDate.toText(key)} が${rangeText(op)}。${dateValueHint()}")))

    def fieldLeafArgs(prefix: String, field: FieldDef): List[LeafArg] =
        let name = ApiId.text(field#apiId);
        let isNull = leafArg("${name}_isNull", GqlCodec.bool(), flag -> Condition.IsNull(field#apiId, flag) :: Nil)
            |> describeLeaf("値が無い（true）・ある（false）");
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
            case FieldKind.DateOnly  => Nil
            case FieldKind.Reference => (idLeaf(name, EntryId.parse, found -> Condition.ArrayContains(apiId, EntryId.text(found))) |> describeLeaf("参照先の一覧にその entry の id を含む。slug で絞りたい時は参照先の一覧を先に引いて id を得る")) :: Nil
            case FieldKind.Asset     => (idLeaf(name, AssetId.parse, found -> Condition.ArrayContains(apiId, AssetId.text(found))) |> describeLeaf("一覧にその asset の id を含む")) :: Nil
            case FieldKind.Select    => (leafArg(name, selectCodec(prefix, field), text -> Condition.ArrayContains(apiId, text) :: Nil) |> describeLeaf("一覧にその選択肢を含む")) :: Nil
            case _                   => (leafArg(name, GqlCodec.string(), text -> Condition.ArrayContains(apiId, text) :: Nil) |> describeLeaf("一覧にその値を含む（要素と完全一致。大文字小文字を区別する）")) :: Nil
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
            case FieldKind.Asset     => (idLeaf("${name}_id_eq", AssetId.parse, found -> Condition.TextEq(apiId, AssetId.text(found))) |> describeLeaf("asset の id が一致")) :: Nil
            case FieldKind.Reference =>
                (idLeaf("${name}_id_eq", EntryId.parse, found -> Condition.TextEq(apiId, EntryId.text(found))) |> describeLeaf("参照先の entry の id が一致。slug で絞りたい時は参照先の一覧を先に引いて id を得る")) ::
                (idsLeaf("${name}_id_in", EntryId.parse, found -> Condition.TextIn(apiId, List.map(EntryId.text, found))) |> describeLeaf("参照先の entry の id が一覧のどれかに一致")) :: Nil
            case FieldKind.Select    => equalityLeaves(name, apiId, selectCodec(prefix, field), "選択肢")
            case FieldKind.Number    => numberLeaves(name, apiId)
            case FieldKind.Date      => dateLeaves(name, apiId)
            case FieldKind.DateOnly  => dateOnlyLeaves(name, apiId)
            case FieldKind.Boolean   => (leafArg("${name}_eq", GqlCodec.bool(), b -> Condition.BoolEq(apiId, b) :: Nil) |> describeLeaf("真偽が一致")) :: Nil
            case _                   => equalityLeaves(name, apiId, GqlCodec.string(), "文字列") ::: searchLeaves(name, apiId)
        }

    /// `_eq` / `_in`。SELECT なら enum の codec、文字列なら String。what は説明に出す値の呼び名。
    def equalityLeaves(name: String, apiId: ApiId, codec: GqlCodec[String], what: String): List[LeafArg] =
        (leafArg("${name}_eq", codec, text -> Condition.TextEq(apiId, text) :: Nil) |> describeLeaf("${what}が一致（完全一致。大文字小文字を区別する）")) ::
        (leafArg("${name}_in", GqlCodec.list(codec), texts -> Condition.TextIn(apiId, texts) :: Nil) |> describeLeaf("${what}が一覧のどれかに一致（完全一致。大文字小文字を区別する）")) :: Nil

    /// `_contains` / `_startsWith`。文字列だけ。
    def searchLeaves(name: String, apiId: ApiId): List[LeafArg] =
        (leafArg("${name}_contains", GqlCodec.string(), text -> Condition.TextContains(apiId, text) :: Nil) |> describeLeaf("部分一致。大文字小文字を区別しない")) ::
        (leafArg("${name}_startsWith", GqlCodec.string(), text -> Condition.TextStartsWith(apiId, text) :: Nil) |> describeLeaf("前方一致。大文字小文字を区別しない")) :: Nil

    /// `_eq` と範囲の 4 つ。
    def numberLeaves(name: String, apiId: ApiId): List[LeafArg] =
        (leafArg("${name}_eq", GqlCodec.float64(), x -> Condition.NumberEq(apiId, x) :: Nil) |> describeLeaf("数値が一致")) ::
        (leafArg("${name}_gt", GqlCodec.float64(), x -> Condition.NumberGt(apiId, x) :: Nil) |> describeLeaf("より大きい")) ::
        (leafArg("${name}_gte", GqlCodec.float64(), x -> Condition.NumberGte(apiId, x) :: Nil) |> describeLeaf("以上")) ::
        (leafArg("${name}_lt", GqlCodec.float64(), x -> Condition.NumberLt(apiId, x) :: Nil) |> describeLeaf("より小さい")) ::
        (leafArg("${name}_lte", GqlCodec.float64(), x -> Condition.NumberLte(apiId, x) :: Nil) |> describeLeaf("以下")) :: Nil

    ///
    /// DATE の `_eq` と範囲の 4 つ。値は ISO 8601 の日時か日付（"2026-09-08" は UTC の 0 時）。読めない文字列は Never（何にも合わない）に倒す。
    ///
    def dateLeaves(name: String, apiId: ApiId): List[LeafArg] =
        (dateLeaf("${name}_eq", at -> Condition.DateEq(apiId, at)) |> describeLeaf("同じ瞬間。${dateValueHint()}")) ::
        (RangeOp.all() |> List.map(op -> dateLeaf("${name}_${RangeOp.toText(op)}", dateCondition(apiId, op)) |> describeLeaf("${rangeText(op)}。${dateValueHint()}")))

    /// DATE の範囲の条件。RangeOp ごとに Condition の case が分かれている。
    def dateCondition(apiId: ApiId, op: RangeOp, at: Timestamp.Timestamp): Condition = match op {
        case RangeOp.Gt  => Condition.DateGt(apiId, at)
        case RangeOp.Gte => Condition.DateGte(apiId, at)
        case RangeOp.Lt  => Condition.DateLt(apiId, at)
        case RangeOp.Lte => Condition.DateLte(apiId, at)
    }

    def dateLeaf(name: String, make: Timestamp.Timestamp -> Condition): LeafArg =
        leafArg(name, GqlCodec.string(), text -> (DateValues.parse(text) |> Option.map(make) |> Option.getWithDefault(Condition.Never)) :: Nil)

    ///
    /// DATE_ONLY の `_eq` と範囲の 4 つ。値は日付（"2026-09-09"）。時刻付きの引数は UTC で見た日付として読む。読めない文字列は Never（何にも合わない）に倒す。
    ///
    def dateOnlyLeaves(name: String, apiId: ApiId): List[LeafArg] =
        (dateOnlyLeaf("${name}_eq", on -> Condition.DateOnlyEq(apiId, on)) |> describeLeaf("同じ日。${dateOnlyValueHint()}")) ::
        (RangeOp.all() |> List.map(op -> dateOnlyLeaf("${name}_${RangeOp.toText(op)}", on -> Condition.DateOnlyCmp(apiId, op, on)) |> describeLeaf("${rangeText(op)}。${dateOnlyValueHint()}")))

    def dateOnlyLeaf(name: String, make: Date.Date -> Condition): LeafArg =
        leafArg(name, GqlCodec.string(), text -> (DateOnlyValues.parse(text) |> Option.map(make) |> Option.getWithDefault(Condition.Never)) :: Nil)

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
