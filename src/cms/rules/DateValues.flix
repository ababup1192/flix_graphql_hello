///
/// DATE フィールドの値の形。全部純粋。
///
/// 保存する値は UTC の ISO 8601 ちょうど 1 通りだけ受ける（`2026-09-09T00:00:00Z`）。
/// offset 付き・ミリ秒付き・秒なし・0 詰めなし・区切りが空白の物は断る。
///
/// WhyNot: 受け取った値を直して保存しないのは、直し方の解釈（offset を UTC にするのか、日付だけを 0 時にするのか）が
/// 読む人ごとに割れるため。1 通りに絞れば「入れた値と出る値が同じ」になり、JSONB の `=` で見る一意も同じ瞬間を同じ値と見る。
/// WhyNot: 絞り込みの引数（parse）まで 1 通りに絞らないのは、引数は保存されず timestamptz にして比べるだけで、
/// 形が違っても並びも一意も狂わないため。
///
mod DateValues {

    ///
    /// 保存できる形か。`2026-09-09T00:00:00Z` の桁ちょうどで、暦としても読める事。
    ///
    pub def isCanonical(text: String): Bool =
        String.isMatch(regex = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", text)
            and Option.nonEmpty(Timestamp.fromIso8601(text))

    ///
    /// 絞り込みの引数を時刻に読む。ISO 8601 の日時（offset 付き）か日付だけ（`2026-09-09`。UTC の 0 時）。読めなければ None。
    ///
    pub def parse(text: String): Option[Timestamp.Timestamp] =
        if (isBareDate(text)) Timestamp.fromIso8601(text + "T00:00:00Z") else Timestamp.fromIso8601(text)

    ///
    /// 送るべき値。読める値なら秒に丸めた UTC の形。読めなければ None。
    ///
    pub def canonical(text: String): Option[String] =
        parse(text) |> Option.map(at -> Timestamp.toIso8601(truncateToSecond(at)))

    ///
    /// 断る時の言い分。直せる値なら直した形を載せる（教えるだけで、直してはやらない）。
    ///
    pub def rejection(apiId: String, text: String): String =
        let received = match canonical(text) {
            case Some(fixed) => "受け取った値: ${text} → ${fixed}"
            case None        => "受け取った値: ${text}"
        };
        "'${apiId}' は UTC の日時（例: ${example()}）で送ってください。${received}"

    ///
    /// エラー文と SDL に出す見本。
    ///
    pub def example(): String = "2026-09-09T00:00:00Z"

    ///
    /// `2026-09-09` の形か。
    ///
    pub def isBareDate(text: String): Bool = String.isMatch(regex = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", text)

    /// 秒未満を切り捨てる。1970 年より前でも下へ丸める。
    def truncateToSecond(at: Timestamp.Timestamp): Timestamp.Timestamp =
        let micros = Timestamp.toEpochMicros(at);
        let seconds = micros / 1000000i64;
        let floored = if (micros < 0i64 and Int64.remainder(micros, 1000000i64) != 0i64) seconds - 1i64 else seconds;
        Timestamp.fromEpochMicros(floored * 1000000i64)

}
