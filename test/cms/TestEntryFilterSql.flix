///
/// EntryFilterSql: 絞り込みと並び順が JSONB の式とプレースホルダに落ちる。純粋。
///
///
/// blogs 型のフィールド。title(text) / views(number) / flag(boolean) / tags(text, many) / publishOn(date)
///
mod TestEntryFilterSql {

    use SqlValue.SqlValue

    def filterFields(): List[FieldDef] =
        CmsTestKit.fieldDef("title", FieldKind.Text) ::
        CmsTestKit.fieldDef("views", FieldKind.Number) ::
        CmsTestKit.fieldDef("flag", FieldKind.Boolean) ::
        { many = true | CmsTestKit.fieldDef("tags", FieldKind.Text) } ::
        CmsTestKit.fieldDef("publishOn", FieldKind.Date) :: Nil

    /// 条件は式とプレースホルダになる。値は SQL の文面に出ない。数値と真偽値は jsonb_typeof で見てからキャストする（型の違う古い値で落ちない）。
    @Test
    def testEntryFilterSqlPred(): Unit \ Assert =
        let conditions = Condition.TextEq(CmsTestKit.apiId("title"), "Flix") :: Condition.NumberGt(CmsTestKit.apiId("views"), 10.0) :: Condition.BoolEq(CmsTestKit.apiId("flag"), true) :: Nil;
        Assert.assertEq(expected = ("((((c.data->>'title') = $1) AND (((CASE WHEN jsonb_typeof(c.data->'views') = 'number' THEN c.data->>'views' END)::numeric) > $2)) AND (((CASE WHEN jsonb_typeof(c.data->'flag') = 'boolean' THEN c.data->>'flag' END)::boolean) = $3))", List#{SqlValue.Str("Flix"), SqlValue.Float64(10.0), SqlValue.Bool(true)}),
            run { Fragment.renderPred(EntryFilterSql.pred(conditions), 1) } with RawSql.runWithAllow)

    /// contains は小文字にして LIKE、% はエスケープされる。isNull は ->> の NULL を見る。OR は括弧で括る。
    @Test
    def testEntryFilterSqlContainsAndOr(): Unit \ Assert =
        let conditions = Condition.AnyOf((Condition.TextContains(CmsTestKit.apiId("title"), "100%") :: Nil) :: (Condition.IsNull(CmsTestKit.apiId("views"), true) :: Nil) :: Nil) :: Nil;
        Assert.assertEq(expected = ("((lower((c.data->>'title')) LIKE $1) OR ((c.data->>'views') IS NULL))", List#{SqlValue.Str("%100\\%%")}),
            run { Fragment.renderPred(EntryFilterSql.pred(conditions), 1) } with RawSql.runWithAllow)

    /// id_in は IN、空なら FALSE。Never も FALSE（規則外の id で全件返さない）。
    @Test
    def testEntryFilterSqlIdIn(): Unit \ Assert =
        let ids = CmsTestKit.entryIds(List#{"a", "b"});
        Assert.assertEq(expected = ("(e.id IN ($1, $2))", "FALSE", "FALSE"),
            run {
                (fst(Fragment.renderPred(EntryFilterSql.pred(Condition.IdIn(ids) :: Nil), 1)),
                 fst(Fragment.renderPred(EntryFilterSql.pred(Condition.IdIn(Nil) :: Nil), 1)),
                 fst(Fragment.renderPred(EntryFilterSql.pred(Condition.Never :: Nil), 1)))
            } with RawSql.runWithAllow)

    /// 並び順は kind で式が変わり、末尾に e.id を足す。空なら更新が新しい順。
    @Test
    def testEntryFilterSqlOrder(): Unit \ Assert =
        Assert.assertEq(expected = ("ORDER BY ((CASE WHEN jsonb_typeof(c.data->'views') = 'number' THEN c.data->>'views' END)::numeric) DESC, (c.data->>'title') ASC, e.id ASC", "ORDER BY e.updated_at DESC, e.id ASC"),
            (Fragment.renderOrder(EntryFilterSql.order(filterFields(), (SortKey.ByField(CmsTestKit.apiId("views")), Direction.Desc) :: (SortKey.ByField(CmsTestKit.apiId("title")), Direction.Asc) :: Nil)),
             Fragment.renderOrder(EntryFilterSql.order(filterFields(), Nil))))

    /// 配列の「含む」は jsonb_array_elements_text の副問い合わせで、値はプレースホルダ。配列でない値は落とさず偽にする。RawSql が付く。
    @Test
    def testEntryFilterSqlArrayContains(): Unit \ Assert =
        let rendered = run {
            Fragment.renderPred(EntryFilterSql.pred(Condition.ArrayContains(CmsTestKit.apiId("tags"), "t1") :: Nil), 1)
        } with RawSql.runWithAllow;
        Assert.assertEq(expected = ("((jsonb_typeof(c.data->'tags') = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(c.data->'tags') AS elem WHERE elem = $1)))", List#{SqlValue.Str("t1")}), rendered)

    /// DATE は日時の形（YYYY-MM-DDT…）の値だけ timestamptz にして比べ、値は Timestamp のプレースホルダ。並び替えも同じ式。
    @Test
    def testEntryFilterSqlDate(): Unit \ Assert =
        let at = Timestamp.at("2026-09-08T00:00:00Z");
        let expr = "((CASE WHEN (c.data->>'publishOn') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN c.data->>'publishOn' END)::timestamptz)";
        Assert.assertEq(
            expected = (("(${expr} >= $1)", List#{SqlValue.Timestamp(Timestamp.toEpochMicros(at))}), "ORDER BY ${expr} DESC, e.id ASC"),
            (run { Fragment.renderPred(EntryFilterSql.pred(Condition.DateGte(CmsTestKit.apiId("publishOn"), at) :: Nil), 1) } with RawSql.runWithAllow,
             Fragment.renderOrder(EntryFilterSql.order(filterFields(), (SortKey.ByField(CmsTestKit.apiId("publishOn")), Direction.Desc) :: Nil))))

    /// 条件 1 つを SQL の断片と引数にする。
    def render(condition: Condition): (String, List[SqlValue]) =
        run { Fragment.renderPred(EntryFilterSql.pred(condition :: Nil), 1) } with RawSql.runWithAllow

    def textExpr(): String = "(c.data->>'title')"

    def numberExpr(): String = "((CASE WHEN jsonb_typeof(c.data->'views') = 'number' THEN c.data->>'views' END)::numeric)"

    def boolExpr(): String = "((CASE WHEN jsonb_typeof(c.data->'flag') = 'boolean' THEN c.data->>'flag' END)::boolean)"

    def dateExpr(): String = "((CASE WHEN (c.data->>'publishOn') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN c.data->>'publishOn' END)::timestamptz)"

    /// Condition の全 case が SQL の断片と引数になる。値は全部プレースホルダで、文面に入るのは apiId だけ。
    /// contains / startsWith は小文字にして LIKE の記号をエスケープ、AnyValueContains は ILIKE で大文字小文字を残す。
    @Test
    def testEntryFilterSqlAllConditions(): Unit \ Assert =
        let title = CmsTestKit.apiId("title");
        let views = CmsTestKit.apiId("views");
        let flag = CmsTestKit.apiId("flag");
        let publishOn = CmsTestKit.apiId("publishOn");
        let tags = CmsTestKit.apiId("tags");
        let at = Timestamp.at("2026-09-08T00:00:00Z");
        let atValue = SqlValue.Timestamp(Timestamp.toEpochMicros(at));
        let cases = List#{
            (Condition.IdEq(CmsTestKit.entryId("a")),                          ("(e.id = $1)", List#{SqlValue.Str("a")})),
            (Condition.IdIn(CmsTestKit.entryIds(List#{"a", "b"})),             ("(e.id IN ($1, $2))", List#{SqlValue.Str("a"), SqlValue.Str("b")})),
            (Condition.TextEq(title, "Flix"),                                  ("(${textExpr()} = $1)", List#{SqlValue.Str("Flix")})),
            (Condition.TextIn(title, List#{"a", "b"}),                         ("(${textExpr()} IN ($1, $2))", List#{SqlValue.Str("a"), SqlValue.Str("b")})),
            (Condition.TextContains(title, "A_b"),                             ("(lower(${textExpr()}) LIKE $1)", List#{SqlValue.Str("%a\\_b%")})),
            (Condition.TextStartsWith(title, "A%"),                            ("(lower(${textExpr()}) LIKE $1)", List#{SqlValue.Str("a\\%%")})),
            (Condition.NumberEq(views, 1.0),                                   ("(${numberExpr()} = $1)", List#{SqlValue.Float64(1.0)})),
            (Condition.NumberGt(views, 1.0),                                   ("(${numberExpr()} > $1)", List#{SqlValue.Float64(1.0)})),
            (Condition.NumberGte(views, 1.0),                                  ("(${numberExpr()} >= $1)", List#{SqlValue.Float64(1.0)})),
            (Condition.NumberLt(views, 1.0),                                   ("(${numberExpr()} < $1)", List#{SqlValue.Float64(1.0)})),
            (Condition.NumberLte(views, 1.0),                                  ("(${numberExpr()} <= $1)", List#{SqlValue.Float64(1.0)})),
            (Condition.BoolEq(flag, true),                                     ("(${boolExpr()} = $1)", List#{SqlValue.Bool(true)})),
            (Condition.DateEq(publishOn, at),                                  ("(${dateExpr()} = $1)", List#{atValue})),
            (Condition.DateGt(publishOn, at),                                  ("(${dateExpr()} > $1)", List#{atValue})),
            (Condition.DateGte(publishOn, at),                                 ("(${dateExpr()} >= $1)", List#{atValue})),
            (Condition.DateLt(publishOn, at),                                  ("(${dateExpr()} < $1)", List#{atValue})),
            (Condition.DateLte(publishOn, at),                                 ("(${dateExpr()} <= $1)", List#{atValue})),
            (Condition.IsNull(title, true),                                    ("(${textExpr()} IS NULL)", Nil)),
            (Condition.IsNull(title, false),                                   ("(${textExpr()} IS NOT NULL)", Nil)),
            (Condition.ArrayContains(tags, "t1"),                              ("((jsonb_typeof(c.data->'tags') = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(c.data->'tags') AS elem WHERE elem = $1)))", List#{SqlValue.Str("t1")})),
            (Condition.AnyOf((Condition.TextEq(title, "x") :: Nil) :: (Condition.BoolEq(flag, true) :: Nil) :: Nil),
                                                                               ("((${textExpr()} = $1) OR (${boolExpr()} = $2))", List#{SqlValue.Str("x"), SqlValue.Bool(true)})),
            (Condition.AnyValueContains("100%"),                               ("(EXISTS (SELECT 1 FROM jsonb_each_text(c.data) AS kv WHERE kv.value ILIKE $1))", List#{SqlValue.Str("%100\\%%")})),
            (Condition.Never,                                                  ("FALSE", Nil))
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (condition, _) -> (condition, render(condition))))

    /// 並び替えの全 key × 昇降。フィールドは kind で式が変わり（型に無い apiId は文字列）、組み込みの key は entries の列。末尾に e.id ASC が付く。
    @Test
    def testEntryFilterSqlOrderKeys(): Unit \ Assert =
        let cases = List#{
            ((SortKey.ByField(CmsTestKit.apiId("title")), Direction.Asc),      "ORDER BY ${textExpr()} ASC, e.id ASC"),
            ((SortKey.ByField(CmsTestKit.apiId("title")), Direction.Desc),     "ORDER BY ${textExpr()} DESC, e.id ASC"),
            ((SortKey.ByField(CmsTestKit.apiId("views")), Direction.Asc),      "ORDER BY ${numberExpr()} ASC, e.id ASC"),
            ((SortKey.ByField(CmsTestKit.apiId("flag")), Direction.Desc),      "ORDER BY ${boolExpr()} DESC, e.id ASC"),
            ((SortKey.ByField(CmsTestKit.apiId("publishOn")), Direction.Asc),  "ORDER BY ${dateExpr()} ASC, e.id ASC"),
            ((SortKey.ByField(CmsTestKit.apiId("unknown")), Direction.Asc),    "ORDER BY (c.data->>'unknown') ASC, e.id ASC"),
            ((SortKey.ByPublishedAt, Direction.Desc),                          "ORDER BY e.published_at DESC, e.id ASC"),
            ((SortKey.ByPublishedAt, Direction.Asc),                           "ORDER BY e.published_at ASC, e.id ASC"),
            ((SortKey.ByCreatedAt, Direction.Desc),                            "ORDER BY e.created_at DESC, e.id ASC"),
            ((SortKey.ByCreatedAt, Direction.Asc),                             "ORDER BY e.created_at ASC, e.id ASC"),
            ((SortKey.ByUpdatedAt, Direction.Asc),                             "ORDER BY e.updated_at ASC, e.id ASC"),
            ((SortKey.ById, Direction.Desc),                                   "ORDER BY e.id DESC, e.id ASC")
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (term, _) -> (term, Fragment.renderOrder(EntryFilterSql.order(filterFields(), term :: Nil)))))

    /// OR の空のグループは「どれにも合わない」。OR: [{}] で絞り込みが全件に広がらず、OR: [] も FALSE。
    @Test
    def testEntryFilterSqlEmptyOr(): Unit \ Assert =
        let title = Condition.TextEq(CmsTestKit.apiId("title"), "x") :: Nil;
        Assert.assertEq(expected = ("FALSE", "(FALSE OR ((c.data->>'title') = $1))"),
            run {
                (fst(Fragment.renderPred(EntryFilterSql.pred(Condition.AnyOf(Nil) :: Nil), 1)),
                 fst(Fragment.renderPred(EntryFilterSql.pred(Condition.AnyOf(Nil :: title :: Nil) :: Nil), 1)))
            } with RawSql.runWithAllow)
}
