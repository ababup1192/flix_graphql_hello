///
/// EntryValue: 中身の JSON の読み方。形が違う物は黙って無い事にする。純粋。
///
mod TestEntryValue {

    use Util.Json.Json

    ///
    /// sections: blocks[hero{headline}]。
    ///
    def sections(): FieldDef =
        { many = true, children = Children.Children({ children = Children.Children(CmsTestKit.fieldDef("headline", FieldKind.Text) :: Nil) | CmsTestKit.fieldDef("hero", FieldKind.Object) } :: Nil) | CmsTestKit.fieldDef("sections", FieldKind.Blocks) }

    /// text / number / bool は形が違えば None、配列版は配列でない値なら空、読めない要素は捨てる。無いフィールドも同じ。
    @Test
    def testEntryValueScalars(): Unit \ Assert =
        let data = CmsTestKit.entryData(List#{
            ("title", Json.JString("t")),
            ("views", CmsTestKit.intJson(3)),
            ("flag", Json.JBool(true)),
            ("tags", Json.JArray(Vector#{Json.JString("a"), CmsTestKit.intJson(1), Json.JString("b")})),
            ("scores", Json.JArray(Vector#{CmsTestKit.intJson(1), Json.JString("x")})),
            ("flags", Json.JString("not an array"))
        });
        let id = CmsTestKit.apiId;
        Assert.assertEq(expected = (Some("t"), None, Some(3.0), Some(true), None, List#{"a", "b"}, List#{1.0}, Nil, Nil),
            (EntryValue.text(id("title"), data), EntryValue.text(id("views"), data),
             EntryValue.number(id("views"), data), EntryValue.bool(id("flag"), data), EntryValue.bool(id("missing"), data),
             EntryValue.texts(id("tags"), data), EntryValue.numbers(id("scores"), data), EntryValue.bools(id("flags"), data), EntryValue.texts(id("missing"), data)))

    /// objects はオブジェクトでない要素を捨て、objectData は apiId の規則に合わないキーを落とす。
    @Test
    def testEntryValueObjects(): Unit \ Assert =
        let data = CmsTestKit.entryData(List#{("related", Json.JArray(Vector#{Json.JObject(Map#{ "label" => Json.JString("a"), "Bad Key" => Json.JString("x") }), Json.JString("not an object")}))});
        Assert.assertEq(expected = List#{List#{"label"}},
            EntryValue.objects(CmsTestKit.apiId("related"), data) |> List.map(inner -> Map.keysOf(inner) |> Set.toList |> List.map(ApiId.text)))

    /// blocks は blockType で variant を選び、中身から blockType を除く。知らない blockType と非オブジェクトは捨てる。
    @Test
    def testEntryValueBlocks(): Unit \ Assert =
        let data = CmsTestKit.entryData(List#{("sections", Json.JArray(Vector#{
            Json.JObject(Map#{ "blockType" => Json.JString("hero"), "headline" => Json.JString("Hi") }),
            Json.JObject(Map#{ "blockType" => Json.JString("nope") }),
            Json.JString("x")}))});
        Assert.assertEq(expected = List#{("hero", List#{"headline"})},
            EntryValue.blocks(sections(), data) |> List.map(match (variant, inner) -> (ApiId.text(variant#apiId), Map.keysOf(inner) |> Set.toList |> List.map(ApiId.text))))

    /// 位置付きの読み取りは元の番号を保つ（読めない要素を飛ばしても詰めない）。配列でなければ空。
    @Test
    def testEntryValueItemsWithIndex(): Unit \ Assert =
        Assert.assertEq(expected = (List#{(0, "a"), (2, "c")}, Nil),
            (EntryValue.itemsWithIndex(EntryValue.asString, Json.JArray(Vector#{Json.JString("a"), CmsTestKit.intJson(1), Json.JString("c")})),
             EntryValue.itemsWithIndex(EntryValue.asString, Json.JString("a"))))

}
