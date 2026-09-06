///
/// 並び順の向き。
///
pub enum Direction with Eq, Order, ToString {
    case Asc
    case Desc
}

///
/// 並び替えのキー。
///
pub enum SortKey with Eq, Order, ToString {
    /// entry の id
    case ById
    /// 公開した時刻
    case ByPublishedAt
    /// 更新した時刻
    case ByUpdatedAt
    /// 作成した時刻
    case ByCreatedAt
    /// フィールドの値（配列でない物だけ）
    case ByField(ApiId)
}

///
/// 並び順。先頭が優先。空なら更新が新しい順。
///
pub type alias OrderBy = List[(SortKey, Direction)]

///
/// 絞り込みの 1 条件。コンテンツ API の <Singular>Where の 1 項目に対応する。
///
pub enum Condition with Eq, Order, ToString {
    case IdEq(EntryId)
    case IdIn(List[EntryId])
    case TextEq(ApiId, String)
    case TextIn(ApiId, List[String])
    /// 大文字小文字を区別しない部分一致
    case TextContains(ApiId, String)
    /// 大文字小文字を区別しない前方一致
    case TextStartsWith(ApiId, String)
    case NumberEq(ApiId, Float64)
    case NumberGt(ApiId, Float64)
    case NumberGte(ApiId, Float64)
    case NumberLt(ApiId, Float64)
    case NumberLte(ApiId, Float64)
    case BoolEq(ApiId, Bool)
    /// true なら値が無い物、false なら値がある物
    case IsNull(ApiId, Bool)
    /// どれかの組（それぞれは AND）に合う物。Where の OR
    case AnyOf(List[List[Condition]])
}

///
/// 絞り込み。全部に合う物（AND）。
///
pub type alias Where = List[Condition]

///
/// コンテンツ API の一覧の条件。
///
/// - filter: 絞り込み
/// - orderBy: 並び順
/// - first / skip: ページ
///
pub type alias ListQuery = { filter = Where, orderBy = OrderBy, first = Int32, skip = Int32 }
