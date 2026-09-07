///
/// 行差分の 1 行。
///
pub enum DiffLine with Eq, ToString {
    /// 両方にある
    case Same(String)
    /// after にだけある
    case Add(String)
    /// before にだけある
    case Del(String)
}

///
/// 1 つのフィールド（か配列の 1 要素）の変わり方。
///
pub enum Change with Eq, ToString {
    /// after にだけある
    case Added(Util.Json.Json)
    /// before にだけある
    case Removed(Util.Json.Json)
    /// 値が違う（before, after）
    case Changed(Util.Json.Json, Util.Json.Json)
    /// OBJECT / BLOCKS / many の中で違う
    case Nested(List[FieldChange])
    /// RICH_TEXT の Markdown の行差分
    case Text(List[DiffLine])
}

///
/// 変わったフィールド。(パス, 変わり方)。パスは最上位から辿った表記（"title" / "hero.cta.label" / "tags[2]" / "sections[0].headline"）。
///
/// WhyNot: パスを ApiId や段（apiId か位置）の型で持たないのは、GraphQL の FieldChange の source がこの値そのもので、
/// children のリゾルバは親を知らないため。各要素が自分の完全なパスを持つ必要がある。
/// WhyNot: レコードにしないのは、Change の payload に入るので Eq が要るため（レコードは Eq を持てない）。
///
pub enum FieldChange with Eq, ToString {
    case FieldChange(String, Change)
}

mod FieldChange {

    pub def path(fieldChange: FieldChange): String =
        let FieldChange.FieldChange(found, _) = fieldChange;
        found

    pub def change(fieldChange: FieldChange): Change =
        let FieldChange.FieldChange(_, found) = fieldChange;
        found

}

///
/// entry の 2 つのバージョンの中身の差分。全部純粋。
///
/// kind ごとの比べ方: スカラー（TEXT / TEXT_AREA / SLUG / NUMBER / BOOLEAN / SELECT / REFERENCE / ASSET / DATE）は JSON の等値。
/// many は位置で比べ、位置ごとの差を Nested に入れる。OBJECT は children で再帰。BLOCKS は同じ位置で同じ variant なら中を再帰、違えば Changed。
/// RICH_TEXT は両方を Markdown に落として行の差分（Text）。null と「キーが無い」は同じ。定義に無いキーは Added / Removed で残す。
/// 出力は定義の position 順で、定義に無い物は最後（apiId 順）。
///
mod EntryDiff {

    use Util.Json.Json

    ///
    /// before と after の差分。同じなら Nil。パスは最上位から。
    ///
    pub def diff(fields: List[FieldDef], before: EntryData, after: EntryData): List[FieldChange] =
        diffAt("", fields, before, after)

    /// parent 付き。入れ子（OBJECT / BLOCKS）はパスが "hero.headline" のように伸びる。
    def diffAt(parent: String, fields: List[FieldDef], before: EntryData, after: EntryData): List[FieldChange] =
        let defined = fields |> List.sortBy(field -> field#position);
        let known = defined |> List.map(field -> field#apiId) |> List.toSet;
        let definedChanges = defined |> List.filterMap(field ->
            diffField(fieldPath(parent, field#apiId), field, present(field#apiId, before), present(field#apiId, after))
                |> Option.map(change -> FieldChange.FieldChange(fieldPath(parent, field#apiId), change)));
        let unknownChanges = Set.union(Map.keysOf(before), Map.keysOf(after)) |> Set.toList |> List.filter(apiId -> not Set.memberOf(apiId, known)) |> List.filterMap(apiId ->
            diffPresence(present(apiId, before), present(apiId, after), (oldValue, newValue) -> Some(Change.Changed(oldValue, newValue)))
                |> Option.map(change -> FieldChange.FieldChange(fieldPath(parent, apiId), change)));
        definedChanges ::: unknownChanges

    /// "parent.apiId"。親が空なら apiId だけ。
    def fieldPath(parent: String, apiId: ApiId): String =
        if (String.isEmpty(parent)) ApiId.text(apiId) else "${parent}.${ApiId.text(apiId)}"

    /// "parent[i]"。
    def indexPath(parent: String, index: Int32): String = "${parent}[${index}]"

    /// キーの値。無いか null なら None。
    def present(apiId: ApiId, data: EntryData): Option[Json] = Map.get(apiId, data) |> Option.filter(value -> value != Json.JNull)

    /// 有無の違いを Added / Removed に。両方あれば compare で比べる。
    def diffPresence(before: Option[Json], after: Option[Json], compare: (Json, Json) -> Option[Change]): Option[Change] = match (before, after) {
        case (None, None)                       => None
        case (None, Some(added))                => Some(Change.Added(added))
        case (Some(removed), None)              => Some(Change.Removed(removed))
        case (Some(oldValue), Some(newValue))   => if (oldValue == newValue) None else compare(oldValue, newValue)
    }

    /// 1 つのフィールド。many なら配列を位置で比べる。
    def diffField(path: String, field: FieldDef, before: Option[Json], after: Option[Json]): Option[Change] =
        diffPresence(before, after, (oldValue, newValue) -> if (field#many) diffMany(path, field, oldValue, newValue) else diffScalar(path, field, oldValue, newValue))

    /// 配列を位置で。長さが違えば余った位置は Added / Removed。配列でない値は丸ごと Changed。
    def diffMany(path: String, field: FieldDef, before: Json, after: Json): Option[Change] = match (before, after) {
        case (Json.JArray(olds), Json.JArray(news)) =>
            let width = Int32.max(Vector.length(olds), Vector.length(news));
            let changes = List.zip(padded(width, olds), padded(width, news)) |> List.zipWithIndex |> List.filterMap(match (index, (oldValue, newValue)) ->
                diffPresence(oldValue, newValue, (oldItem, newItem) -> diffScalar(indexPath(path, index), field, oldItem, newItem))
                    |> Option.map(change -> FieldChange.FieldChange(indexPath(path, index), change)));
            nested(changes)
        case _ => Some(Change.Changed(before, after))
    }

    /// 要素を Some で包み、width まで None で埋める（null の要素は無い物）。
    def padded(width: Int32, items: Vector[Json]): List[Option[Json]] =
        (items |> Vector.toList |> List.map(item -> if (item == Json.JNull) None else Some(item))) ::: List.repeat(width - Vector.length(items), None)

    /// 1 つの値。OBJECT / BLOCKS は中を再帰、RICH_TEXT は行差分、他は Changed。
    def diffScalar(path: String, field: FieldDef, before: Json, after: Json): Option[Change] = match (field#kind, before, after) {
        case (FieldKind.Object, Json.JObject(olds), Json.JObject(news)) => nested(diffAt(path, Children.toList(field#children), EntryValue.objectData(olds), EntryValue.objectData(news)))
        case (FieldKind.Blocks, _, _)                                   => diffBlock(path, Children.toList(field#children), before, after)
        case (FieldKind.RichText, _, _)                                 => text(diffLines(Markdown.toMarkdown(before), Markdown.toMarkdown(after)))
        case _                                                          => Some(Change.Changed(before, after))
    }

    /// BLOCKS の 1 要素。同じ variant なら中を再帰、違う（か読めない）なら Changed。
    def diffBlock(path: String, variants: List[FieldDef], before: Json, after: Json): Option[Change] = match (EntryValue.readBlock(variants, before), EntryValue.readBlock(variants, after)) {
        case (Some((oldVariant, olds)), Some((newVariant, news))) if oldVariant#apiId == newVariant#apiId => nested(diffAt(path, Children.toList(oldVariant#children), olds, news))
        case _ => Some(Change.Changed(before, after))
    }

    def nested(changes: List[FieldChange]): Option[Change] = if (List.isEmpty(changes)) None else Some(Change.Nested(changes))

    /// 全部 Same なら差分無し。
    def text(lines: List[DiffLine]): Option[Change] = if (List.forAll(isSame, lines)) None else Some(Change.Text(lines))

    def isSame(line: DiffLine): Bool = match line {
        case DiffLine.Same(_) => true
        case _                => false
    }

    // ---- 行差分 ----

    ///
    /// 行単位の差分（LCS）。共通の行は Same、before にだけある行は Del、after にだけある行は Add。同じ所では Del が Add より先。
    ///
    pub def diffLines(before: String, after: String): List[DiffLine] =
        let olds = lines(before);
        let news = lines(after);
        backtrack(olds, news, lcsTable(olds, news), Vector.length(olds), Vector.length(news), Nil)

    /// 空文字列は 0 行。
    def lines(textValue: String): Vector[String] = if (String.isEmpty(textValue)) Vector.empty() else textValue |> String.splitOn(substr = "\n") |> List.toVector

    /// table[i][j] = olds の先頭 i 行と news の先頭 j 行の LCS の長さ。
    def lcsTable(olds: Vector[String], news: Vector[String]): Vector[Vector[Int32]] =
        let firstRow = Vector.repeat(Vector.length(news) + 1, 0);
        olds |> Vector.foldLeft((rows, oldValue) -> match rows {
            case previous :: _ => nextRow(previous, oldValue, news) :: rows
            case Nil           => rows
        }, firstRow :: Nil) |> List.reverse |> List.toVector

    /// 1 行分。左の値と上の行から埋める。
    def nextRow(previous: Vector[Int32], oldValue: String, news: Vector[String]): Vector[Int32] =
        news |> Vector.toList |> List.zipWithIndex |> List.foldLeft((cells, indexed) -> {
            let (index, newValue) = indexed;
            let left = List.head(cells) |> Option.getWithDefault(0);
            let cell = if (oldValue == newValue) Vector.get(index, previous) + 1 else Int32.max(Vector.get(index + 1, previous), left);
            cell :: cells
        }, 0 :: Nil) |> List.reverse |> List.toVector

    /// 表の右下から左上へ辿り、先頭に積む（結果は前から順）。同じ長さなら Add を先に取るので、出力では Del が Add より先になる。
    def backtrack(olds: Vector[String], news: Vector[String], table: Vector[Vector[Int32]], i: Int32, j: Int32, acc: List[DiffLine]): List[DiffLine] =
        if (i == 0 and j == 0) acc
        else if (i == 0) backtrack(olds, news, table, i, j - 1, DiffLine.Add(Vector.get(j - 1, news)) :: acc)
        else if (j == 0) backtrack(olds, news, table, i - 1, j, DiffLine.Del(Vector.get(i - 1, olds)) :: acc)
        else if (Vector.get(i - 1, olds) == Vector.get(j - 1, news)) backtrack(olds, news, table, i - 1, j - 1, DiffLine.Same(Vector.get(i - 1, olds)) :: acc)
        else if (cellAt(table, i, j - 1) >= cellAt(table, i - 1, j)) backtrack(olds, news, table, i, j - 1, DiffLine.Add(Vector.get(j - 1, news)) :: acc)
        else backtrack(olds, news, table, i - 1, j, DiffLine.Del(Vector.get(i - 1, olds)) :: acc)

    def cellAt(table: Vector[Vector[Int32]], i: Int32, j: Int32): Int32 = Vector.get(j, Vector.get(i, table))

}
