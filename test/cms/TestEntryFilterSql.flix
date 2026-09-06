///
/// EntryFilterSql: 絞り込みと並び順が JSONB の式とプレースホルダに落ちる。純粋。
///
///
/// blogs 型のフィールド。title(text) / views(number) / flag(boolean) / tags(text, many)
///
mod TestEntryFilterSql {

    use SqlValue.SqlValue

    def filterFields(): List[FieldDef] =
        CmsTestKit.fieldDef("title", FieldKind.Text) ::
        CmsTestKit.fieldDef("views", FieldKind.Number) ::
        CmsTestKit.fieldDef("flag", FieldKind.Boolean) ::
        { many = true | CmsTestKit.fieldDef("tags", FieldKind.Text) } :: Nil

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
