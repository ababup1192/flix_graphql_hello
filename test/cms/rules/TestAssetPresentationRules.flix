///
/// AssetPresentationRules: asset の注目点（focalPoint）と切り抜き枠（crop）の規則。純粋。
///
/// 観点:
/// - 範囲: 0〜1 の割合。crop は width / height が 0 より大きく、left + width と top + height が 1 以下
/// - 省略: どちらも無い（そのまま）は通る
/// - 直し方: Keep は変えない、Clear は消す、Set は置き換える。項目ごとに独立
///
mod TestAssetPresentationRules {

    def point(x: Float64, y: Float64): FocalPoint = { x = x, y = y }

    def rect(left: Float64, top: Float64, width: Float64, height: Float64): CropRect = { left = left, top = top, width = width, height = height }

    def presentation(focalPoint: Option[FocalPoint], crop: Option[CropRect]): AssetPresentation = { focalPoint = focalPoint, crop = crop }

    /// 比べやすい形に平らにする（レコードは Eq を持たない）。
    def flatten(source: AssetPresentation): (Option[(Float64, Float64)], Option[(Float64, Float64, Float64, Float64)]) =
        (source#focalPoint |> Option.map(found -> (found#x, found#y)),
         source#crop |> Option.map(found -> (found#left, found#top, found#width, found#height)))

    /// 違反の path だけ取り出す。
    def paths(violations: List[Violation]): List[String] =
        violations |> List.map(violation -> { let Violation.Violation(path, _) = violation; path })

    /// 範囲内の値は通る。両端（0 と 1）と、枠が右下に接する物も通る。
    @Test
    def testValidateAccepts(): Unit \ Assert =
        let table = List#{
            presentation(None, None),
            presentation(Some(point(0.5, 0.3)), None),
            presentation(None, Some(rect(0.0, 0.1, 1.0, 0.8))),
            presentation(Some(point(0.0, 0.0)), Some(rect(0.0, 0.0, 1.0, 1.0))),
            presentation(Some(point(1.0, 1.0)), Some(rect(0.25, 0.75, 0.75, 0.25)))
        };
        Assert.assertEq(expected = List.repeat(List.length(table), Nil),
            table |> List.map(AssetPresentationRules.validate))

    /// 範囲外は違反。path は `focalPoint.x` のようにどの値かが分かる形で、1 つの値に付く違反は 1 つ。
    ///
    ///   focalPoint: x / y が 0 未満・1 超
    ///   crop:       left / top が 0 未満・1 超、width / height が 0 以下・1 超、left + width / top + height が 1 超
    @Test
    def testValidateRejects(): Unit \ Assert =
        let table = List#{
            (presentation(Some(point(-0.1, 0.5)), None),                 List#{ "focalPoint.x" }),
            (presentation(Some(point(0.5, 1.5)), None),                  List#{ "focalPoint.y" }),
            (presentation(Some(point(2.0, -1.0)), None),                 List#{ "focalPoint.x", "focalPoint.y" }),
            (presentation(None, Some(rect(-0.1, 0.0, 0.5, 0.5))),        List#{ "crop.left" }),
            (presentation(None, Some(rect(0.0, 1.5, 0.5, 0.5))),         List#{ "crop.top" }),
            (presentation(None, Some(rect(0.0, 0.0, 0.0, 0.5))),         List#{ "crop.width" }),
            (presentation(None, Some(rect(0.0, 0.0, 0.5, -0.5))),        List#{ "crop.height" }),
            (presentation(None, Some(rect(0.0, 0.0, 1.5, 0.5))),         List#{ "crop.width" }),
            (presentation(None, Some(rect(0.5, 0.0, 0.6, 0.5))),         List#{ "crop.width" }),
            (presentation(None, Some(rect(0.0, 0.5, 0.5, 0.6))),         List#{ "crop.height" }),
            (presentation(Some(point(1.1, 0.5)), Some(rect(0.5, 0.5, 0.6, 0.6))), List#{ "focalPoint.x", "crop.width", "crop.height" })
        };
        Assert.assertEq(expected = table |> List.map(snd),
            table |> List.map(fst) |> List.map(AssetPresentationRules.validate) |> List.map(paths))

    /// Keep は今の値、Clear は無し、Set は新しい値。focalPoint と crop は互いに影響しない。
    @Test
    def testApplyTable(): Unit \ Assert =
        let current = presentation(Some(point(0.5, 0.3)), Some(rect(0.0, 0.1, 1.0, 0.8)));
        let table = List#{
            ({ focalPoint = Patch.Keep, crop = Patch.Keep },                              (Some((0.5, 0.3)), Some((0.0, 0.1, 1.0, 0.8)))),
            ({ focalPoint = Patch.Clear, crop = Patch.Keep },                             (None, Some((0.0, 0.1, 1.0, 0.8)))),
            ({ focalPoint = Patch.Keep, crop = Patch.Clear },                             (Some((0.5, 0.3)), None)),
            ({ focalPoint = Patch.Set(point(0.1, 0.9)), crop = Patch.Keep },              (Some((0.1, 0.9)), Some((0.0, 0.1, 1.0, 0.8)))),
            ({ focalPoint = Patch.Keep, crop = Patch.Set(rect(0.2, 0.2, 0.5, 0.5)) },     (Some((0.5, 0.3)), Some((0.2, 0.2, 0.5, 0.5)))),
            ({ focalPoint = Patch.Clear, crop = Patch.Clear },                            (None, None))
        };
        Assert.assertEq(expected = table |> List.map(snd),
            table |> List.map(fst) |> List.map(patch -> AssetPresentationRules.apply(patch, current) |> flatten))

    /// 何も無い所に Set すると付き、Clear は何も無いまま。
    @Test
    def testApplyFromEmpty(): Unit \ Assert =
        let table = List#{
            ({ focalPoint = Patch.Set(point(0.5, 0.5)), crop = Patch.Clear }, (Some((0.5, 0.5)), None)),
            ({ focalPoint = Patch.Clear, crop = Patch.Clear },                (None, None))
        };
        Assert.assertEq(expected = table |> List.map(snd),
            table |> List.map(fst) |> List.map(patch -> AssetPresentationRules.apply(patch, AssetPresentation.empty()) |> flatten))

}
