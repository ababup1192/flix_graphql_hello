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

mod SortKey {

    ///
    /// GraphQL に出す名前。組み込みは id / publishedAt / updatedAt / createdAt、フィールドは apiId。
    /// コンテンツ API の `<Singular>OrderBy`（`title_ASC`）と管理 API の `orderBy: [{ field: "title" }]` と cursor の中身が同じ物を使う。
    ///
    pub def toText(key: SortKey): String = match key {
        case SortKey.ById           => "id"
        case SortKey.ByPublishedAt  => "publishedAt"
        case SortKey.ByUpdatedAt    => "updatedAt"
        case SortKey.ByCreatedAt    => "createdAt"
        case SortKey.ByField(apiId) => ApiId.text(apiId)
    }

    ///
    /// 名前から。組み込みの名前はフィールドの apiId に使えない（Naming の予約名）ので、先に組み込みを見る。規則外なら None。
    ///
    pub def fromText(text: String): Option[SortKey] = match text {
        case "id"          => Some(SortKey.ById)
        case "publishedAt" => Some(SortKey.ByPublishedAt)
        case "updatedAt"   => Some(SortKey.ByUpdatedAt)
        case "createdAt"   => Some(SortKey.ByCreatedAt)
        case other         => ApiId.parse(other) |> Option.map(SortKey.ByField)
    }

}

mod Direction {

    pub def toText(direction: Direction): String = match direction {
        case Direction.Asc  => "ASC"
        case Direction.Desc => "DESC"
    }

    pub def fromText(text: String): Option[Direction] = match text {
        case "ASC"  => Some(Direction.Asc)
        case "DESC" => Some(Direction.Desc)
        case _      => None
    }

}

///
/// 並び順。先頭が優先。空なら更新が新しい順。
///
pub type alias OrderBy = List[(SortKey, Direction)]

mod OrderBy {

    ///
    /// 実際に SQL に出す並び順。空なら更新が新しい順。末尾の id（順序を安定させる物）は含めない。
    /// cursor はこの並びと対で意味を持つ。
    ///
    pub def effective(orderBy: OrderBy): OrderBy =
        if (List.isEmpty(orderBy)) (SortKey.ByUpdatedAt, Direction.Desc) :: Nil else orderBy

    ///
    /// フィールドの値で並べるキーがあるか。あれば式を決めるのに型の定義（kind）が要る。
    ///
    pub def hasField(orderBy: OrderBy): Bool =
        List.exists(match (key, _) -> match key { case SortKey.ByField(_) => true case _ => false }, orderBy)

}

///
/// ページの始まり。offset（skip）か cursor（after）のどちらか 1 つ。
///
pub enum PageStart with Eq, ToString {
    /// 先頭から skip 件読み飛ばす。0 なら先頭
    case Offset(Int32)
    /// この cursor の位置の次から
    case After(Cursor)
}

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
    /// DATE の比較。値は timestamptz にして比べる
    case DateEq(ApiId, Timestamp.Timestamp)
    case DateGt(ApiId, Timestamp.Timestamp)
    case DateGte(ApiId, Timestamp.Timestamp)
    case DateLt(ApiId, Timestamp.Timestamp)
    case DateLte(ApiId, Timestamp.Timestamp)
    /// true なら値が無い物、false なら値がある物
    case IsNull(ApiId, Bool)
    /// 配列のフィールド（文字列・select・reference）がこの値を含む
    case ArrayContains(ApiId, String)
    /// どれかの組（それぞれは AND）に合う物。Where の OR
    case AnyOf(List[List[Condition]])
    /// 管理画面の検索。最上位のどれかの値に大文字小文字を区別せず含む。入れ子（オブジェクト・配列）は JSON の文字列として見るので、中のキー名にも当たる
    case AnyValueContains(String)
    /// 何にも合わない。規則外の id で絞り込んだ時に、条件を落として全件返さないための物
    case Never
    /// entry の状態（entries.stage）。管理 API の一覧で公開中の物だけを見る
    case StageEq(Stage)
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
/// - first: 最大件数
/// - start: ページの始まり（skip か after）
///
pub type alias ListQuery = { filter = Where, orderBy = OrderBy, first = Int32, start = PageStart }
