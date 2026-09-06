///
/// EntryLinks: 中身から参照を取り出す。純粋。
///
/// reference のフィールドだけ見て、単体は位置 0、配列は要素の位置。規則外の id は捨てる。
mod TestEntryLinks {

    use Util.Json.Json

    @Test
    def testEntryLinksExtract(): Unit \ Assert =
        let fields = { id = FieldId.FieldId(1i64), target = Some(TypeId.TypeId(2i64)) | CmsTestKit.fieldDef("profile", FieldKind.Reference) } ::
                     { id = FieldId.FieldId(2i64), many = true, target = Some(TypeId.TypeId(3i64)) | CmsTestKit.fieldDef("tags", FieldKind.Reference) } ::
                     { id = FieldId.FieldId(3i64) | CmsTestKit.fieldDef("title", FieldKind.Text) } :: Nil;
        let data = CmsTestKit.entryData(List#{("profile", Json.JString("p1")), ("tags", Json.JArray(Vector#{Json.JString("t1"), Json.JString("bad id"), Json.JString("t2")})), ("title", Json.JString("p9"))});
        Assert.assertEq(expected = List#{(1i64, "p1", 0), (2i64, "t1", 0), (2i64, "t2", 2)},
            EntryLinks.extract(fields, data) |> List.map(link -> (FieldId.toInt64(link#field#id), EntryId.text(link#target), link#position)))

    /// Object と Blocks の中の参照も辿る。
    @Test
    def testEntryLinksNested(): Unit \ Assert =
        let post = { id = FieldId.FieldId(9i64), target = Some(TypeId.TypeId(1i64)) | CmsTestKit.fieldDef("post", FieldKind.Reference) };
        let teaser = { children = Children.Children(post :: Nil) | CmsTestKit.fieldDef("teaser", FieldKind.Object) };
        let fields = { many = true, children = Children.Children(post :: Nil) | CmsTestKit.fieldDef("related", FieldKind.Object) } ::
                     { many = true, children = Children.Children(teaser :: Nil) | CmsTestKit.fieldDef("sections", FieldKind.Blocks) } :: Nil;
        let data = CmsTestKit.entryData(List#{
            ("related", Json.JArray(Vector#{Json.JObject(Map#{ "post" => Json.JString("a1") }), Json.JObject(Map#{ "post" => Json.JString("a2") })})),
            ("sections", Json.JArray(Vector#{Json.JObject(Map#{ "blockType" => Json.JString("teaser"), "post" => Json.JString("a3") })}))});
        Assert.assertEq(expected = List#{"a1", "a2", "a3"}, EntryLinks.targets(fields, data) |> List.map(EntryId.text))

}
