use SqlValue.SqlValue
use Row.Row
use CmsErr.CmsFailure
use GeneratedAdmin.FieldKind

///
/// ContentTypes: ユースケースを DB 無しで確かめる。決めた行を返す偽ハンドラで、検証と発行 SQL を見る。
///


///
/// content_types の行。blogs / Blog と tags / Tag の 2 型。
///
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
    Row.makeRows(List#{"id", "type_id", "api_id", "name", "kind", "is_many", "is_required", "is_unique", "is_localized", "config", "position"},
        List#{
            List#{SqlValue.Int64(10i64), SqlValue.Int64(1i64), SqlValue.Str("title"), SqlValue.Str("題名"), SqlValue.Str("text"), SqlValue.Bool(false), SqlValue.Bool(true), SqlValue.Bool(false), SqlValue.Bool(false), SqlValue.Json("{\"maxLength\": 120}"), SqlValue.Int32(0)},
            List#{SqlValue.Int64(11i64), SqlValue.Int64(1i64), SqlValue.Str("body"), SqlValue.Str("本文"), SqlValue.Str("textArea"), SqlValue.Bool(false), SqlValue.Bool(false), SqlValue.Bool(false), SqlValue.Bool(false), SqlValue.Json("{}"), SqlValue.Int32(1)}
        })

///
/// SQL の文面で返す行を決める。INSERT の RETURNING は id 99、位置の問い合わせは 2。
///
def rowsFor(sql: String): Option[List[Row]] =
    if (String.startsWith(prefix = "INSERT", sql)) Some(Row.makeRows(List#{"id"}, List#{List#{SqlValue.Int64(99i64)}}))
    else if (String.contains(substr = "max(position)", sql)) Some(Row.makeRows(List#{"next"}, List#{List#{SqlValue.Int32(2)}}))
    else if (String.contains(substr = "FROM content_fields", sql)) Some(fieldRows())
    else Some(typeRows())

///
/// 偽ハンドラで thunk を走らせ、(結果, 発行した SQL の先頭語の並び) を返す。
///
def record(thunk: Unit -> a \ ef): (Result[CmsFailure, a], List[String]) \ ef - {SqlRead, SqlWrite, CmsErr} =
    let (result, statements) = DbTest.runRecordingWith(rowsFor, 1, () -> CmsErr.runWithResult(thunk));
    (result, statements |> List.map(statement -> statement#sql |> String.splitOn(substr = " ") |> List.head |> Option.getWithDefault("")))

///
/// 誤りのパスだけ。
///
def failurePaths(result: Result[CmsFailure, a]): List[String] = match result {
    case Err(CmsFailure.Invalid(violations)) => violations |> List.map(violation -> { let Violation.Violation(path, _) = violation; path })
    case _                                   => Nil
}

// ---- 読む ----

/// list は 2 本の SELECT で、型ごとにフィールドを付けて返す。
@Test
def testContentTypesList(): Unit \ {Assert, IO} =
    let (result, sqls) = DbError.runWithFailure(() -> record(() -> ContentTypes.list()))
        |> Result.getWithDefault((Err(CmsFailure.NotFound("", "")), Nil));
    Assert.assertEq(expected = (Ok(List#{("blogs", List#{"title", "body"}), ("tags", Nil)}), List#{"SELECT", "SELECT"}),
        (result |> Result.map(List.map(contentType -> (contentType#apiId, contentType#fields |> List.map(field -> field#apiId)))), sqls))

/// 行の config は FieldConfig に読まれ、kind は enum になる。
@Test
def testContentTypesFieldShape(): Unit \ {Assert, IO} =
    let field = DbError.runWithFailure(() -> record(() -> ContentTypes.get(1i64)))
        |> Result.map(fst) |> Result.map(Result.map(contentType -> List.head(contentType#fields)));
    Assert.assertEq(expected = Ok(Ok(Some((FieldKind.Text, Some(120), true)))),
        field |> Result.map(Result.map(Option.map(found -> (found#kind, found#config#maxLength, found#required)))))

// ---- 作る ----

/// 規則に合わない apiId は invalid で、INSERT は発行されない。
@Test
def testContentTypesCreateInvalidWritesNothing(): Unit \ {Assert, IO} =
    let (result, sqls) = DbError.runWithFailure(() -> record(() ->
        ContentTypes.create({ apiId = "Blog Posts", kind = None, name = "記事", singular = None, plural = None, previewUrl = None })))
        |> Result.getWithDefault((Err(CmsFailure.NotFound("", "")), Nil));
    Assert.assertEq(expected = (List#{"apiId"}, false), (failurePaths(result), List.memberOf("INSERT", sqls)))

/// 既にある apiId も invalid。
@Test
def testContentTypesCreateDuplicate(): Unit \ {Assert, IO} =
    let (result, _) = DbError.runWithFailure(() -> record(() ->
        ContentTypes.create({ apiId = "blogs", kind = None, name = "記事", singular = None, plural = None, previewUrl = None })))
        |> Result.getWithDefault((Err(CmsFailure.NotFound("", "")), Nil));
    Assert.assertEq(expected = List#{"apiId"}, failurePaths(result))

/// 通れば INSERT が発行され、singular / plural は apiId から導かれる。
@Test
def testContentTypesCreateDerivesNames(): Unit \ {Assert, IO} =
    let (_, statements) = DbTest.runRecordingWith(rowsFor, 1, () -> DbError.runWithFailure(() -> CmsErr.runWithResult(() ->
        ContentTypes.create({ apiId = "profiles", kind = None, name = "書き手", singular = None, plural = None, previewUrl = None }))));
    let insert = statements |> List.find(statement -> String.startsWith(prefix = "INSERT", statement#sql));
    Assert.assertEq(expected = Some(List#{SqlValue.Str("profiles"), SqlValue.Str("collection"), SqlValue.Str("書き手"), SqlValue.Str("Profile"), SqlValue.Str("profiles"), SqlValue.Str("")}),
        insert |> Option.map(statement -> statement#params))

// ---- フィールド ----

/// 同じ型に既にある apiId は invalid。
@Test
def testContentTypesAddFieldDuplicate(): Unit \ {Assert, IO} =
    let (result, _) = DbError.runWithFailure(() -> record(() ->
        ContentTypes.addField(1i64, { apiId = "title", name = "題名", kind = FieldKind.Text, many = None, required = None, unique = None, localized = None, config = None })))
        |> Result.getWithDefault((Err(CmsFailure.NotFound("", "")), Nil));
    Assert.assertEq(expected = List#{"apiId"}, failurePaths(result))

/// 通れば末尾の位置（既存の max + 1）で INSERT され、型の updated_at を触る。
@Test
def testContentTypesAddFieldAppends(): Unit \ {Assert, IO} =
    let (_, statements) = DbTest.runRecordingWith(rowsFor, 1, () -> DbError.runWithFailure(() -> CmsErr.runWithResult(() ->
        ContentTypes.addField(1i64, { apiId = "slug", name = "スラッグ", kind = FieldKind.Slug, many = None, required = Some(true), unique = Some(true), localized = None, config = Some({ maxLength = None, sourceField = Some("title"), min = None, max = None, integer = None }) }))));
    let insert = statements |> List.find(statement -> String.startsWith(prefix = "INSERT", statement#sql));
    Assert.assertEq(expected = (Some(SqlValue.Int32(2)), true),
        (insert |> Option.flatMap(statement -> List.last(statement#params)),
         List.exists(statement -> String.contains(substr = "updated_at = now()", statement#sql), statements)))

/// 無い型に足そうとすると notFound。
@Test
def testContentTypesAddFieldToMissingType(): Unit \ {Assert, IO} =
    let (result, _) = DbTest.runRecordingWith(_ -> Some(Nil), 0, () -> DbError.runWithFailure(() -> CmsErr.runWithResult(() ->
        ContentTypes.addField(7i64, { apiId = "x", name = "x", kind = FieldKind.Text, many = None, required = None, unique = None, localized = None, config = None }))));
    Assert.assertEq(expected = Ok(Err(CmsFailure.NotFound("content type", "7"))), result |> Result.map(Result.map(field -> field#apiId)))

/// reorderFields は全 id を過不足なく渡さないと invalid。
@Test
def testContentTypesReorderNeedsAllIds(): Unit \ {Assert, IO} =
    let (result, _) = DbError.runWithFailure(() -> record(() -> ContentTypes.reorderFields(1i64, List#{10i64})))
        |> Result.getWithDefault((Err(CmsFailure.NotFound("", "")), Nil));
    Assert.assertEq(expected = List#{"ids"}, failurePaths(result))
