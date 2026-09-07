///
/// DATE フィールドの値の読み方。全部純粋。
/// 値は ISO 8601 の文字列（offset 付き。"2026-09-08T09:00:00Z" / "2026-09-08T18:00:00+09:00"）か、日付だけ（"2026-09-08"）。
/// 日付だけの物は UTC の 0 時として読む。書く時は normalize で日時の形に揃える（コンテンツ API の絞り込みと並び替えが timestamptz で比べられるように）。
///
mod DateValues {

    ///
    /// 値を時刻に読む。ISO 8601 でも日付だけでもなければ None。
    ///
    pub def parse(text: String): Option[Timestamp.Timestamp] =
        if (isBareDate(text)) Timestamp.fromIso8601(text + "T00:00:00Z") else Timestamp.fromIso8601(text)

    ///
    /// 書く時の形。日付だけなら UTC の 0 時の日時にし、日時ならそのまま。読めない値はそのまま返す（検証が違反として言う）。
    ///
    /// WhyNot: 日時を UTC に書き直さないのは、書いた人の offset（"+09:00"）を残すため。比べる時は DB が timestamptz にして揃える。
    ///
    pub def normalize(text: String): String =
        if (isBareDate(text)) text + "T00:00:00Z" else text

    ///
    /// "2026-09-08" の形か。
    ///
    pub def isBareDate(text: String): Bool = String.isMatch(regex = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", text)

}
