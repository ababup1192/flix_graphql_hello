///
/// entry の中身から参照（Reference のフィールドの値と、RichText の本文内のリンク）を取り出す。純粋。entry_links に写す元と、参照の展開に使う。
/// 本文内のリンクも entry_links に載せるのは、リンク先を消したり取り下げたりした時に「壊れる」と分かるようにするため。
///
mod EntryLinks {

    ///
    /// 参照 1 つ。(フィールド, 参照先の id, 配列の中の位置)。
    ///
    pub type alias Link = { field = FieldDef, target = EntryId, position = Int32 }

    ///
    /// 中身の中の全参照。規則に合わない id は捨てる（下書きの検証が先に止める）。Object と Blocks の中も辿る。
    ///
    pub def extract(fields: List[FieldDef], data: EntryData): List[Link] =
        fields |> List.flatMap(field -> match (field#kind, field#many) {
            case (FieldKind.Reference, false) =>
                EntryValue.text(field#apiId, data) |> Option.flatMap(EntryId.parse) |> Option.map(target -> { field = field, target = target, position = 0 }) |> Option.toList
            case (FieldKind.Reference, true) =>
                Map.get(field#apiId, data) |> Option.map(EntryValue.itemsWithIndex(item -> EntryValue.asString(item) |> Option.flatMap(EntryId.parse))) |> Option.getWithDefault(Nil)
                    |> List.map(match (index, target) -> { field = field, target = target, position = index })
            case (FieldKind.Object, false) =>
                EntryValue.object(field#apiId, data) |> Option.map(extract(Children.toList(field#children))) |> Option.getWithDefault(Nil)
            case (FieldKind.Object, true) =>
                EntryValue.objects(field#apiId, data) |> List.flatMap(extract(Children.toList(field#children)))
            case (FieldKind.Blocks, _) =>
                EntryValue.blocks(field, data) |> List.flatMap(match (variant, inner) -> extract(Children.toList(variant#children), inner))
            case (FieldKind.RichText, _) =>
                Map.get(field#apiId, data) |> Option.map(RichText.linkedEntryIds) |> Option.getWithDefault(Nil)
                    |> List.zipWithIndex |> List.map(match (index, target) -> { field = field, target = target, position = index })
            case _ => Nil
        })

    ///
    /// 参照先の id だけ。重複を除く。
    ///
    pub def targets(fields: List[FieldDef], data: EntryData): List[EntryId] =
        extract(fields, data) |> List.map(link -> link#target) |> List.distinct

}
