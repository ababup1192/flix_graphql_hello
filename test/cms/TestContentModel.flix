use GeneratedAdmin.FieldKind
use GeneratedAdmin.TypeKind
use Util.Json.Json

///
/// ContentModel: kind の文字列と config の JSON の往復。
///


/// kind は DB の文字列と往復して元に戻る。
@Test
def testContentModelKindRoundTrip(): Unit \ Assert =
    let fieldKinds = List#{FieldKind.Text, FieldKind.TextArea, FieldKind.Slug, FieldKind.Number, FieldKind.Boolean};
    Assert.assertEq(expected = (List.map(Some, fieldKinds), Some(TypeKind.Collection), Some(TypeKind.Singleton), None),
        (List.map(kind -> ContentModel.fieldKindFromDb(ContentModel.fieldKindToDb(kind)), fieldKinds),
         ContentModel.typeKindFromDb(ContentModel.typeKindToDb(TypeKind.Collection)),
         ContentModel.typeKindFromDb(ContentModel.typeKindToDb(TypeKind.Singleton)),
         ContentModel.typeKindFromDb("folder")))

/// config は JSON と往復して元に戻る。None の項目はキー自体が出ない。
@Test
def testContentModelConfigRoundTrip(): Unit \ Assert =
    let config = { maxLength = Some(120), sourceField = Some("title"), min = None, max = Some(99.5), integer = Some(false) };
    let json = ContentModel.configToJson(config);
    let keys = match json {
        case Json.JObject(map) => Map.keysOf(map) |> Set.toList
        case _                 => Nil
    };
    Assert.assertEq(expected = (List#{"integer", "max", "maxLength", "sourceField"}, Some(120), Some("title"), None, Some(99.5), Some(false)),
        (keys,
         ContentModel.configFromJson(json)#maxLength,
         ContentModel.configFromJson(json)#sourceField,
         ContentModel.configFromJson(json)#min,
         ContentModel.configFromJson(json)#max,
         ContentModel.configFromJson(json)#integer))

/// 空の JSON、オブジェクトでない JSON、型の違う値は全部 None になる（壊れた config で落ちない）。
@Test
def testContentModelConfigLenient(): Unit \ Assert =
    let broken = Json.JObject(Map#{ "maxLength" => Json.JString("ten"), "sourceField" => Json.JNumber(Int32.toBigDecimal(1)) });
    Assert.assertEq(expected = (None, None, None),
        (ContentModel.configFromJson(Json.JObject(Map.empty()))#maxLength,
         ContentModel.configFromJson(Json.JNull)#maxLength,
         ContentModel.configFromJson(broken)#sourceField))

/// ID は DB の id と往復する。数字でない ID は None。
@Test
def testContentModelIds(): Unit \ Assert =
    Assert.assertEq(expected = (Some(42i64), None),
        (ContentModel.parseId(ContentModel.idOf(42i64)), ContentModel.parseId(Id.Id("xcmk3larl"))))
