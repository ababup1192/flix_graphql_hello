///
/// AssetRows: assets の行とドメインの Asset の往復。純粋（DbErr は Result に落として見る）。
///
/// 観点:
/// - 往復: status の全 case、寸法の None ↔ 0、時刻（ms）
/// - 境界: 0 以下の寸法は不明（None）。知らない status と規則外の id は DbErr
///
mod TestAssetRows {

    def at(millis: Int64): Timestamp.Timestamp = Timestamp.fromEpochMillis(millis)

    def asset(status: AssetStatus, width: Option[Int32], height: Option[Int32]): Asset =
        { id = AssetId.AssetId("img-01_A"), key = "1/img-01_A/写真.png", fileName = "写真.png", mime = "image/png", size = 123456789012i64,
          width = width, height = height, alt = "", status = status, createdAt = at(1725000000123i64) }

    def rowOf(source: Asset): { id = String, key = String, fileName = String, mime = String, size = Int64, width = Int32, height = Int32, alt = String, status = String, createdAt = Timestamp.Timestamp } =
        { id = AssetId.text(source#id), key = source#key, fileName = source#fileName, mime = source#mime, size = source#size,
          width = AssetRows.dimensionToDb(source#width), height = AssetRows.dimensionToDb(source#height), alt = source#alt,
          status = AssetRows.statusToDb(source#status), createdAt = source#createdAt }

    def flatten(source: Asset): (AssetId, String, String, String, Int64, Option[Int32], Option[Int32], String, AssetStatus, Timestamp.Timestamp) =
        (source#id, source#key, source#fileName, source#mime, source#size, source#width, source#height, source#alt, source#status, source#createdAt)

    /// status は DB の文字列と往復し、知らない文字列は None。
    @Test
    def testAssetStatusRoundTrip(): Unit \ Assert =
        let statuses = List#{AssetStatus.Pending, AssetStatus.Ready};
        Assert.assertEq(expected = (List.map(Some, statuses), None),
            (statuses |> List.map(status -> AssetRows.statusFromDb(AssetRows.statusToDb(status))), AssetRows.statusFromDb("uploaded")))

    /// Asset → 行 → Asset で全項目が同じ。寸法の None は列の 0 と対になる。
    @Test
    def testAssetRoundTrip(): Unit \ Assert =
        let table = List#{asset(AssetStatus.Pending, None, None), asset(AssetStatus.Ready, Some(1920), Some(1080)), asset(AssetStatus.Ready, Some(1), None)};
        Assert.assertEq(expected = table |> List.map(source -> Ok(flatten(source))),
            table |> List.map(source -> DbErr.runWithResult(() -> AssetRows.toAsset(rowOf(source)) |> flatten)))

    /// 列の 0 と負の寸法は不明（None）。
    @Test
    def testAssetDimensionBoundary(): Unit \ Assert =
        Assert.assertEq(expected = Ok((None, None)),
            DbErr.runWithResult(() -> {
                let found = AssetRows.toAsset({ width = 0, height = -1 | rowOf(asset(AssetStatus.Ready, None, None)) });
                (found#width, found#height)
            }))

    /// 知らない status と規則外の id は DbErr。
    @Test
    def testToAssetRejects(): Unit \ Assert =
        let good = rowOf(asset(AssetStatus.Ready, None, None));
        let table = List#{ { status = "uploaded" | good }, { id = "img 01" | good }, { id = "" | good } };
        Assert.assertEq(expected = List.repeat(List.length(table), true),
            table |> List.map(row -> DbErr.runWithResult(() -> AssetRows.toAsset(row)) |> Result.isErr))

}
