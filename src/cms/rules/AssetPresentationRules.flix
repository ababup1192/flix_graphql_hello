///
/// asset の見せ方（注目点と切り抜き枠）の規則。値の範囲と、直し方（Patch）の当て方。純粋。
///
/// WhyNot: 画像の寸法（px）と突き合わせない。値は割合なので寸法が無い（confirm で渡されなかった）asset にも付けられ、
/// 配信側が表示サイズに合わせて計算する。
///
mod AssetPresentationRules {

    ///
    /// 範囲の検査。0〜1 の割合で、crop は width / height が 0 より大きく、右端・下端が 1 を超えない。
    /// path は `focalPoint.x` / `crop.left` のように値の場所。
    ///
    pub def validate(presentation: AssetPresentation): List[Violation] =
        (presentation#focalPoint |> Option.map(validatePoint) |> Option.getWithDefault(Nil)) :::
        (presentation#crop |> Option.map(validateCrop) |> Option.getWithDefault(Nil))

    ///
    /// 直し方を今の値に当てる。項目ごとに Keep は今の値、Clear は無し、Set は新しい値。
    ///
    pub def apply(patch: AssetPresentationPatch, current: AssetPresentation): AssetPresentation =
        { focalPoint = applyOne(patch#focalPoint, current#focalPoint), crop = applyOne(patch#crop, current#crop) }

    def applyOne(patch: Patch[a], current: Option[a]): Option[a] = match patch {
        case Patch.Keep       => current
        case Patch.Clear      => None
        case Patch.Set(value) => Some(value)
    }

    def validatePoint(point: FocalPoint): List[Violation] =
        ratio("focalPoint.x", point#x) ::: ratio("focalPoint.y", point#y)

    /// 1 つの値に付く違反は 1 つ。位置が範囲外なら大きさとの和は見ない（同じ原因を 2 度言わない）。
    def validateCrop(crop: CropRect): List[Violation] =
        ratio("crop.left", crop#left) ::: ratio("crop.top", crop#top) :::
        extent("crop.width", crop#width, crop#left) ::: extent("crop.height", crop#height, crop#top)

    /// 0〜1 の割合か。NaN は比較が偽になるので違反。
    def ratio(path: String, value: Float64): List[Violation] =
        if (value >= 0.0 and value <= 1.0) Nil else Violation.Violation(path, "0 から 1 の割合で指定してください") :: Nil

    /// 枠の大きさ。0 より大きく 1 以下で、始点と足して 1 を超えない。
    def extent(path: String, size: Float64, start: Float64): List[Violation] =
        if (not (size > 0.0 and size <= 1.0)) Violation.Violation(path, "0 より大きく 1 以下の割合で指定してください") :: Nil
        else if (start >= 0.0 and start <= 1.0 and start + size > 1.0) Violation.Violation(path, "枠が画像の外に出ています（始点と足して 1 以下にしてください）") :: Nil
        else Nil

}
