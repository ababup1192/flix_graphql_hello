///
/// DATE_ONLY フィールドの値の形。全部純粋。
///
/// 保存する値は日付だけの ISO 8601 ちょうど 1 通り（`2026-09-09`）。時刻付き・ゼロ詰めなしは断る。
///
/// WhyNot: DATE（瞬間）に畳まないのは、誕生日や発行日を UTC の 0 時の瞬間として持つと、
/// 読む側のタイムゾーンで前日に出るため（UTC-5 で `2026-09-09T00:00:00Z` は 9/8）。日付は日付のまま持つ。
/// WhyNot: DATE で見つかった「JSONB の `=` は文字列比較なので、同じ瞬間でも offset の書き方が違えば別の値になる」は
/// ここでは起きない。形が 1 通りしかなく、同じ日は必ず同じ文字列になるため、unique はそのまま正しい。
///
mod DateOnlyValues {

    ///
    /// 保存できる形か。`2026-09-09` の桁ちょうどで、暦としても読める事。
    ///
    pub def isCanonical(text: String): Bool =
        String.isMatch(regex = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", text)
            and Option.nonEmpty(Date.fromIso8601(text))

    ///
    /// 絞り込みの引数を日付に読む。日付だけの形か、日時（その瞬間の UTC での日付を取る）。読めなければ None。
    ///
    pub def parse(text: String): Option[Date.Date] =
        match Date.fromIso8601(text) {
            case Some(date) => Some(date)
            case None       => DateValues.parse(text) |> Option.map(at -> TimeZone.runWith(Zone.utc(), () -> Timestamp.toDate(at)))
        }

    ///
    /// 送るべき値。読める値なら日付だけの形。読めなければ None。
    ///
    pub def canonical(text: String): Option[String] =
        parse(text) |> Option.map(Date.toIso8601)

    ///
    /// 断る時の言い分。直せる値なら直した形を載せる（教えるだけで、直してはやらない）。
    ///
    pub def rejection(apiId: String, text: String): String =
        let received = match canonical(text) {
            case Some(fixed) => "受け取った値: ${text} → ${fixed}"
            case None        => "受け取った値: ${text}"
        };
        "'${apiId}' は日付（例: ${example()}）で送ってください。${received}"

    ///
    /// エラー文と SDL に出す見本。
    ///
    pub def example(): String = "2026-09-09"

}
