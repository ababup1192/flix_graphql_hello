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
            AssetRules.validateUpload({ fileName = "///", mime = "video/quicktime", size = 21i64 * 1024i64 * 1024i64 })
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
        let cases = List#{ (AssetRules.maxSize("image/png"), Nil), (AssetRules.maxSize("image/png") + 1i64, List#{"size"}) };
        Assert.assertEq(expected = cases,
            cases |> List.map(match (size, _) -> (size, CmsTestKit.violationPaths(AssetRules.validateUpload({ fileName = "a.png", mime = "image/png", size = size })))))

    /// 上限は mime ごと。動画（mp4 / webm）は 200 MB、画像と PDF は 20 MB。
    @Test
    def testMaxSizeByMime(): Unit \ Assert =
        let cases = List#{ ("video/mp4", 200i64), ("video/webm", 200i64), ("image/png", 20i64), ("application/pdf", 20i64) };
        Assert.assertEq(expected = cases, cases |> List.map(match (mime, _) -> (mime, AssetRules.maxSize(mime) / 1024i64 / 1024i64)))

    /// 動画は 200 MB ちょうどまで置け、1 バイト超えると落ちる。画像に 200 MB は落ち、video/quicktime は mime で落ちる。
    @Test
    def testVideoUpload(): Unit \ Assert =
        let videoMax = 200i64 * 1024i64 * 1024i64;
        let cases = List#{
            ("a.mp4",  "video/mp4",       videoMax,        Nil),
            ("a.webm", "video/webm",      videoMax,        Nil),
            ("a.mp4",  "video/mp4",       videoMax + 1i64, List#{"size"}),
            ("a.png",  "image/png",       videoMax,        List#{"size"}),
            ("a.mov",  "video/quicktime", 1i64,            List#{"mime"})
        };
        Assert.assertEq(expected = cases |> List.map(match (_, _, _, paths) -> paths),
            cases |> List.map(match (fileName, mime, size, _) -> CmsTestKit.violationPaths(AssetRules.validateUpload({ fileName = fileName, mime = mime, size = size }))))

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
