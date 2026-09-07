///
/// コンテンツ API の絞り込みと並び順を、entries / entry_contents への SQL の断片にする。
/// 値は全部プレースホルダ（$n）で渡し、SQL の文面に入るのは apiId（[a-z][A-Za-z0-9]* に限られる）だけ。
/// 生成された listEntriesByStage / countEntriesByStage の {filter} / {order} に渡す。
///
/// WhyNot: 断片 DSL の Col を使わず Pred / Order の case を直に組むのは、DSL の Col は列名を指す物で、
/// JSONB の式（c.data->>'title'）を置く口が無いため。case は式を文字列で持つので、パラメータ化はそのまま効く。
///
mod EntryFilterSql {

    use Fragment.Pred
    use Fragment.CompareOp
    use Fragment.Order
    use SqlValue.SqlValue

    ///
    /// 絞り込みを述語にする。配列の「含む」だけ生 SQL（jsonb_array_elements_text の副問い合わせ）なので RawSql が付く。
    ///
    pub def pred(conditions: Where): Pred[EntryContentsTable.EntryContentsTable] \ RawSql =
        Fragment.all(List.map(condition, conditions))

    ///
    /// 生 SQL を許した述語。生成されたクエリに渡す形。RawSql を許す判断はここ（SQL の文面を組む層）に置く。
    ///
    pub def predAllowingRaw(conditions: Where): Pred[EntryContentsTable.EntryContentsTable] =
        RawSql.runWithAllow(() -> pred(conditions))

    ///
    /// 並び順にする。空なら更新が新しい順。末尾に id を足して順序を安定させる。
    /// フィールドの kind で式が変わるので fields を受ける。
    ///
    pub def order(fields: List[FieldDef], orderBy: OrderBy): Order[EntryContentsTable.EntryContentsTable] =
        let requested = if (List.isEmpty(orderBy)) (SortKey.ByUpdatedAt, Direction.Desc) :: Nil else orderBy;
        let terms = requested ::: (SortKey.ById, Direction.Asc) :: Nil;
        List.foldLeft((acc, term) -> Order.Then(acc, orderTerm(fields, term)), Order.Unordered, terms)

    def orderTerm(fields: List[FieldDef], term: (SortKey, Direction)): Order[EntryContentsTable.EntryContentsTable] =
        let (key, direction) = term;
        let expression = match key {
            case SortKey.ById          => "e.id"
            case SortKey.ByPublishedAt => "e.published_at"
            case SortKey.ByUpdatedAt   => "e.updated_at"
            case SortKey.ByCreatedAt   => "e.created_at"
            case SortKey.ByField(apiId) => match List.find(field -> field#apiId == apiId, fields) |> Option.map(field -> field#kind) {
                case Some(FieldKind.Number)  => numberExpr(apiId)
                case Some(FieldKind.Boolean) => boolExpr(apiId)
                case Some(FieldKind.Date)    => dateExpr(apiId)
                case _                       => textExpr(apiId)
            }
        };
        match direction {
            case Direction.Asc  => Order.Asc(expression)
            case Direction.Desc => Order.Desc(expression)
        }

    def condition(given: Condition): Pred[EntryContentsTable.EntryContentsTable] \ RawSql = match given {
        case Condition.IdEq(id)                  => Pred.Compare("e.id", CompareOp.Eq, SqlValue.Str(EntryId.text(id)))
        case Condition.IdIn(ids)                 => Pred.In("e.id", ids |> List.map(id -> SqlValue.Str(EntryId.text(id))))
        case Condition.TextEq(apiId, text)       => Pred.Compare(textExpr(apiId), CompareOp.Eq, SqlValue.Str(text))
        case Condition.TextIn(apiId, texts)      => Pred.In(textExpr(apiId), List.map(SqlValue.Str, texts))
        case Condition.TextContains(apiId, text) => Pred.Compare("lower(${textExpr(apiId)})", CompareOp.Like, SqlValue.Str("%" + EntrySearch.escapeLike(String.toLowerCase(text)) + "%"))
        case Condition.TextStartsWith(apiId, text) => Pred.Compare("lower(${textExpr(apiId)})", CompareOp.Like, SqlValue.Str(EntrySearch.escapeLike(String.toLowerCase(text)) + "%"))
        case Condition.NumberEq(apiId, x)        => Pred.Compare(numberExpr(apiId), CompareOp.Eq, SqlValue.Float64(x))
        case Condition.NumberGt(apiId, x)        => Pred.Compare(numberExpr(apiId), CompareOp.Gt, SqlValue.Float64(x))
        case Condition.NumberGte(apiId, x)       => Pred.Compare(numberExpr(apiId), CompareOp.Ge, SqlValue.Float64(x))
        case Condition.NumberLt(apiId, x)        => Pred.Compare(numberExpr(apiId), CompareOp.Lt, SqlValue.Float64(x))
        case Condition.NumberLte(apiId, x)       => Pred.Compare(numberExpr(apiId), CompareOp.Le, SqlValue.Float64(x))
        case Condition.BoolEq(apiId, b)          => Pred.Compare(boolExpr(apiId), CompareOp.Eq, SqlValue.Bool(b))
        case Condition.DateEq(apiId, at)         => Pred.Compare(dateExpr(apiId), CompareOp.Eq, timestampValue(at))
        case Condition.DateGt(apiId, at)         => Pred.Compare(dateExpr(apiId), CompareOp.Gt, timestampValue(at))
        case Condition.DateGte(apiId, at)        => Pred.Compare(dateExpr(apiId), CompareOp.Ge, timestampValue(at))
        case Condition.DateLt(apiId, at)         => Pred.Compare(dateExpr(apiId), CompareOp.Lt, timestampValue(at))
        case Condition.DateLte(apiId, at)        => Pred.Compare(dateExpr(apiId), CompareOp.Le, timestampValue(at))
        case Condition.IsNull(apiId, true)       => Pred.IsNull(textExpr(apiId))
        case Condition.IsNull(apiId, false)      => Pred.IsNotNull(textExpr(apiId))
        case Condition.ArrayContains(apiId, text) =>
            // WhyNot: jsonb_typeof の前置きを省かないのは、値が配列でないと jsonb_array_elements_text が PG の例外で落ちるため
            Fragment.rawPredWith("(jsonb_typeof(c.data->'${ApiId.text(apiId)}') = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(c.data->'${ApiId.text(apiId)}') AS elem WHERE elem = ?))", SqlValue.Str(text) :: Nil)
        // WhyNot: 空のグループを pred(Nil)（TRUE）のまま OR に入れないのは、OR: [{}] で絞り込みが全件に広がるため。空は「どれにも合わない」
        case Condition.AnyOf(groups)             => if (List.isEmpty(groups)) never() else Fragment.any(groups |> List.map(group -> if (List.isEmpty(group)) never() else pred(group)))
        case Condition.AnyValueContains(text)    =>
            Fragment.rawPredWith("EXISTS (SELECT 1 FROM jsonb_each_text(c.data) AS kv WHERE kv.value ILIKE ?)", SqlValue.Str("%" + EntrySearch.escapeLike(text) + "%") :: Nil)
        // WhyNot: Fragment.any(Nil) は「絞り込み無し（TRUE）」なので使えない。空の IN が FALSE になるのを借りる
        case Condition.Never                     => never()
    }

    def never(): Pred[EntryContentsTable.EntryContentsTable] = Pred.In("e.id", Nil)

    ///
    /// 値を文字列として取り出す式。無いキーと JSON の null は SQL の NULL になる。
    ///
    def textExpr(apiId: ApiId): String = "(c.data->>'${ApiId.text(apiId)}')"

    ///
    /// 数値として取り出す式。数値でない値は NULL。
    ///
    /// WhyNot: 素の ::numeric にしないのは、フィールドの kind を変えて作り直した後に古い文字列が残っていると
    /// キャストで PG の例外になり、一覧のクエリ全体が落ちるため。jsonb_typeof で見てから落とす
    ///
    def numberExpr(apiId: ApiId): String = "(${typedExpr(apiId, "number")}::numeric)"

    def boolExpr(apiId: ApiId): String = "(${typedExpr(apiId, "boolean")}::boolean)"

    ///
    /// 日時として取り出す式。日時の形（YYYY-MM-DDT…。書く時に揃える）でない値は NULL。
    ///
    /// WhyNot: 文字列なら何でも ::timestamptz にしないのは、同じ apiId で作り直した DATE に古い文字列が残っていると
    /// キャストで PG の例外になり、一覧のクエリ全体が落ちるため。形を見てから落とす
    ///
    def dateExpr(apiId: ApiId): String =
        "((CASE WHEN (c.data->>'${ApiId.text(apiId)}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN c.data->>'${ApiId.text(apiId)}' END)::timestamptz)"

    def timestampValue(at: Timestamp.Timestamp): SqlValue = SqlValue.Timestamp(Timestamp.toEpochMicros(at))

    def typedExpr(apiId: ApiId, jsonType: String): String =
        "(CASE WHEN jsonb_typeof(c.data->'${ApiId.text(apiId)}') = '${jsonType}' THEN c.data->>'${ApiId.text(apiId)}' END)"

}
