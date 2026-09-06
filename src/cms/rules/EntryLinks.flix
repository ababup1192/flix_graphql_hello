///
/// entry の中身から参照（Reference のフィールドの値）を取り出す。純粋。entry_links に写す元と、参照の展開に使う。
///
mod EntryLinks {

    use Util.Json.Json

    ///
    /// 参照 1 つ。(フィールド, 参照先の id, 配列の中の位置)。
    ///
    pub type alias Link = { field = FieldDef, target = EntryId, position = Int32 }

    ///
    /// 中身の中の全参照。規則に合わない id は捨てる（下書きの検証が先に止める）。
    ///
    pub def extract(fields: List[FieldDef], data: EntryData): List[Link] =
        fields |> List.filter(field -> field#kind == FieldKind.Reference) |> List.flatMap(field ->
            match Map.get(field#apiId, data) {
                case Some(Json.JString(text))  => EntryId.parse(text) |> Option.map(target -> { field = field, target = target, position = 0 }) |> Option.toList
                case Some(Json.JArray(items)) =>
                    items |> Vector.toList |> List.zipWithIndex |> List.filterMap(match (index, item) -> match item {
                        case Json.JString(text) => EntryId.parse(text) |> Option.map(target -> { field = field, target = target, position = index })
                        case _                  => None
                    })
                case _ => Nil
            })

    ///
    /// 参照先の id だけ。重複を除く。
    ///
    pub def targets(fields: List[FieldDef], data: EntryData): List[EntryId] =
        extract(fields, data) |> List.map(link -> link#target) |> List.distinct

}
