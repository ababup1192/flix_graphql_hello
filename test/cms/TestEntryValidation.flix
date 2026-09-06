use Util.Json.Json

///
/// EntryValidation: 下書きの中身の検証と、変更の重ね方。全部純粋。
///

///
/// blogs 型のフィールド。title(text, maxLength 10) / views(number, integer 0..100) / tags(text, many) / draft(boolean)
///
def fields(): List[FieldDef] =
    let base = { id = FieldId.FieldId(0i64), typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("x"), name = "", kind = FieldKind.Text, many = false, required = false, unique = false, localized = false, config = FieldConfig.empty(), position = 0 };
    { id = FieldId.FieldId(1i64), apiId = CmsTestKit.apiId("title"), config = { maxLength = Some(10) | FieldConfig.empty() } | base } ::
    { id = FieldId.FieldId(2i64), apiId = CmsTestKit.apiId("views"), kind = FieldKind.Number, config = { min = Some(0.0), max = Some(100.0), integer = Some(true) | FieldConfig.empty() } | base } ::
    { id = FieldId.FieldId(3i64), apiId = CmsTestKit.apiId("tags"), many = true | base } ::
    { id = FieldId.FieldId(4i64), apiId = CmsTestKit.apiId("draft"), kind = FieldKind.Boolean | base } :: Nil

def data(pairs: List[(String, Json)]): EntryData =
    pairs |> List.map(match (key, value) -> (CmsTestKit.apiId(key), value)) |> List.toMap

def number(n: Float64): Json = Float64.tryToBigDecimal(n) |> Option.map(Json.JNumber) |> Option.getWithDefault(Json.JNull)

/// 形が合う中身は通る。無いフィールドは構わず、null はどの kind でも通る。
@Test
def testEntryValidationOk(): Unit \ Assert =
    Assert.assertEq(expected = Nil,
        EntryValidation.draft(fields(), data(List#{("title", Json.JString("hello")), ("views", number(42.0)), ("tags", Json.JArray(Vector#{Json.JString("a"), Json.JString("b")})), ("draft", Json.JNull)})))

/// 型に無いフィールド、kind に合わない値、配列でない many は落ちる。
@Test
def testEntryValidationShape(): Unit \ Assert =
    Assert.assertEq(expected = List#{"fields.body", "fields.draft", "fields.tags", "fields.title", "fields.views"},
        CmsTestKit.violationPaths(EntryValidation.draft(fields(), data(List#{
            ("body", Json.JString("x")),
            ("title", number(1.0)),
            ("views", Json.JString("many")),
            ("tags", Json.JString("not-array")),
            ("draft", Json.JString("yes"))}))) |> List.sort)

/// maxLength、min / max、integer の違反は kind が合っていても落ちる。配列の中も見る。
@Test
def testEntryValidationConfig(): Unit \ Assert =
    Assert.assertEq(expected = List#{"fields.tags", "fields.title", "fields.views", "fields.views"},
        CmsTestKit.violationPaths(EntryValidation.draft(fields(), data(List#{
            ("title", Json.JString("0123456789ab")),
            ("views", number(150.5)),
            ("tags", Json.JArray(Vector#{Json.JString("ok"), number(1.0)}))}))) |> List.sort)

/// merge は patch のキーだけ上書きし、null は消す。
@Test
def testEntryValidationMerge(): Unit \ Assert =
    let before = data(List#{("title", Json.JString("old")), ("views", number(1.0)), ("draft", Json.JBool(true))});
    let patch = data(List#{("title", Json.JString("new")), ("views", Json.JNull)});
    Assert.assertEq(expected = data(List#{("title", Json.JString("new")), ("draft", Json.JBool(true))}),
        EntryValidation.merge(before, patch))
