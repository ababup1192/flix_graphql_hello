///
/// entry の中身から asset の参照を取り出す。ASSET の単数・配列、RICH_TEXT の image と gallery の中の image、OBJECT の中。
///
mod TestAssetRefs {

    use Util.Json.Json

    def image(assetId: String): Json =
        Json.JObject(Map#{ "type" => Json.JString("image"), "attrs" => Json.JObject(Map#{ "assetId" => Json.JString(assetId) }) })

    ///
    ///   cover: ASSET            = "a1"
    ///   gallery: ASSET (many)   = ["a2", "bad id!", "a1"]
    ///   body: RICH_TEXT         = doc [ image a3, gallery [ image a5, image a3 ] ]
    ///   related: OBJECT { thumb: ASSET = "a4" }
    ///
    @Test
    def testExtract(): Unit \ Assert =
        let fields = List#{
            CmsTestKit.fieldDef("cover", FieldKind.Asset),
            { many = true | CmsTestKit.fieldDef("gallery", FieldKind.Asset) },
            CmsTestKit.fieldDef("body", FieldKind.RichText),
            { children = Children.Children(CmsTestKit.fieldDef("thumb", FieldKind.Asset) :: Nil) | CmsTestKit.fieldDef("related", FieldKind.Object) }
        };
        let data = CmsTestKit.entryData(List#{
            ("cover", Json.JString("a1")),
            ("gallery", Json.JArray(Vector#{ Json.JString("a2"), Json.JString("bad id!"), Json.JString("a1") })),
            ("body", Json.JObject(Map#{ "type" => Json.JString("doc"), "content" => Json.JArray(Vector#{
                image("a3"),
                Json.JObject(Map#{ "type" => Json.JString("gallery"), "content" => Json.JArray(Vector#{ image("a5"), image("a3") }) }) }) })),
            ("related", Json.JObject(Map#{ "thumb" => Json.JString("a4") }))
        });
        Assert.assertEq(expected = List#{ "a1", "a2", "a3", "a5", "a4" }, AssetRefs.extract(fields, data) |> List.map(AssetId.text))

}
