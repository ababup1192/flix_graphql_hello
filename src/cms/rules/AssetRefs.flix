///
/// entry の中身から asset の参照（ASSET のフィールドの値と、RICH_TEXT の image）を取り出す。純粋。
/// 公開時に「asset が実在して ready か」を見る元と、消す時の使用中検査の裏付けに使う。
///
mod AssetRefs {

    ///
    /// 中身の中の全 asset id。重複を除く。規則に合わない物は捨てる（下書きの検証が先に止める）。Object と Blocks の中も辿る。
    ///
    pub def extract(fields: List[FieldDef], data: EntryData): List[AssetId] =
        fields |> List.flatMap(field -> match (field#kind, field#many) {
            case (FieldKind.Asset, false) => EntryValue.text(field#apiId, data) |> Option.flatMap(AssetId.parse) |> Option.toList
            case (FieldKind.Asset, true)  => EntryValue.texts(field#apiId, data) |> List.filterMap(AssetId.parse)
            case (FieldKind.RichText, _)  => Map.get(field#apiId, data) |> Option.map(RichText.assetIds) |> Option.getWithDefault(Nil)
            case (FieldKind.Object, false) => EntryValue.object(field#apiId, data) |> Option.map(extract(Children.toList(field#children))) |> Option.getWithDefault(Nil)
            case (FieldKind.Object, true)  => EntryValue.objects(field#apiId, data) |> List.flatMap(extract(Children.toList(field#children)))
            case (FieldKind.Blocks, _)     => EntryValue.blocks(field, data) |> List.flatMap(match (variant, inner) -> extract(Children.toList(variant#children), inner))
            case _ => Nil
        }) |> List.distinct

}
