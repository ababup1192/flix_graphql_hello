///
/// 一覧の検索語の扱い。純粋。
///
mod EntrySearch {

    ///
    /// LIKE / ILIKE のパターンに埋めるためにエスケープする。`\` `%` `_` をそのままの文字として当てる。
    /// PostgreSQL の既定の ESCAPE は `\`。
    ///
    pub def escapeLike(text: String): String =
        text
            |> String.replace(src = "\\", dst = "\\\\")
            |> String.replace(src = "%", dst = "\\%")
            |> String.replace(src = "_", dst = "\\_")

}
