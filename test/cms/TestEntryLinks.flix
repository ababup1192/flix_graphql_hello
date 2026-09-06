use Util.Json.Json

///
/// EntryLinks: 中身から参照を取り出す。純粋。
///

/// reference のフィールドだけ見て、単体は位置 0、配列は要素の位置。規則外の id は捨てる。
@Test
def testEntryLinksExtract(): Unit \ Assert =
    let base = { id = FieldId.FieldId(0i64), typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("x"), name = "", kind = FieldKind.Text, many = false, required = false, unique = false, localized = false, target = None, config = FieldConfig.empty(), position = 0 };
    let fields = { id = FieldId.FieldId(1i64), apiId = CmsTestKit.apiId("profile"), kind = FieldKind.Reference, target = Some(TypeId.TypeId(2i64)) | base } ::
                 { id = FieldId.FieldId(2i64), apiId = CmsTestKit.apiId("tags"), kind = FieldKind.Reference, many = true, target = Some(TypeId.TypeId(3i64)) | base } ::
                 { id = FieldId.FieldId(3i64), apiId = CmsTestKit.apiId("title") | base } :: Nil;
    let data = CmsTestKit.entryData(List#{("profile", Json.JString("p1")), ("tags", Json.JArray(Vector#{Json.JString("t1"), Json.JString("bad id"), Json.JString("t2")})), ("title", Json.JString("p9"))});
    Assert.assertEq(expected = List#{(1i64, "p1", 0), (2i64, "t1", 0), (2i64, "t2", 2)},
        EntryLinks.extract(fields, data) |> List.map(link -> (FieldId.toInt64(link#field#id), EntryId.text(link#target), link#position)))
