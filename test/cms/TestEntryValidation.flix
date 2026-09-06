///
/// EntryValidation: 下書きの中身の検証と、変更の重ね方。全部純粋。
///
///
/// blogs 型のフィールド。title(text, maxLength 10) / views(number, integer 0..100) / tags(text, many) / draft(boolean)
///
mod TestEntryValidation {

    use Util.Json.Json

    def validationFields(): List[FieldDef] =
        { id = FieldId.FieldId(1i64), config = { maxLength = Some(10) | FieldConfig.empty() } | CmsTestKit.fieldDef("title", FieldKind.Text) } ::
        { id = FieldId.FieldId(2i64), config = { min = Some(0.0), max = Some(100.0), integer = Some(true) | FieldConfig.empty() } | CmsTestKit.fieldDef("views", FieldKind.Number) } ::
        { id = FieldId.FieldId(3i64), many = true | CmsTestKit.fieldDef("tags", FieldKind.Text) } ::
        { id = FieldId.FieldId(4i64) | CmsTestKit.fieldDef("draft", FieldKind.Boolean) } :: Nil

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

    /// integer は小数部の有無だけ見る。Int32 を超える整数も通り、1.5 は落ちる。
    @Test
    def testEntryValidationIntegerBeyondInt32(): Unit \ Assert =
        let fields = { config = { integer = Some(true) | FieldConfig.empty() } | CmsTestKit.fieldDef("views", FieldKind.Number) } :: Nil;
        Assert.assertEq(expected = (Nil, List#{"fields.views"}),
            (CmsTestKit.violationPaths(EntryValidation.draft(fields, CmsTestKit.entryData(List#{("views", CmsTestKit.floatJson(3000000000.0))}))),
             CmsTestKit.violationPaths(EntryValidation.draft(fields, CmsTestKit.entryData(List#{("views", CmsTestKit.floatJson(1.5))})))))

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
        let required = api -> kind -> { required = true | CmsTestKit.fieldDef(api, kind) };
        let fields = required("title", FieldKind.Text) :: { many = true | required("tags", FieldKind.Text) } :: required("views", FieldKind.Number) :: Nil;
        Assert.assertEq(expected = (Nil, List#{"fields.tags", "fields.title", "fields.views"}),
            (CmsTestKit.violationPaths(EntryValidation.publish(fields, CmsTestKit.entryData(List#{("title", Json.JString("ok")), ("tags", Json.JArray(Vector#{Json.JString("a")})), ("views", CmsTestKit.intJson(1))}))),
             CmsTestKit.violationPaths(EntryValidation.publish(fields, CmsTestKit.entryData(List#{("title", Json.JString("")), ("tags", Json.JArray(Vector.empty()))}))) |> List.sort))

    /// select は選択肢の中だけ、reference は entry の id の形だけ通る。
    @Test
    def testEntryValidationSelectAndReference(): Unit \ Assert =
        let fields = { config = { options = List#{"A", "B"} | FieldConfig.empty() } | CmsTestKit.fieldDef("category", FieldKind.Select) } ::
                     { target = Some(TypeId.TypeId(2i64)) | CmsTestKit.fieldDef("author", FieldKind.Reference) } :: Nil;
        Assert.assertEq(expected = (Nil, List#{"fields.author", "fields.category"}),
            (CmsTestKit.violationPaths(EntryValidation.draft(fields, CmsTestKit.entryData(List#{("category", Json.JString("A")), ("author", Json.JString("abc_123"))}))),
             CmsTestKit.violationPaths(EntryValidation.draft(fields, CmsTestKit.entryData(List#{("category", Json.JString("C")), ("author", Json.JString("no spaces!"))}))) |> List.sort))

    /// Object は子の規則で中を見て、Blocks は blockType で variant を選んで中を見る。パスは入れ子の位置まで伸びる。
    @Test
    def testEntryValidationNested(): Unit \ Assert =
        let hero = { children = Children.Children(CmsTestKit.fieldDef("headline", FieldKind.Text) :: Nil) | CmsTestKit.fieldDef("hero", FieldKind.Object) };
        let fields = { children = Children.Children(CmsTestKit.fieldDef("label", FieldKind.Text) :: CmsTestKit.fieldDef("count", FieldKind.Number) :: Nil) | CmsTestKit.fieldDef("related", FieldKind.Object) } ::
                     { many = true, children = Children.Children(hero :: Nil) | CmsTestKit.fieldDef("sections", FieldKind.Blocks) } :: Nil;
        let ok = CmsTestKit.entryData(List#{
            ("related", Json.JObject(Map#{ "label" => Json.JString("a"), "count" => CmsTestKit.intJson(1) })),
            ("sections", Json.JArray(Vector#{Json.JObject(Map#{ "blockType" => Json.JString("hero"), "headline" => Json.JString("Hi") })}))});
        let bad = CmsTestKit.entryData(List#{
            ("related", Json.JObject(Map#{ "label" => CmsTestKit.intJson(1), "extra" => Json.JString("x") })),
            ("sections", Json.JArray(Vector#{Json.JObject(Map#{ "blockType" => Json.JString("nope") }), Json.JObject(Map#{ "blockType" => Json.JString("hero"), "headline" => CmsTestKit.intJson(2) })}))});
        Assert.assertEq(expected = (Nil, List#{"fields.related.extra", "fields.related.label", "fields.sections[0]", "fields.sections[1].headline"}),
            (CmsTestKit.violationPaths(EntryValidation.draft(fields, ok)),
             CmsTestKit.violationPaths(EntryValidation.draft(fields, bad)) |> List.sort))

    /// maxLength は文字で数える。絵文字（サロゲートペア）10 個は 10 文字で通り、11 文字目で落ちる。
    @Test
    def testEntryValidationMaxLengthCountsCodePoints(): Unit \ Assert =
        let emoji10 = "😀😀😀😀😀😀😀😀😀😀";
        Assert.assertEq(expected = (Nil, List#{"fields.title"}),
            (CmsTestKit.violationPaths(EntryValidation.draft(validationFields(), CmsTestKit.entryData(List#{("title", Json.JString(emoji10))}))),
             CmsTestKit.violationPaths(EntryValidation.draft(validationFields(), CmsTestKit.entryData(List#{("title", Json.JString(emoji10 + "a"))})))))

    /// 入れ子の規則外のキーは黙って落とさず違反にする（Object の中も、Blocks の variant の中も）。
    @Test
    def testEntryValidationNestedBadKeys(): Unit \ Assert =
        let hero = { children = Children.Children(CmsTestKit.fieldDef("headline", FieldKind.Text) :: Nil) | CmsTestKit.fieldDef("hero", FieldKind.Object) };
        let fields = { children = Children.Children(CmsTestKit.fieldDef("label", FieldKind.Text) :: Nil) | CmsTestKit.fieldDef("related", FieldKind.Object) } ::
                     { many = true, children = Children.Children(hero :: Nil) | CmsTestKit.fieldDef("sections", FieldKind.Blocks) } :: Nil;
        let data = CmsTestKit.entryData(List#{
            ("related", Json.JObject(Map#{ "label" => Json.JString("a"), "Bad Key" => Json.JString("x") })),
            ("sections", Json.JArray(Vector#{Json.JObject(Map#{ "blockType" => Json.JString("hero"), "bad-key" => Json.JString("x") })}))});
        Assert.assertEq(expected = List#{"fields.related.Bad Key", "fields.sections[0].bad-key"},
            CmsTestKit.violationPaths(EntryValidation.draft(fields, data)) |> List.sort)

    /// 型に無いキーを落とす（フィールドを消した後の古い値）。型にあるキーはそのまま。
    @Test
    def testEntryValidationPrune(): Unit \ Assert =
        let data = CmsTestKit.entryData(List#{("title", Json.JString("a")), ("gone", Json.JString("b"))});
        Assert.assertEq(expected = List#{"title"},
            EntryValidation.prune(validationFields(), data) |> Map.keysOf |> Set.toList |> List.map(ApiId.text))
}
