///
/// 生成されたクエリの行に共通の読み方。RETURNING id、count、max+1 の行と、規則外の値の扱い。
///
mod Rows {

    ///
    /// RETURNING id の行。無いのは DB かドライバの異常なので DbErr にする。
    ///
    pub def expectId(row: Option[{ id = Int64 | r }]): Int64 \ DbErr = match row {
        case Some(found) => found#id
        case None        => DbErr.other("INSERT ... RETURNING が行を返しませんでした")
    }

    ///
    /// count(*) の行。無ければ 0。
    ///
    pub def total(row: Option[{ total = Option[Int64] | r }]): Int64 =
        row |> Option.flatMap(found -> found#total) |> Option.getWithDefault(0i64)

    ///
    /// 次の position の行。無ければ 0。
    ///
    pub def nextPosition(row: Option[{ next = Option[Int32] | r }]): Int32 =
        row |> Option.flatMap(found -> found#next) |> Option.getWithDefault(0)

    ///
    /// 行の値が読めない。DB に規則外の値が入っている事（DDL と管理 API が守るので起きない）なので DbErr。
    ///
    pub def orRaise(column: String, text: String, value: Option[a]): a \ DbErr = match value {
        case Some(found) => found
        case None        => DbErr.other("${column} の値が読めません: ${text}")
    }

}
