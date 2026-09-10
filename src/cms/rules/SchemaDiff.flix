///
/// スキーマの変更。既存のデータに影響しうる物だけ。
///
/// FieldConfigNarrowed が持つ config は**変更前**の物。何を外したかを数えるのに要る。
///
pub enum SchemaChange {
    case TypeAdded(ContentType)
    case TypeRemoved(ContentType)
    case FieldAdded(FieldDef)
    case FieldRemoved(FieldDef)
    case FieldRequired(FieldDef)
    case FieldUnique(FieldDef)
    case FieldConfigNarrowed(FieldDef, FieldConfig)
    case FieldsReordered(TypeId)
}

///
/// config のどこを、どこまで締めたか。種類ごとに 1 つ（SELECT は選択肢、文字列は上限、NUMBER は範囲）。
/// 数え上げがそのまま SQL に渡す。
///
/// Range が持つのは**締めた側だけ**。触っていない側の範囲から外れていた値は前から保存できなかったので、
/// 今回の影響には入れない。
///
pub enum Narrowing with Eq {
    /// 残る選択肢
    case Options(List[String])
    /// 新しい上限（文字数）
    case MaxLength(Int32)
    /// 上げた下限、下げた上限、整数に限ったか
    case Range(Option[Float64], Option[Float64], Bool)
}

///
/// スキーマ全体の前後から変更の列を出す。純粋。
///
/// 出すのは「既存のデータに影響しうる変更」だけ。緩める側（required を外す、選択肢を足す、
/// 上限を伸ばす）と、見た目だけの変更（name、アイコン、previewUrl）は出さない。
///
/// WhyNot: mutation ごとに影響を書かない。書くと reorderFields のように影響の確認を
/// 通らない mutation が残り、親を消した時に一緒に消える子も手で数える事になる。
///
/// WhyNot: フィールドを apiId ではなく id で突き合わせる。消して同じ apiId で足し直すと
/// 別のフィールドになり（値が意図せず配信に戻る）、それを「変わっていない」にすると隠れる。
///
mod SchemaDiff {

    ///
    /// 前後の差。型は id で、フィールドは id で突き合わせる。並びは型の id 順、
    /// その中はフィールドの木の順（親が先）。
    ///
    pub def diff(before: List[ContentType], after: List[ContentType]): List[SchemaChange] =
        let olds = byId(before);
        let news = byId(after);
        let removed = before |> List.filter(owner -> not Map.memberOf(owner#id, news)) |> List.map(owner -> SchemaChange.TypeRemoved(owner));
        let added = after |> List.filter(owner -> not Map.memberOf(owner#id, olds)) |> List.map(owner -> SchemaChange.TypeAdded(owner));
        let kept = after |> List.filterMap(owner -> Map.get(owner#id, olds) |> Option.map(was -> withinType(was, owner))) |> List.flatten;
        removed ::: added ::: kept

    def byId(types: List[ContentType]): Map[TypeId, ContentType] =
        types |> List.map(owner -> (owner#id, owner)) |> List.toMap

    /// 型 1 つの中の差。フィールドの増減・締めた性質・締めた config・並び。
    def withinType(was: ContentType, now: ContentType): List[SchemaChange] =
        let olds = FieldTree.flatten(was#fields);
        let news = FieldTree.flatten(now#fields);
        let oldById = fieldsById(olds);
        let newById = fieldsById(news);
        let removed = olds |> List.filter(field -> not Map.memberOf(field#id, newById)) |> List.map(field -> SchemaChange.FieldRemoved(field));
        let added = news |> List.filter(field -> not Map.memberOf(field#id, oldById)) |> List.map(field -> SchemaChange.FieldAdded(field));
        let tightened = news |> List.flatMap(field -> Map.get(field#id, oldById) |> Option.map(narrowed(field)) |> Option.getWithDefault(Nil));
        removed ::: added ::: tightened ::: reordered(olds, news)

    def fieldsById(fields: List[FieldDef]): Map[FieldId, FieldDef] =
        fields |> List.map(field -> (field#id, field)) |> List.toMap

    /// 同じフィールドで締めた所。緩めた所は出さない。
    def narrowed(now: FieldDef, was: FieldDef): List[SchemaChange] =
        (if (now#required and not was#required) SchemaChange.FieldRequired(now) :: Nil else Nil) :::
        (if (now#unique and not was#unique) SchemaChange.FieldUnique(now) :: Nil else Nil) :::
        (if (configNarrowed(was#config, now#config)) SchemaChange.FieldConfigNarrowed(now, was#config) :: Nil else Nil)

    /// config を締めたか。
    def configNarrowed(was: FieldConfig, now: FieldConfig): Bool = Option.nonEmpty(narrowing(was, now))

    ///
    /// config を締めたなら、どこをどこまで締めたか。選択肢を外す・上限を縮める・下限を上げる・整数に限る、が締める側。
    ///
    /// WhyNot: 選択肢は「数が減ったか」で見ない。B を消して C を足すと数は同じだが、B の値は取り残される。
    /// 前にあった選択肢が 1 つでも無くなっていれば締めた事にする。
    ///
    /// WhyNot: sourceField（slug の元）の変更は締めた事にしない。既にある値はそのまま残り、
    /// 次に作る entry の初期値が変わるだけ。
    ///
    pub def narrowing(was: FieldConfig, now: FieldConfig): Option[Narrowing] =
        let optionDropped = List.exists(option -> not List.memberOf(option, now#options), was#options);
        let low = if (tightenedLower(was#min, now#min)) now#min else None;
        let high = if (tightenedUpperFloat(was#max, now#max)) now#max else None;
        let integer = now#integer == Some(true) and was#integer != Some(true);
        if (optionDropped) Some(Narrowing.Options(now#options))
        else if (tightenedUpper(was#maxLength, now#maxLength)) now#maxLength |> Option.map(Narrowing.MaxLength)
        else if (Option.nonEmpty(low) or Option.nonEmpty(high) or integer) Some(Narrowing.Range(low, high, integer))
        else None

    /// 上限: 無かった所に付く、または小さくなる。
    def tightenedUpper(was: Option[Int32], now: Option[Int32]): Bool = match (was, now) {
        case (None, Some(_))            => true
        case (Some(old), Some(fresh))   => fresh < old
        case _                          => false
    }

    def tightenedUpperFloat(was: Option[Float64], now: Option[Float64]): Bool = match (was, now) {
        case (None, Some(_))            => true
        case (Some(old), Some(fresh))   => fresh < old
        case _                          => false
    }

    /// 下限: 無かった所に付く、または大きくなる。
    def tightenedLower(was: Option[Float64], now: Option[Float64]): Bool = match (was, now) {
        case (None, Some(_))            => true
        case (Some(old), Some(fresh))   => fresh > old
        case _                          => false
    }

    ///
    /// 並びが変わったか。中身は変わらないが、配信に出る順が変わる。
    ///
    /// WhyNot: フィールドごとに出さない。並べ替えは 1 回の操作で複数のフィールドが動くので、
    /// 型ごとに 1 つで足りる。
    ///
    def reordered(olds: List[FieldDef], news: List[FieldDef]): List[SchemaChange] =
        let shared = news |> List.filterMap(field -> if (List.exists(old -> old#id == field#id, olds)) Some(field#id) else None);
        let before = olds |> List.filterMap(field -> if (List.memberOf(field#id, shared)) Some(field#id) else None);
        match List.head(news) {
            case None        => Nil
            case Some(first) => if (shared == before) Nil else SchemaChange.FieldsReordered(first#typeId) :: Nil
        }

}
