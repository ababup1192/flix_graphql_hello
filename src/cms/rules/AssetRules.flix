///
/// asset の規則。何を置いてよいか（mime と大きさ）と、ファイル名の整え方。純粋。
///
mod AssetRules {

    ///
    /// 置いてよい mime。画像と PDF だけ。動画は寸法の扱いを決めていないので入れない。
    ///
    pub def allowedMimes(): List[String] =
        List#{ "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/svg+xml", "application/pdf" }

    /// 1 ファイルの上限。20 MB。
    pub def maxSize(): Int64 = 20i64 * 1024i64 * 1024i64

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
            else if (request#size > maxSize()) Some(Violation.Violation("size", "${maxSize() / 1024i64 / 1024i64} MB までです"))
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
