use SqlValue.SqlValue

///
/// EntryFilterSql: 絞り込みと並び順が JSONB の式とプレースホルダに落ちる。純粋。
///

///
/// blogs 型のフィールド。title(text) / views(number) / flag(boolean) / tags(text, many)
///
def filterFields(): List[FieldDef] =
    let base = { id = FieldId.FieldId(0i64), typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("x"), name = "", kind = FieldKind.Text, many = false, required = false, unique = false, localized = false, target = None, config = FieldConfig.empty(), position = 0 };
    { apiId = CmsTestKit.apiId("title") | base } ::
    { apiId = CmsTestKit.apiId("views"), kind = FieldKind.Number | base } ::
    { apiId = CmsTestKit.apiId("flag"), kind = FieldKind.Boolean | base } ::
    { apiId = CmsTestKit.apiId("tags"), many = true | base } :: Nil

/// 条件は式とプレースホルダになる。値は SQL の文面に出ない。
@Test
def testEntryFilterSqlPred(): Unit \ Assert =
    let conditions = Condition.TextEq(CmsTestKit.apiId("title"), "Flix") :: Condition.NumberGt(CmsTestKit.apiId("views"), 10.0) :: Condition.BoolEq(CmsTestKit.apiId("flag"), true) :: Nil;
    Assert.assertEq(expected = ("((((c.data->>'title') = $1) AND (((c.data->>'views')::numeric) > $2)) AND (((c.data->>'flag')::boolean) = $3))", List#{SqlValue.Str("Flix"), SqlValue.Float64(10.0), SqlValue.Bool(true)}),
        run { Fragment.renderPred(EntryFilterSql.pred(conditions), 1) } with RawSql.runWithAllow)

/// contains は小文字にして LIKE、% はエスケープされる。isNull は ->> の NULL を見る。OR は括弧で括る。
@Test
def testEntryFilterSqlContainsAndOr(): Unit \ Assert =
    let conditions = Condition.AnyOf((Condition.TextContains(CmsTestKit.apiId("title"), "100%") :: Nil) :: (Condition.IsNull(CmsTestKit.apiId("views"), true) :: Nil) :: Nil) :: Nil;
    Assert.assertEq(expected = ("((lower((c.data->>'title')) LIKE $1) OR ((c.data->>'views') IS NULL))", List#{SqlValue.Str("%100\\%%")}),
        run { Fragment.renderPred(EntryFilterSql.pred(conditions), 1) } with RawSql.runWithAllow)

/// id_in は IN、空なら FALSE。
@Test
def testEntryFilterSqlIdIn(): Unit \ Assert =
    let ids = List#{"a", "b"} |> List.filterMap(EntryId.parse);
    Assert.assertEq(expected = ("(e.id IN ($1, $2))", "FALSE"),
        run {
            (fst(Fragment.renderPred(EntryFilterSql.pred(Condition.IdIn(ids) :: Nil), 1)),
             fst(Fragment.renderPred(EntryFilterSql.pred(Condition.IdIn(Nil) :: Nil), 1)))
        } with RawSql.runWithAllow)

/// 並び順は kind で式が変わり、末尾に e.id を足す。空なら更新が新しい順。
@Test
def testEntryFilterSqlOrder(): Unit \ Assert =
    Assert.assertEq(expected = ("ORDER BY ((c.data->>'views')::numeric) DESC, (c.data->>'title') ASC, e.id ASC", "ORDER BY e.updated_at DESC, e.id ASC"),
        (Fragment.renderOrder(EntryFilterSql.order(filterFields(), (SortKey.ByField(CmsTestKit.apiId("views")), Direction.Desc) :: (SortKey.ByField(CmsTestKit.apiId("title")), Direction.Asc) :: Nil)),
         Fragment.renderOrder(EntryFilterSql.order(filterFields(), Nil))))

/// 配列の「含む」は jsonb_array_elements_text の副問い合わせで、値はプレースホルダ。RawSql が付く。
@Test
def testEntryFilterSqlArrayContains(): Unit \ Assert =
    let rendered = run {
        Fragment.renderPred(EntryFilterSql.pred(Condition.ArrayContains(CmsTestKit.apiId("tags"), "t1") :: Nil), 1)
    } with RawSql.runWithAllow;
    Assert.assertEq(expected = ("(EXISTS (SELECT 1 FROM jsonb_array_elements_text(c.data->'tags') AS elem WHERE elem = $1))", List#{SqlValue.Str("t1")}), rendered)
