///
/// 監査に残した変更前の姿から、消したフィールドと型を組み直せるかを実 PostgreSQL で見る。
///
/// 「押した後に戻せるか」の答えがここ。SchemaSnapshot の往復は純粋なテストが見ているので、
/// ここが見るのは DB を通した時に同じ物が返るか——detail に入って戻ってきた JSON で addField が通るか。
///
mod TestSchemaRestorePg {

    use Util.Json.Json

    /// 監査の detail から変更前の姿を取り出す。
    def beforeOf(detail: Json): Option[Json] = match detail {
        case Json.JObject(map) => Map.get("before", map)
        case _                 => None
    }

    /// action で監査を 1 行引き、変更前の姿を返す。
    def recorded(action: String): Option[Json] \ DbRead + CmsErr + Tenant + Session =
        Audit.latest(Session.grant(), 50i64)
            |> List.filter(found -> found#action == action)
            |> List.head
            |> Option.flatMap(found -> beforeOf(found#detail))

    /// apiId → 型 id。参照先を解くのに要る。
    def idsByApiId(): Map[ApiId, TypeId] \ DbRead + CmsErr + Tenant + Session =
        ContentTypes.list(Session.grant()) |> List.map(owner -> (owner#apiId, owner#id)) |> List.toMap

    /// フィールドを見分けの付く 1 行に。FieldDef は record なので Eq を持てない。
    def label(field: FieldDef): String =
        let target = field#target |> Option.map(id -> "${TypeId.toInt64(id)}") |> Option.getWithDefault("-");
        "${ApiId.text(field#apiId)} ${field#name} ${field#kind} ${field#many}${field#required}${field#unique}${field#localized} ${target} ${Util.Json.toCompactString(FieldConfig.toJson(field#config))}"

    /// 残した姿でフィールドを足し直す。
    def restore(typeId: TypeId, was: Json): Option[FieldDef] \ Db + CmsErr + IdGen + Tenant + Session =
        SchemaSnapshot.toDraft(idsByApiId(), was) |> Option.map(draft -> ContentTypes.addField(Session.grant(), typeId, draft))

    ///
    /// 選択肢と上限を持つフィールドを消し、監査に残った姿で足し直すと同じ定義に戻る。
    ///
    @Test
    def testPgRemovedFieldRestoresFromAudit(): Unit \ {IO, Assert} =
        let config = { maxLength = None, sourceField = None, min = None, max = None, integer = None, options = List#{"DRAFT", "LIVE"} };
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            let draft = { many = true, localized = true | CmsTestKit.fieldDraft("status", FieldKind.Select, config) };
            let before = ContentTypes.addField(Session.grant(), blogs#id, draft);
            ContentTypes.removeField(Session.grant(), before#id);
            let restored = recorded("field.removed") |> Option.flatMap(was -> restore(blogs#id, was));
            (label(before), restored |> Option.map(label))
        });
        Assert.assertEq(expected = Ok(Ok((
            "status status Select truefalsefalsetrue - {\"options\":[\"DRAFT\",\"LIVE\"]}",
            Some("status status Select truefalsefalsetrue - {\"options\":[\"DRAFT\",\"LIVE\"]}")))), result)

    ///
    /// 参照するフィールドは、参照先を apiId で残しているので足し直しても同じ型を指す。
    ///
    @Test
    def testPgRemovedReferenceRestoresTarget(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let tags = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("tags", "タグ"));
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            let draft = { target = Some(tags#id) | CmsTestKit.fieldDraft("tag", FieldKind.Reference, FieldConfig.empty()) };
            let before = ContentTypes.addField(Session.grant(), blogs#id, draft);
            ContentTypes.removeField(Session.grant(), before#id);
            let restored = recorded("field.removed") |> Option.flatMap(was -> restore(blogs#id, was));
            (Some(tags#id), restored |> Option.flatMap(field -> field#target))
        });
        Assert.assertEq(expected = true, result |> Result.map(inner -> inner |> Result.map(match (expected, actual) -> expected == actual)) == Ok(Ok(true)))

    ///
    /// 型を消すと、監査には型の見出しとフィールド全部が残る。子を持つフィールドも子ごと残る。
    ///
    @Test
    def testPgDeletedTypeKeepsEveryField(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            let seo = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("seo", FieldKind.Object, FieldConfig.empty()));
            discard ContentTypes.addField(Session.grant(), blogs#id, { parent = Some(seo#id) | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
            ContentTypes.delete(Session.grant(), blogs#id);
            recorded("type.deleted") |> Option.map(Util.Json.toCompactString)
        });
        Assert.assertEq(
            expected = Ok(Ok(Some("{\"apiId\":\"blogs\",\"fields\":[{\"apiId\":\"seo\",\"children\":[{\"apiId\":\"title\",\"config\":{},\"kind\":\"text\",\"localized\":false,\"many\":false,\"name\":\"title\",\"required\":false,\"unique\":false}],\"config\":{},\"kind\":\"object\",\"localized\":false,\"many\":false,\"name\":\"seo\",\"required\":false,\"unique\":false}],\"icon\":\"list\",\"kind\":\"collection\",\"name\":\"記事\",\"plural\":\"blogs\",\"singular\":\"Blog\"}"))),
            result)

    ///
    /// 直した時は変更前の姿が残る。config を上書きしても、消えた選択肢が監査から読める。
    ///
    @Test
    def testPgUpdatedFieldKeepsOldConfig(): Unit \ {IO, Assert} =
        let wide = { maxLength = None, sourceField = None, min = None, max = None, integer = None, options = List#{"DRAFT", "LIVE", "ARCHIVED"} };
        let narrow = { options = List#{"DRAFT"} | wide };
        let result = PgTestSupport.withDb(() -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            let status = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("status", FieldKind.Select, wide));
            discard ContentTypes.updateField(Session.grant(), status#id, { name = None, required = None, unique = None, localized = None, config = Some(narrow) });
            recorded("field.updated")
                |> Option.flatMap(was -> SchemaSnapshot.toDraft(idsByApiId(), was))
                |> Option.map(draft -> draft#config#options)
        });
        Assert.assertEq(expected = Ok(Ok(Some(List#{"DRAFT", "LIVE", "ARCHIVED"}))), result)

}
