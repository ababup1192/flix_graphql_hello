///
/// ContentTypes: ユースケースを DB 無しで確かめる。決めた行を返す偽ハンドラで、検証と発行 SQL を見る。
///
///
/// content_types の行。blogs / Blog と tags / Tag の 2 型。
///
mod TestContentTypes {

    use SqlValue.SqlValue
    use Row.Row
    use CmsErr.CmsFailure

    def typeRows(): List[Row] =
        Row.makeRows(List#{"id", "api_id", "kind", "name", "singular", "plural", "preview_url", "created_at", "updated_at"},
            List#{
                List#{SqlValue.Int64(1i64), SqlValue.Str("blogs"), SqlValue.Str("collection"), SqlValue.Str("記事"), SqlValue.Str("Blog"), SqlValue.Str("blogs"), SqlValue.Str(""), SqlValue.ofTimestamp(Timestamp.at("2026-09-01T00:00:00Z")), SqlValue.ofTimestamp(Timestamp.at("2026-09-01T00:00:00Z"))},
                List#{SqlValue.Int64(2i64), SqlValue.Str("tags"), SqlValue.Str("collection"), SqlValue.Str("タグ"), SqlValue.Str("Tag"), SqlValue.Str("tags"), SqlValue.Str(""), SqlValue.ofTimestamp(Timestamp.at("2026-09-01T00:00:00Z")), SqlValue.ofTimestamp(Timestamp.at("2026-09-01T00:00:00Z"))}
            })

    ///
    /// content_fields の行。blogs に title と body。
    ///
    def fieldRows(): List[Row] =
        Row.makeRows(List#{"id", "type_id", "api_id", "name", "kind", "is_many", "is_required", "is_unique", "is_localized", "target_type_id", "parent_field_id", "config", "position"},
            List#{
                List#{SqlValue.Int64(10i64), SqlValue.Int64(1i64), SqlValue.Str("title"), SqlValue.Str("題名"), SqlValue.Str("text"), SqlValue.Bool(false), SqlValue.Bool(true), SqlValue.Bool(false), SqlValue.Bool(false), SqlValue.Null, SqlValue.Null, SqlValue.Json("{\"maxLength\": 120}"), SqlValue.Int32(0)},
                List#{SqlValue.Int64(11i64), SqlValue.Int64(1i64), SqlValue.Str("body"), SqlValue.Str("本文"), SqlValue.Str("textArea"), SqlValue.Bool(false), SqlValue.Bool(false), SqlValue.Bool(false), SqlValue.Bool(false), SqlValue.Null, SqlValue.Null, SqlValue.Json("{}"), SqlValue.Int32(1)}
            })

    ///
    /// SQL の文面で返す行を決める。INSERT の RETURNING は id 99、位置の問い合わせは 2。
    ///
    def rowsFor(sql: String): Option[List[Row]] =
        if (String.startsWith(prefix = "INSERT", sql)) Some(Row.makeRows(List#{"id"}, List#{List#{SqlValue.Int64(99i64)}}))
        else if (String.contains(substr = "max(position)", sql)) Some(Row.makeRows(List#{"next"}, List#{List#{SqlValue.Int32(2)}}))
        else if (String.contains(substr = "FROM content_fields", sql)) Some(fieldRows())
        else if (String.contains(substr = "FROM content_types", sql)) Some(typeRows())
        else bug!("想定外の SQL: ${sql}")

    ///
    /// 偽ハンドラで thunk を走らせ、(結果, 発行した SQL の先頭語の並び) を返す。DB の失敗は起きない前提で剥がす。
    ///
    def record(thunk: Unit -> a \ ef): (Result[CmsFailure, a], List[String]) \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr, Tenant, Session}) + IO =
        let (result, statements) = DbTest.runRecordingWith(rowsFor, 1, () -> DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Tenant.runWith(ProjectId.default(), () -> Session.runWith(Actor.System, thunk)))));
        let flattened = match result {
            case Ok(inner)    => inner
            case Err(failure) => bug!("unexpected DbFailure: ${failure}")
        };
        (flattened, statements |> List.map(statement -> statement#sql |> String.splitOn(substr = " ") |> List.head |> Option.getWithDefault("")))

    // ---- 読む ----

    /// list は 2 本の SELECT で、型ごとにフィールドを付けて返す。
    @Test
    def testContentTypesList(): Unit \ {Assert, IO} =
        let (result, sqls) = record(() -> ContentTypes.list());
        Assert.assertEq(expected = (Ok(List#{("blogs", List#{"title", "body"}), ("tags", Nil)}), List#{"SELECT", "SELECT"}),
            (result |> Result.map(List.map(contentType -> (ApiId.text(contentType#apiId), contentType#fields |> List.map(field -> ApiId.text(field#apiId))))), sqls))

    /// 行の config は FieldConfig に読まれ、kind と id はドメインの型になる。
    @Test
    def testContentTypesFieldShape(): Unit \ {Assert, IO} =
        let (result, _) = record(() -> ContentTypes.get(TypeId.TypeId(1i64)));
        Assert.assertEq(expected = Ok(Some((FieldId.FieldId(10i64), FieldKind.Text, Some(120), true))),
            result |> Result.map(contentType -> List.head(contentType#fields) |> Option.map(found -> (found#id, found#kind, found#config#maxLength, found#required))))

    // ---- 作る ----

    /// 既にある apiId は invalid で、INSERT は発行されない。
    @Test
    def testContentTypesCreateDuplicateWritesNothing(): Unit \ {Assert, IO} =
        let (result, sqls) = record(() -> ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事")));
        Assert.assertEq(expected = (List#{"apiId"}, false), (CmsTestKit.failurePaths(result), List.memberOf("INSERT", sqls)))

    /// 通れば INSERT が発行され、singular / plural は apiId から導かれる。
    @Test
    def testContentTypesCreateDerivesNames(): Unit \ {Assert, IO} =
        let (_, statements) = DbTest.runRecordingWith(rowsFor, 1, () -> DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Tenant.runWith(ProjectId.default(), () -> Session.runWith(Actor.System, () ->
            ContentTypes.create(CmsTestKit.typeDraft("profiles", "記事")))))));
        let insert = statements |> List.find(statement -> String.startsWith(prefix = "INSERT", statement#sql));
        Assert.assertEq(expected = Some(List#{SqlValue.Int64(1i64), SqlValue.Str("profiles"), SqlValue.Str("collection"), SqlValue.Str("記事"), SqlValue.Str("Profile"), SqlValue.Str("profiles"), SqlValue.Str("")}),
            insert |> Option.map(statement -> statement#params))

    // ---- フィールド ----

    /// 同じ型に既にある apiId は invalid。
    @Test
    def testContentTypesAddFieldDuplicate(): Unit \ {Assert, IO} =
        let (result, _) = record(() -> ContentTypes.addField(TypeId.TypeId(1i64), CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty())));
        Assert.assertEq(expected = List#{"apiId"}, CmsTestKit.failurePaths(result))

    /// 通れば末尾の位置（既存の max + 1）で INSERT され、型の updated_at を触る。
    @Test
    def testContentTypesAddFieldAppends(): Unit \ {Assert, IO} =
        let slugConfig = { sourceField = Some(CmsTestKit.apiId("title")) | FieldConfig.empty() };
        let (_, statements) = DbTest.runRecordingWith(rowsFor, 1, () -> DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Tenant.runWith(ProjectId.default(), () -> Session.runWith(Actor.System, () ->
            ContentTypes.addField(TypeId.TypeId(1i64), CmsTestKit.fieldDraft("slug", FieldKind.Slug, slugConfig)))))));
        let insert = statements |> List.find(statement -> String.startsWith(prefix = "INSERT", statement#sql));
        Assert.assertEq(expected = (Some(SqlValue.Int32(2)), true),
            (insert |> Option.flatMap(statement -> List.last(statement#params)),
             List.exists(statement -> String.contains(substr = "updated_at = now()", statement#sql), statements)))

    /// 無い型に足そうとすると notFound。
    @Test
    def testContentTypesAddFieldToMissingType(): Unit \ {Assert, IO} =
        let (result, _) = DbTest.runRecordingWith(_ -> Some(Nil), 0, () -> DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Tenant.runWith(ProjectId.default(), () -> Session.runWith(Actor.System, () ->
            ContentTypes.addField(TypeId.TypeId(7i64), CmsTestKit.fieldDraft("x", FieldKind.Text, FieldConfig.empty())))))));
        Assert.assertEq(expected = Ok(Err(CmsFailure.NotFound(Entity.ContentType, "7"))), result |> Result.map(Result.map(_ -> ())))

    /// reorderFields は全 id を過不足なく渡さないと invalid。
    @Test
    def testContentTypesReorderNeedsAllIds(): Unit \ {Assert, IO} =
        let (result, _) = record(() -> ContentTypes.reorderFields(TypeId.TypeId(1i64), List#{FieldId.FieldId(10i64)}));
        Assert.assertEq(expected = List#{"ids"}, CmsTestKit.failurePaths(result))

}
