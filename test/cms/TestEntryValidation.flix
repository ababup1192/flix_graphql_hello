use Util.Json.Json

///
/// EntryValidation: 下書きの中身の検証と、変更の重ね方。全部純粋。
///

///
/// blogs 型のフィールド。title(text, maxLength 10) / views(number, integer 0..100) / tags(text, many) / draft(boolean)
///
def validationFields(): List[FieldDef] =
    let base = { id = FieldId.FieldId(0i64), typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("x"), name = "", kind = FieldKind.Text, many = false, required = false, unique = false, localized = false, target = None, parent = None, children = Children.none(), config = FieldConfig.empty(), position = 0 };
    { id = FieldId.FieldId(1i64), apiId = CmsTestKit.apiId("title"), config = { maxLength = Some(10) | FieldConfig.empty() } | base } ::
    { id = FieldId.FieldId(2i64), apiId = CmsTestKit.apiId("views"), kind = FieldKind.Number, config = { min = Some(0.0), max = Some(100.0), integer = Some(true) | FieldConfig.empty() } | base } ::
    { id = FieldId.FieldId(3i64), apiId = CmsTestKit.apiId("tags"), many = true | base } ::
    { id = FieldId.FieldId(4i64), apiId = CmsTestKit.apiId("draft"), kind = FieldKind.Boolean | base } :: Nil

/// 形が合う中身は通る。無いフィールドは構わず、null はどの kind でも通る。
@Test
def testEntryValidationOk(): Unit \ Assert =
    Assert.assertEq(expected = Nil,
        EntryValidation.draft(validationFields(), CmsTestKit.entryData(List#{("title", Json.JString("hello")), ("views", CmsTestKit.floatJson(42.0)), ("tags", Json.JArray(Vector#{Json.JString("a"), Json.JString("b")})), ("draft", Json.JNull)})))

/// 型に無いフィールド、kind に合わない値、配列でない many は落ちる。
@Test
def testEntryValidationShape(): Unit \ Assert =
    Assert.assertEq(expected = List#{"fields.body", "fields.draft", "fields.tags", "fields.title", "fields.views"},
        CmsTestKit.violationPaths(EntryValidation.draft(validationFields(), CmsTestKit.entryData(List#{
            ("body", Json.JString("x")),
            ("title", CmsTestKit.floatJson(1.0)),
            ("views", Json.JString("many")),
            ("tags", Json.JString("not-array")),
            ("draft", Json.JString("yes"))}))) |> List.sort)

/// maxLength、min / max、integer の違反は kind が合っていても落ちる。配列の中も見て、パスは何番目かまで指す。
@Test
def testEntryValidationConfig(): Unit \ Assert =
    Assert.assertEq(expected = List#{"fields.tags[1]", "fields.title", "fields.views", "fields.views"},
        CmsTestKit.violationPaths(EntryValidation.draft(validationFields(), CmsTestKit.entryData(List#{
            ("title", Json.JString("0123456789ab")),
            ("views", CmsTestKit.floatJson(150.5)),
            ("tags", Json.JArray(Vector#{Json.JString("ok"), CmsTestKit.floatJson(1.0)}))}))) |> List.sort)

/// merge は patch のキーだけ上書きし、null は消す。
@Test
def testEntryValidationMerge(): Unit \ Assert =
    let before = CmsTestKit.entryData(List#{("title", Json.JString("old")), ("views", CmsTestKit.floatJson(1.0)), ("draft", Json.JBool(true))});
    let patch = CmsTestKit.entryData(List#{("title", Json.JString("new")), ("views", Json.JNull)});
    Assert.assertEq(expected = CmsTestKit.entryData(List#{("title", Json.JString("new")), ("draft", Json.JBool(true))}),
        EntryValidation.merge(before, patch))

/// 公開の検査は required に値が要る。null・無い・空文字・空の配列は駄目で、下書きの検査も一緒に返る。
@Test
def testEntryValidationPublish(): Unit \ Assert =
    let base = { id = FieldId.FieldId(0i64), typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("x"), name = "", kind = FieldKind.Text, many = false, required = true, unique = false, localized = false, target = None, parent = None, children = Children.none(), config = FieldConfig.empty(), position = 0 };
    let fields = { apiId = CmsTestKit.apiId("title") | base } :: { apiId = CmsTestKit.apiId("tags"), many = true | base } :: { apiId = CmsTestKit.apiId("views"), kind = FieldKind.Number | base } :: Nil;
    Assert.assertEq(expected = (Nil, List#{"fields.tags", "fields.title", "fields.views"}),
        (CmsTestKit.violationPaths(EntryValidation.publish(fields, CmsTestKit.entryData(List#{("title", Json.JString("ok")), ("tags", Json.JArray(Vector#{Json.JString("a")})), ("views", CmsTestKit.intJson(1))}))),
         CmsTestKit.violationPaths(EntryValidation.publish(fields, CmsTestKit.entryData(List#{("title", Json.JString("")), ("tags", Json.JArray(Vector.empty()))}))) |> List.sort))

/// select は選択肢の中だけ、reference は entry の id の形だけ通る。
@Test
def testEntryValidationSelectAndReference(): Unit \ Assert =
    let base = { id = FieldId.FieldId(0i64), typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("x"), name = "", kind = FieldKind.Text, many = false, required = false, unique = false, localized = false, target = None, parent = None, children = Children.none(), config = FieldConfig.empty(), position = 0 };
    let fields = { apiId = CmsTestKit.apiId("category"), kind = FieldKind.Select, config = { options = List#{"A", "B"} | FieldConfig.empty() } | base } ::
                 { apiId = CmsTestKit.apiId("author"), kind = FieldKind.Reference, target = Some(TypeId.TypeId(2i64)) | base } :: Nil;
    Assert.assertEq(expected = (Nil, List#{"fields.author", "fields.category"}),
        (CmsTestKit.violationPaths(EntryValidation.draft(fields, CmsTestKit.entryData(List#{("category", Json.JString("A")), ("author", Json.JString("abc_123"))}))),
         CmsTestKit.violationPaths(EntryValidation.draft(fields, CmsTestKit.entryData(List#{("category", Json.JString("C")), ("author", Json.JString("no spaces!"))}))) |> List.sort))

/// Object は子の規則で中を見て、Blocks は blockType で variant を選んで中を見る。パスは入れ子の位置まで伸びる。
@Test
def testEntryValidationNested(): Unit \ Assert =
    let base = { id = FieldId.FieldId(0i64), typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("x"), name = "", kind = FieldKind.Text, many = false, required = false, unique = false, localized = false, target = None, parent = None, children = Children.none(), config = FieldConfig.empty(), position = 0 };
    let hero = { apiId = CmsTestKit.apiId("hero"), kind = FieldKind.Object, children = Children.Children({ apiId = CmsTestKit.apiId("headline") | base } :: Nil) | base };
    let fields = { apiId = CmsTestKit.apiId("related"), kind = FieldKind.Object, children = Children.Children({ apiId = CmsTestKit.apiId("label") | base } :: { apiId = CmsTestKit.apiId("count"), kind = FieldKind.Number | base } :: Nil) | base } ::
                 { apiId = CmsTestKit.apiId("sections"), kind = FieldKind.Blocks, many = true, children = Children.Children(hero :: Nil) | base } :: Nil;
    let ok = CmsTestKit.entryData(List#{
        ("related", Json.JObject(Map#{ "label" => Json.JString("a"), "count" => CmsTestKit.intJson(1) })),
        ("sections", Json.JArray(Vector#{Json.JObject(Map#{ "blockType" => Json.JString("hero"), "headline" => Json.JString("Hi") })}))});
    let bad = CmsTestKit.entryData(List#{
        ("related", Json.JObject(Map#{ "label" => CmsTestKit.intJson(1), "extra" => Json.JString("x") })),
        ("sections", Json.JArray(Vector#{Json.JObject(Map#{ "blockType" => Json.JString("nope") }), Json.JObject(Map#{ "blockType" => Json.JString("hero"), "headline" => CmsTestKit.intJson(2) })}))});
    Assert.assertEq(expected = (Nil, List#{"fields.related.extra", "fields.related.label", "fields.sections[0]", "fields.sections[1].headline"}),
        (CmsTestKit.violationPaths(EntryValidation.draft(fields, ok)),
         CmsTestKit.violationPaths(EntryValidation.draft(fields, bad)) |> List.sort))
