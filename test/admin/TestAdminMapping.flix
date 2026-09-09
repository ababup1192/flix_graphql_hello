///
/// AdminMapping: GraphQL の型 ↔ ドメインの写し。DB 無し。
///
mod TestAdminMapping {

    /// id は数字の文字列で往復する（TypeId / FieldId / VersionId）。数字でなければ invalid。
    @Test
    def testAdminMappingIdRoundTrip(): Unit \ Assert =
        let roundTrip = () -> (
            AdminMapping.typeId("id", AdminMapping.idOfType(TypeId.TypeId(42i64))),
            AdminMapping.fieldId("id", AdminMapping.idOfField(FieldId.FieldId(7i64))),
            AdminMapping.versionId("id", AdminMapping.idOfVersion(VersionId.VersionId(9i64))));
        Assert.assertEq(expected = (Ok((TypeId.TypeId(42i64), FieldId.FieldId(7i64), VersionId.VersionId(9i64))), List#{"id"}),
            (CmsTestKit.runWithResult(roundTrip),
             CmsTestKit.failurePaths(CmsTestKit.runWithResult(() -> AdminMapping.typeId("id", Id.Id("TypeId(1)"))))))

    /// FieldKind と TypeKind は GraphQL の enum と全 case で往復する。
    @Test
    def testAdminMappingKindRoundTrip(): Unit \ Assert =
        let kinds = List#{FieldKind.Text, FieldKind.TextArea, FieldKind.Slug, FieldKind.Number, FieldKind.Boolean, FieldKind.Select, FieldKind.Reference, FieldKind.Object, FieldKind.Blocks, FieldKind.Asset, FieldKind.RichText, FieldKind.Date};
        Assert.assertEq(expected = (kinds, List#{TypeKind.Collection, TypeKind.Singleton}),
            (kinds |> List.map(kind -> AdminMapping.fieldKindOf(AdminMapping.fieldKindToGql(kind))),
             List#{TypeKind.Collection, TypeKind.Singleton} |> List.map(kind -> AdminMapping.typeKindOf(AdminMapping.typeKindToGql(kind)))))

    // ---- entries の where / orderBy ----

    def fields(): List[FieldDef] =
        CmsTestKit.fieldDef("title", FieldKind.Text) ::
        CmsTestKit.fieldDef("views", FieldKind.Number) ::
        CmsTestKit.fieldDef("flag", FieldKind.Boolean) ::
        CmsTestKit.fieldDef("publishOn", FieldKind.Date) ::
        { many = true | CmsTestKit.fieldDef("tags", FieldKind.Text) } ::
        CmsTestKit.fieldDef("body", FieldKind.RichText) :: Nil

    def condition(apiId: String, op: GeneratedAdmin.FieldConditionOp, value: Option[Value]): GeneratedAdmin.EntryFieldCondition =
        { apiId = apiId, op = op, value = value }

    def violation(apiId: String, message: String): Result[Violation, Condition] = Err(Violation.Violation("where.fields.${apiId}", message))

    /// フィールドの条件は op と kind で Condition に写る。型に無い apiId、kind に合わない op、value の型違いは Err。読めない日時は Never。
    @Test
    def testAdminMappingFieldCondition(): Unit \ Assert =
        let title = CmsTestKit.apiId("title");
        let views = CmsTestKit.apiId("views");
        let flag = CmsTestKit.apiId("flag");
        let publishOn = CmsTestKit.apiId("publishOn");
        let tags = CmsTestKit.apiId("tags");
        let at = Timestamp.at("2026-09-08T00:00:00Z");
        let cases = List#{
            (condition("title", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Str("x"))),                 Ok(Condition.TextEq(title, "x"))),
            (condition("title", GeneratedAdmin.FieldConditionOp.In, Some(Value.List(Value.Str("a") :: Value.Str("b") :: Nil))), Ok(Condition.TextIn(title, List#{"a", "b"}))),
            (condition("title", GeneratedAdmin.FieldConditionOp.Contains, Some(Value.Str("x"))),           Ok(Condition.TextContains(title, "x"))),
            (condition("title", GeneratedAdmin.FieldConditionOp.StartsWith, Some(Value.Str("x"))),         Ok(Condition.TextStartsWith(title, "x"))),
            (condition("title", GeneratedAdmin.FieldConditionOp.IsNull, None),                             Ok(Condition.IsNull(title, true))),
            (condition("title", GeneratedAdmin.FieldConditionOp.IsNull, Some(Value.Bool(false))),          Ok(Condition.IsNull(title, false))),
            (condition("views", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Int(1))),                   Ok(Condition.NumberEq(views, 1.0))),
            (condition("views", GeneratedAdmin.FieldConditionOp.Gt, Some(Value.Float(1.5))),               Ok(Condition.NumberGt(views, 1.5))),
            (condition("views", GeneratedAdmin.FieldConditionOp.Gte, Some(Value.Int(1))),                  Ok(Condition.NumberGte(views, 1.0))),
            (condition("views", GeneratedAdmin.FieldConditionOp.Lt, Some(Value.Int(1))),                   Ok(Condition.NumberLt(views, 1.0))),
            (condition("views", GeneratedAdmin.FieldConditionOp.Lte, Some(Value.Int(1))),                  Ok(Condition.NumberLte(views, 1.0))),
            (condition("flag", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Bool(true))),                Ok(Condition.BoolEq(flag, true))),
            (condition("publishOn", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Str("2026-09-08"))),    Ok(Condition.DateEq(publishOn, at))),
            (condition("publishOn", GeneratedAdmin.FieldConditionOp.Gte, Some(Value.Str("2026-09-08"))),   Ok(Condition.DateGte(publishOn, at))),
            (condition("publishOn", GeneratedAdmin.FieldConditionOp.Lt, Some(Value.Str("not a date"))),    Ok(Condition.Never)),
            (condition("tags", GeneratedAdmin.FieldConditionOp.ArrayContains, Some(Value.Str("t1"))),      Ok(Condition.ArrayContains(tags, "t1"))),
            (condition("tags", GeneratedAdmin.FieldConditionOp.IsNull, Some(Value.Bool(true))),            Ok(Condition.IsNull(tags, true))),
            (condition("nope", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Str("x"))),                  violation("nope", "'nope' はこの型にありません")),
            (condition("title", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Int(1))),                   violation("title", "value は文字列で渡してください")),
            (condition("views", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Str("1"))),                 violation("views", "value は数で渡してください")),
            (condition("flag", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Str("true"))),               violation("flag", "value は真偽値で渡してください")),
            (condition("title", GeneratedAdmin.FieldConditionOp.In, Some(Value.Str("a"))),                 violation("title", "value は文字列の配列で渡してください")),
            (condition("title", GeneratedAdmin.FieldConditionOp.IsNull, Some(Value.Str("yes"))),           violation("title", "value は真偽値で渡してください")),
            (condition("title", GeneratedAdmin.FieldConditionOp.Gt, Some(Value.Str("a"))),                 violation("title", "この op はこのフィールドの kind には使えません")),
            (condition("views", GeneratedAdmin.FieldConditionOp.Contains, Some(Value.Str("1"))),           violation("views", "この op はこのフィールドの kind には使えません")),
            (condition("tags", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Str("t1"))),                 violation("tags", "この op はこのフィールドの kind には使えません")),
            (condition("title", GeneratedAdmin.FieldConditionOp.ArrayContains, Some(Value.Str("x"))),      violation("title", "この op はこのフィールドの kind には使えません")),
            (condition("body", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Str("x"))),                  violation("body", "この op はこのフィールドの kind には使えません"))
        };
        let label = given -> (given#apiId, given#op, given#value);
        Assert.assertEq(
            expected = cases |> List.map(match (given, outcome) -> (label(given), outcome)),
            cases |> List.map(match (given, _) -> (label(given), AdminMapping.fieldConditionOf(fields(), given))))

    /// where の stage は StageEq、id_in は規則に合う id だけ（規則外は落ちる）、fields は順に並ぶ。None なら空。
    @Test
    def testAdminMappingEntryWhere(): Unit \ Assert =
        let given = { stage = Some(GeneratedAdmin.ContentStage.Published), id_in = Some(Id.Id("a") :: Id.Id("bad id!") :: Nil),
                      fields = Some(condition("title", GeneratedAdmin.FieldConditionOp.Eq, Some(Value.Str("x"))) :: Nil),
                      createdAt = None, updatedAt = None, publishedAt = None };
        Assert.assertEq(
            expected = (Ok(Condition.StageEq(Stage.Published) :: Condition.IdIn(CmsTestKit.entryIds(List#{"a"})) :: Condition.TextEq(CmsTestKit.apiId("title"), "x") :: Nil), Ok(Nil), (true, false)),
            (CmsTestKit.runWithResult(() -> AdminMapping.entryWhere(fields(), Some(given))),
             CmsTestKit.runWithResult(() -> AdminMapping.entryWhere(fields(), None)),
             (AdminMapping.whereNeedsFields(Some(given)), AdminMapping.whereNeedsFields(Some({ fields = None | given })))))

    /// システムの日時は書いた口だけが条件になる。値は日付だけでもオフセット付きでも読み、読めない値は Never（何にも合わない）。
    @Test
    def testAdminMappingEntryWhereSystemDates(): Unit \ Assert =
        let filter = { gt = None, gte = Some("2026-09-01"), lt = None, lte = Some("2026-09-09T09:00:00+09:00") };
        let given = { stage = None, id_in = None, fields = None,
                      createdAt = None, updatedAt = Some(filter), publishedAt = Some({ gte = Some("someday") | noRange() }) };
        Assert.assertEq(
            expected = Ok(Condition.SystemDateCmp(SystemDate.UpdatedAt, RangeOp.Gte, Timestamp.at("2026-09-01T00:00:00Z")) ::
                          Condition.SystemDateCmp(SystemDate.UpdatedAt, RangeOp.Lte, Timestamp.at("2026-09-09T00:00:00Z")) ::
                          Condition.Never :: Nil),
            CmsTestKit.runWithResult(() -> AdminMapping.entryWhere(fields(), Some(given))))

    /// 何も書いていない範囲の入力。
    def noRange(): GeneratedAdmin.DateTimeFilter = { gt = None, gte = None, lt = None, lte = None }

    /// orderBy の field は組み込みの名前かフィールドの apiId、direction は ASC / DESC。規則外の field は invalid（orderBy.field）。
    @Test
    def testAdminMappingEntryOrderBy(): Unit \ Assert =
        let terms = { field = "updatedAt", direction = GeneratedAdmin.SortDirection.Desc } :: { field = "title", direction = GeneratedAdmin.SortDirection.Asc } :: Nil;
        Assert.assertEq(
            expected = (Ok((SortKey.ByUpdatedAt, Direction.Desc) :: (SortKey.ByField(CmsTestKit.apiId("title")), Direction.Asc) :: Nil), Ok(Nil), List#{"orderBy.field"}),
            (CmsTestKit.runWithResult(() -> AdminMapping.entryOrderBy(Some(terms))),
             CmsTestKit.runWithResult(() -> AdminMapping.entryOrderBy(None)),
             CmsTestKit.failurePaths(CmsTestKit.runWithResult(() -> AdminMapping.entryOrderBy(Some({ field = "Bad Name", direction = GeneratedAdmin.SortDirection.Asc } :: Nil))))))

}
