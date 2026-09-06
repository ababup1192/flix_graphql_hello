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
    /// 絞り込みを述語にする。
    ///
    pub def pred(conditions: Where): Pred[EntryContentsTable.EntryContentsTable] =
        Fragment.all(List.map(condition, conditions))

    ///
    /// 並び順にする。空なら更新が新しい順。末尾に id を足して順序を安定させる。
    /// フィールドの kind で式が変わるので fields を受ける。
    ///
    pub def order(fields: List[FieldDef], orderBy: OrderBy): Order[EntryContentsTable.EntryContentsTable] =
        let terms = match orderBy {
            case Nil  => (SortKey.ByUpdatedAt, Direction.Desc) :: Nil
            case keys => keys
        };
        List.foldLeft((acc, term) -> Order.Then(acc, orderTerm(fields, term)), orderTerm(fields, List.head(terms) |> Option.getWithDefault((SortKey.ByUpdatedAt, Direction.Desc))), List.drop(1, terms))
            |> (built -> Order.Then(built, Order.Asc("e.id")))

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
                case _                       => textExpr(apiId)
            }
        };
        match direction {
            case Direction.Asc  => Order.Asc(expression)
            case Direction.Desc => Order.Desc(expression)
        }

    def condition(given: Condition): Pred[EntryContentsTable.EntryContentsTable] = match given {
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
        case Condition.IsNull(apiId, true)       => Pred.IsNull(textExpr(apiId))
        case Condition.IsNull(apiId, false)      => Pred.IsNotNull(textExpr(apiId))
        case Condition.AnyOf(groups)             => Fragment.any(List.map(pred, groups))
    }

    ///
    /// 値を文字列として取り出す式。無いキーと JSON の null は SQL の NULL になる。
    ///
    def textExpr(apiId: ApiId): String = "(c.data->>'${ApiId.text(apiId)}')"

    def numberExpr(apiId: ApiId): String = "((c.data->>'${ApiId.text(apiId)}')::numeric)"

    def boolExpr(apiId: ApiId): String = "((c.data->>'${ApiId.text(apiId)}')::boolean)"

}
