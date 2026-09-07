///
/// asset の規則。置いてよい物の検査と、ファイル名の整え方。
///
mod TestAssetRules {

    /// 許可リストの mime と上限内の size なら誤り無し。
    @Test
    def testValidUpload(): Unit \ Assert =
        Assert.assertEq(expected = Nil, AssetRules.validateUpload({ fileName = "photo.png", mime = "image/png", size = 1024i64 }))

    /// mime が許可リストに無い・size が上限超え・ファイル名が空、は path 付きの Violation。
    @Test
    def testInvalidUpload(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "mime", "size", "fileName" },
            AssetRules.validateUpload({ fileName = "///", mime = "video/mp4", size = 21i64 * 1024i64 * 1024i64 })
                |> List.map(violation -> { let Violation.Violation(path, _) = violation; path }))

    /// size 0 は置けない。
    @Test
    def testZeroSize(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "size" },
            AssetRules.validateUpload({ fileName = "a.pdf", mime = "application/pdf", size = 0i64 })
                |> List.map(violation -> { let Violation.Violation(path, _) = violation; path }))

    /// size は上限ちょうどまで置け、1 バイト超えると落ちる。
    @Test
    def testMaxSizeBoundary(): Unit \ Assert =
        let cases = List#{ (AssetRules.maxSize(), Nil), (AssetRules.maxSize() + 1i64, List#{"size"}) };
        Assert.assertEq(expected = cases,
            cases |> List.map(match (size, _) -> (size, CmsTestKit.violationPaths(AssetRules.validateUpload({ fileName = "a.png", mime = "image/png", size = size })))))

    /// mime は許可リストの綴りそのまま。SVG は置けず、大文字の綴りも通らない。
    @Test
    def testMimeIsExactMatch(): Unit \ Assert =
        let cases = List#{ ("image/png", Nil), ("image/svg+xml", List#{"mime"}), ("IMAGE/PNG", List#{"mime"}), ("image/png; charset=binary", List#{"mime"}) };
        Assert.assertEq(expected = cases,
            cases |> List.map(match (mime, _) -> (mime, CmsTestKit.violationPaths(AssetRules.validateUpload({ fileName = "a.png", mime = mime, size = 1i64 })))))

    /// パスの区切りより後ろだけ取り、空白は -、URL で困る文字は落とし、日本語は残す。
    @Test
    def testSafeFileName(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "photo-x.png", "写真.jpg", "ab.png", "a.pdf" },
            List#{ "../etc/photo x.png", "C:\\Users\\写真.jpg", "a?b#.png", "a.pdf" } |> List.map(AssetRules.safeFileName))

    /// 長すぎる名前は上限で切る。
    @Test
    def testSafeFileNameLength(): Unit \ Assert =
        Assert.assertEq(expected = 200, String.length(AssetRules.safeFileName(String.repeat(300, "a"))))

}
