///
/// FieldConfig: JSON との往復。
///
/// config は JSON と往復して元に戻る。None の項目はキー自体が出ない。
mod TestFieldConfig {

    use Util.Json.Json

    @Test
    def testFieldConfigRoundTrip(): Unit \ Assert =
        let config = { maxLength = Some(120), sourceField = Some(CmsTestKit.apiId("title")), min = None, max = Some(99.5), integer = Some(false), options = List#{"A", "B"} };
        let json = FieldConfig.toJson(config);
        let keys = match json {
            case Json.JObject(map) => Map.keysOf(map) |> Set.toList
            case _                 => bug!("FieldConfig.toJson は JObject を返すはず")
        };
        let back = FieldConfig.fromJson(json);
        Assert.assertEq(expected = (List#{"integer", "max", "maxLength", "options", "sourceField"}, Some(120), Some("title"), None, Some(99.5), Some(false), List#{"A", "B"}),
            (keys, back#maxLength, back#sourceField |> Option.map(ApiId.text), back#min, back#max, back#integer, back#options))

    /// 空の JSON、オブジェクトでない JSON、型の違う値、規則に合わない sourceField は全部 None になる（壊れた config で落ちない）。
    @Test
    def testFieldConfigLenient(): Unit \ Assert =
        let broken = Json.JObject(Map#{ "maxLength" => Json.JString("ten"), "sourceField" => Json.JString("Not Valid") });
        Assert.assertEq(expected = (None, None, None, None),
            (FieldConfig.fromJson(Json.JObject(Map.empty()))#maxLength,
             FieldConfig.fromJson(Json.JNull)#maxLength,
             FieldConfig.fromJson(broken)#maxLength,
             FieldConfig.fromJson(broken)#sourceField))

}
