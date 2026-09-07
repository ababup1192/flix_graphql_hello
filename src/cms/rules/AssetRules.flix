///
/// asset の規則。何を置いてよいか（mime と大きさ）と、ファイル名の整え方。純粋。
///
mod AssetRules {

    ///
    /// 置いてよい mime。画像・PDF・動画（mp4 / webm）。
    ///
    /// WhyNot: image/svg+xml を入れないのは、SVG がスクリプトを含められ、配信 URL を直接開かれると実行されるため。
    /// 要る時はプロジェクトの設定で明示し、Content-Disposition: attachment で配る。
    /// WhyNot: video/quicktime（mov）を入れないのは、ブラウザで直に再生できる保証が無く、変換もしないため。
    ///
    pub def allowedMimes(): List[String] =
        List#{ "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "application/pdf" } ::: videoMimes()

    /// 動画の mime。上限が画像より大きい。
    pub def videoMimes(): List[String] = List#{ "video/mp4", "video/webm" }

    /// 1 ファイルの上限。動画は 200 MB、他は 20 MB。
    pub def maxSize(mime: String): Int64 =
        (if (List.memberOf(mime, videoMimes())) 200i64 else 20i64) * 1024i64 * 1024i64

    /// ファイル名の上限（文字数）。key に入るので長すぎる物は切る。
    pub def maxFileNameLength(): Int32 = 200

    ///
    /// 申し込みの検査。mime が許可リストに無い、size が 0 以下か上限超え、ファイル名が空、を Violation にする。
    ///
    pub def validateUpload(request: UploadRequest): List[Violation] =
        List.filterMap(identity, List#{
            if (List.memberOf(request#mime, allowedMimes())) None
            else Some(Violation.Violation("mime", "'${request#mime}' は置けません（${List.join(", ", allowedMimes())}）")),
            if (request#size <= 0i64) Some(Violation.Violation("size", "1 バイト以上にしてください"))
            else if (request#size > maxSize(request#mime)) Some(Violation.Violation("size", "${maxSize(request#mime) / 1024i64 / 1024i64} MB までです"))
            else None,
            if (String.isEmpty(safeFileName(request#fileName))) Some(Violation.Violation("fileName", "ファイル名が空です")) else None
        })

    ///
    /// ストレージの key に入れるファイル名。パスの区切りより後ろだけを取り、空白・制御文字・URL で困る文字を `-` にし、長さを切る。
    ///
    pub def safeFileName(fileName: String): String =
        fileName
            |> String.splitOn(substr = "/")
            |> List.last
            |> Option.getWithDefault("")
            |> String.splitOn(substr = "\\")
            |> List.last
            |> Option.getWithDefault("")
            |> String.replace(src = " ", dst = "-")
            |> String.toList
            |> List.filter(isSafeChar)
            |> List.map(Char.toString)
            |> List.join("")
            |> String.takeLeft(maxFileNameLength())

    /// key に残してよい文字。英数字と `. - _` と、ASCII 以外（日本語のファイル名は残す）。
    def isSafeChar(c: Char): Bool =
        Char.isLetterOrDigit(c) or c == '.' or c == '-' or c == '_' or Char.toBmpCodePoint(c) > 127

}
