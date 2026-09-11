///
/// スキーマの変更が既存のデータに起こす事。
///
pub enum SchemaEffectKind with Eq, Order, ToString {
    /// 値が配信から消える。DB には残る
    case ValuesHidden
    /// 参照が配信から消える（REFERENCE / RICH_TEXT）
    case ReferencesHidden
    /// asset の参照が配信から消える
    case AssetsHidden
    /// 消したはずの値が配信に戻る
    case ValuesResurrected
    /// 公開中の entry が再公開できなくなる
    case PublishBlocked
    /// 下書きの保存が通らなくなる
    case DraftBlocked
    /// 型と一緒に entry が消える
    case EntriesRemoved
}

///
/// 影響 1 つ。apiId は型ごとの変更（EntriesRemoved）では None。
/// entries は当たる entry の見本（先頭 `FieldImpact.sampleSize()` 件）。件数は draft / published が正で、見本は画面に並べる分だけ。
///
pub type alias SchemaEffect = { kind = SchemaEffectKind, typeId = TypeId, apiId = Option[ApiId], draft = Int64, published = Int64, entries = List[EntryId] }

///
/// 押す前に見せる影響のまとまり。safe なら確認なしで押せる。
///
pub type alias SchemaImpact = { safe = Bool, effects = List[SchemaEffect] }

///
/// 当たった数と、その見本。total は全部の件数、entries は先頭の何件か（SQL が LIMIT で絞る）。
///
pub type alias Hit = { total = Int64, entries = List[EntryId] }

///
/// フィールド 1 本の数え上げ。SQL が埋める。
///
/// - draft / published: その apiId に値を持つ entry
/// - missingPublished: 公開中だが値が無い entry（required を立てると再公開できなくなる）
/// - outsideConfig: 新しい config に収まらない値を持つ entry（下書きの保存が通らなくなる）
/// - duplicatePublished: 公開中で値が重なっている entry（unique を立てると再公開できなくなる）
///
pub type alias FieldCount = { typeId = TypeId, apiId = ApiId, draft = Hit, published = Hit, missingPublished = Hit, outsideConfig = Hit, duplicatePublished = Hit }

///
/// 型 1 つの数え上げ。
///
pub type alias TypeCount = { typeId = TypeId, entries = Hit }

///
/// スキーマの変更と数え上げから、既存のデータに何が起きるかを出す。純粋。
///
/// **0 件なら何も返さない。** 影響が空かどうかがそのまま確認の要否になるので、
/// 「起きるかもしれない」は出さず、実際に当たる entry がある物だけを返す。
///
/// WhyNot: Datalog で書かない。導出に再帰が要らないため。入れ子の親を消した時に子も
/// 出るのは SchemaDiff が木を平らにして解いていて、ここに残るのは 1 段の写しだけ。
///
/// WhyNot: ここで件数から違反を作らない。「値がある」の定義（空文字と空の配列を値なしと見る）は
/// EntryValidation が持つ。SQL は候補を絞って数えるだけにして、判定の口を 1 つに保つ。
///
mod FieldImpact {

    ///
    /// 見本として持つ entry の数。SQL の LIMIT と、下書きと公開中を合わせた時の上限の両方がこれ。
    ///
    /// WhyNot: 全部返さない。画面に並べられるのは数件で、残りは「他 N 件」で足りる。
    /// 件数（total）は別に正確に持つので、見本を絞っても判定は変わらない。
    ///
    pub def sampleSize(): Int32 = 5

    /// 何も当たっていない。
    pub def none(): Hit = { total = 0i64, entries = Nil }

    ///
    /// 変更の順に影響を並べる。数え上げの無いフィールドは、当たる entry が無いのと同じ。
    ///
    pub def of(changes: List[SchemaChange], fields: List[FieldCount], types: List[TypeCount]): List[SchemaEffect] =
        let byField = fields |> List.map(count -> ((count#typeId, count#apiId), count)) |> List.toMap;
        let byType = types |> List.map(count -> (count#typeId, count)) |> List.toMap;
        changes |> List.flatMap(change -> effectsOf(byField, byType, change))

    def effectsOf(byField: Map[(TypeId, ApiId), FieldCount], byType: Map[TypeId, TypeCount], change: SchemaChange): List[SchemaEffect] =
        match change {
            case SchemaChange.FieldRemoved(field)          => countOf(byField, field) |> Option.map(removed(field)) |> Option.getWithDefault(Nil)
            case SchemaChange.FieldAdded(field)            => countOf(byField, field) |> Option.map(resurrected(field)) |> Option.getWithDefault(Nil)
            case SchemaChange.FieldRequired(field)         => countOf(byField, field) |> Option.map(blocked(field, count -> count#missingPublished)) |> Option.getWithDefault(Nil)
            case SchemaChange.FieldUnique(field)           => countOf(byField, field) |> Option.map(blocked(field, count -> count#duplicatePublished)) |> Option.getWithDefault(Nil)
            case SchemaChange.FieldConfigNarrowed(field, _) => countOf(byField, field) |> Option.map(narrowed(field)) |> Option.getWithDefault(Nil)
            case SchemaChange.TypeRemoved(owner)           => Map.get(owner#id, byType) |> Option.map(entriesRemoved(owner)) |> Option.getWithDefault(Nil)
            // 既存のデータに触らない
            case SchemaChange.TypeAdded(_)                 => Nil
            case SchemaChange.FieldsReordered(_)           => Nil
        }

    def countOf(byField: Map[(TypeId, ApiId), FieldCount], field: FieldDef): Option[FieldCount] =
        Map.get((field#typeId, field#apiId), byField)

    /// 消したフィールドに値があれば配信から消える。参照と asset は追加で出す（壊れる先が別にあるため）。
    def removed(field: FieldDef, count: FieldCount): List[SchemaEffect] =
        let sample = both(count#draft, count#published);
        if (count#draft#total + count#published#total == 0i64) Nil
        else effect(SchemaEffectKind.ValuesHidden, field, count#draft#total, count#published#total, sample)
            ::: (if (makesLink(field#kind)) effect(SchemaEffectKind.ReferencesHidden, field, count#draft#total, count#published#total, sample) else Nil)
            ::: (if (field#kind == FieldKind.Asset) effect(SchemaEffectKind.AssetsHidden, field, count#draft#total, count#published#total, sample) else Nil)

    /// 下書きと公開中の見本を合わせる。同じ entry が両方にいれば 1 つ、公開中を先に。
    def both(draft: Hit, published: Hit): List[EntryId] =
        (published#entries ::: draft#entries) |> List.distinct |> List.take(sampleSize())

    /// 本文のリンクとフィールドの参照。OBJECT / BLOCKS は器で、参照を持つのは子なので入れない。
    def makesLink(kind: FieldKind): Bool = kind == FieldKind.Reference or kind == FieldKind.RichText

    /// 足したフィールドの apiId に値が残っていれば、消したはずの値が配信に戻る。
    def resurrected(field: FieldDef, count: FieldCount): List[SchemaEffect] =
        if (count#draft#total + count#published#total == 0i64) Nil
        else effect(SchemaEffectKind.ValuesResurrected, field, count#draft#total, count#published#total, both(count#draft, count#published))

    /// 締めた性質。当たるのは公開中の entry なので published にだけ数を載せる。
    def blocked(field: FieldDef, pick: FieldCount -> Hit, count: FieldCount): List[SchemaEffect] =
        let hit = pick(count);
        if (hit#total == 0i64) Nil else effect(SchemaEffectKind.PublishBlocked, field, 0i64, hit#total, hit#entries)

    /// 締めた config。下書きの検査に当たるので draft に載せる。
    def narrowed(field: FieldDef, count: FieldCount): List[SchemaEffect] =
        let hit = count#outsideConfig;
        if (hit#total == 0i64) Nil else effect(SchemaEffectKind.DraftBlocked, field, hit#total, 0i64, hit#entries)

    def entriesRemoved(owner: ContentType, count: TypeCount): List[SchemaEffect] =
        if (count#entries#total == 0i64) Nil
        else { kind = SchemaEffectKind.EntriesRemoved, typeId = owner#id, apiId = None, draft = 0i64, published = count#entries#total, entries = count#entries#entries } :: Nil

    def effect(kind: SchemaEffectKind, field: FieldDef, draft: Int64, published: Int64, entries: List[EntryId]): List[SchemaEffect] =
        { kind = kind, typeId = field#typeId, apiId = Some(field#apiId), draft = draft, published = published, entries = entries } :: Nil

}
