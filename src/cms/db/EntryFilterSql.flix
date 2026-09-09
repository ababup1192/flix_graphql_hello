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
    /// 絞り込みとページの始まりを合わせた述語。after なら cursor の位置の次からの条件（afterClause）を AND で足す。
    ///
    pub def predWithStart(fields: List[FieldDef], listQuery: ListQuery): Pred[EntryContentsTable.EntryContentsTable] =
        RawSql.runWithAllow(() -> match listQuery#start {
            case PageStart.Offset(_)     => pred(listQuery#filter)
            case PageStart.After(cursor) => Fragment.both(pred(listQuery#filter), afterClause(fields, cursor))
        })

    ///
    /// cursor の位置の次から、の条件。並び順のキーを先頭から見て「先頭のキーがその先か、同じなら次のキーで…、全部同じなら id がその先」。
    /// DESC は `<`、ASC は `>`。NULL は並びの末尾（order と同じ向き）なので、値のある行の後に NULL の行が続き、cursor が NULL なら NULL の行の id の先だけ。
    /// cursor の id がこのプロジェクトの entry でなければ（他のプロジェクトの cursor）1 件も返さない。
    ///
    /// WhyNot: 行の比較 `(a, b) < ($1, $2)` にしないのは、PG の行の比較は NULL の組で止まって unknown になり、NULL を末尾に置いた並びと合わないため。
    /// WhyNot: id の検査でゴミ箱の entry を除かないのは、ページの末尾の entry を消した直後に次のページが 0 件になり、全件を舐める途中で切れるため。
    ///
    pub def afterClause(fields: List[FieldDef], cursor: Cursor): Pred[EntryContentsTable.EntryContentsTable] \ RawSql =
        let terms = Cursor.keys(cursor) |> List.map(match (key, direction, value) -> (sortExpr(fields, key), isNullable(key), direction, value));
        Fragment.both(
            continuation(terms, Cursor.id(cursor)),
            Fragment.rawPredWith("EXISTS (SELECT 1 FROM entries AS x WHERE x.id = ? AND x.project_id = e.project_id AND x.type_id = e.type_id)", SqlValue.Str(Cursor.id(cursor)) :: Nil))

    /// 並び順のキーの列を先頭から見た「その先」。キーが尽きたら id（ASC）がその先。
    def continuation(terms: List[(String, Bool, Direction, CursorValue)], id: String): Pred[EntryContentsTable.EntryContentsTable] = match terms {
        case Nil => Pred.Compare("e.id", CompareOp.Gt, SqlValue.Str(id))
        case (expression, _, _, CursorValue.Null) :: rest => Pred.And(Pred.IsNull(expression), continuation(rest, id))
        case (expression, nullable, direction, value) :: rest =>
            let right = sqlValueOf(value);
            let strict = Pred.Compare(expression, match direction { case Direction.Desc => CompareOp.Lt case Direction.Asc => CompareOp.Gt }, right);
            let tie = Pred.And(Pred.Compare(expression, CompareOp.Eq, right), continuation(rest, id));
            if (nullable) Pred.Or(Pred.Or(strict, tie), Pred.IsNull(expression)) else Pred.Or(strict, tie)
    }

    def sqlValueOf(value: CursorValue): SqlValue = match value {
        case CursorValue.Null           => SqlValue.Null
        case CursorValue.Text(text)     => SqlValue.Str(text)
        case CursorValue.Number(x)      => SqlValue.Float64(x)
        case CursorValue.Bool(b)        => SqlValue.Bool(b)
        case CursorValue.Micros(micros) => SqlValue.Timestamp(micros)
        case CursorValue.Day(days)      => SqlValue.Date(days)
    }

    ///
    /// 並び順にする。空なら更新が新しい順。末尾に id を足して順序を安定させる。
    /// フィールドの kind で式が変わるので fields を受ける。NULL を取りうるキー（publishedAt とフィールド）は DESC でも末尾に置く。
    ///
    /// WhyNot: `DESC NULLS LAST` と書かないのは、断片 DSL の Order が式の後ろに向きを付けるだけで NULLS の指定を持たないため。`(式 IS NULL) ASC` を前に置いて同じ並びにする。
    ///
    pub def order(fields: List[FieldDef], orderBy: OrderBy): Order[EntryContentsTable.EntryContentsTable] =
        let terms = OrderBy.effective(orderBy) ::: (SortKey.ById, Direction.Asc) :: Nil;
        List.foldLeft((acc, term) -> Order.Then(acc, orderTerm(fields, term)), Order.Unordered, terms)

    def orderTerm(fields: List[FieldDef], term: (SortKey, Direction)): Order[EntryContentsTable.EntryContentsTable] =
        let (key, direction) = term;
        let expression = sortExpr(fields, key);
        match direction {
            case Direction.Asc                      => Order.Asc(expression)
            case Direction.Desc if isNullable(key)  => Order.Then(Order.Asc("(${expression} IS NULL)"), Order.Desc(expression))
            case Direction.Desc                     => Order.Desc(expression)
        }

    /// 並び順のキーの式。フィールドは kind で決まり、型に無い apiId は文字列。
    def sortExpr(fields: List[FieldDef], key: SortKey): String = match key {
        case SortKey.ById          => "e.id"
        case SortKey.ByPublishedAt => "e.published_at"
        case SortKey.ByUpdatedAt   => "e.updated_at"
        case SortKey.ByCreatedAt   => "e.created_at"
        case SortKey.ByField(apiId) => match List.find(field -> field#apiId == apiId, fields) |> Option.map(field -> field#kind) {
            case Some(FieldKind.Number)  => numberExpr(apiId)
            case Some(FieldKind.Boolean) => boolExpr(apiId)
            case Some(FieldKind.Date)     => dateExpr(apiId)
            case Some(FieldKind.DateOnly) => dateOnlyExpr(apiId)
            case _                       => textExpr(apiId)
        }
    }

    /// NULL を取りうるキーか。published_at は未公開なら NULL、JSONB のフィールドは無いキーと形の違う値が NULL。
    def isNullable(key: SortKey): Bool = match key {
        case SortKey.ByPublishedAt => true
        case SortKey.ByField(_)    => true
        case _                     => false
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
        case Condition.DateOnlyEq(apiId, on)     => Pred.Compare(dateOnlyExpr(apiId), CompareOp.Eq, dateValue(on))
        case Condition.DateOnlyCmp(apiId, op, on) => Pred.Compare(dateOnlyExpr(apiId), compareOp(op), dateValue(on))
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
        case Condition.StageEq(stage)            => Pred.Compare("e.stage", CompareOp.Eq, SqlValue.Str(EntryRows.stageToDb(stage)))
        // WhyNot: JSONB でなく entries の列で比べるのは、created_at / updated_at / published_at が列であり、索引が効くため
        case Condition.SystemDateCmp(key, op, at) => Pred.Compare(SystemDate.column(key), compareOp(op), timestampValue(at))
    }

    def compareOp(op: RangeOp): CompareOp = match op {
        case RangeOp.Gt  => CompareOp.Gt
        case RangeOp.Gte => CompareOp.Ge
        case RangeOp.Lt  => CompareOp.Lt
        case RangeOp.Lte => CompareOp.Le
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

    ///
    /// 日付として取り出す式。日付の形（YYYY-MM-DD ちょうど。書く時に断るので、それ以外は古い値だけ）でない値は NULL。
    ///
    /// WhyNot: 文字列なら何でも ::date にしないのは、同じ apiId で作り直した DATE_ONLY に古い値が残っていると
    /// キャストで PG の例外になり、一覧のクエリ全体が落ちるため。形を見てから落とす
    ///
    def dateOnlyExpr(apiId: ApiId): String =
        "((CASE WHEN (c.data->>'${ApiId.text(apiId)}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN c.data->>'${ApiId.text(apiId)}' END)::date)"

    def timestampValue(at: Timestamp.Timestamp): SqlValue = SqlValue.Timestamp(Timestamp.toEpochMicros(at))

    def dateValue(on: Date.Date): SqlValue = SqlValue.Date(Date.toEpochDay(on))

    def typedExpr(apiId: ApiId, jsonType: String): String =
        "(CASE WHEN jsonb_typeof(c.data->'${ApiId.text(apiId)}') = '${jsonType}' THEN c.data->>'${ApiId.text(apiId)}' END)"

}
