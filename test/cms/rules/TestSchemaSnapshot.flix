///
/// SchemaSnapshot: 変更前のスキーマを JSON にし、足し直す下書きに戻す。純粋。
///
/// 見るのは往復。消したフィールドの JSON から下書きが元通り作れれば、監査に残した物で戻せる。
///
mod TestSchemaSnapshot {

    use Util.Json.Json

    // ---- 部品 ----

    /// 参照先の型 id ↔ apiId。target を apiId で残すのに要る。
    def names(): Map[TypeId, ApiId] = Map#{ TypeId.TypeId(2i64) => CmsTestKit.apiId("tags") }

    def ids(): Map[ApiId, TypeId] = Map#{ CmsTestKit.apiId("tags") => TypeId.TypeId(2i64) }

    def field(api: String, kind: FieldKind): FieldDef =
        { id = FieldId.FieldId(10i64) | CmsTestKit.fieldDef(api, kind) }

    /// tags を参照するフィールド。
    def reference(api: String): FieldDef =
        { target = Some(TypeId.TypeId(2i64)) | field(api, FieldKind.Reference) }

    /// 選択肢を持つ SELECT（select は Flix の予約語なので withOptions）。
    def withOptions(api: String, options: List[String]): FieldDef =
        { config = { options = options | FieldConfig.empty() } | field(api, FieldKind.Select) }

    /// 子を持つ OBJECT。
    def object(api: String, children: List[FieldDef]): FieldDef =
        { children = Children.Children(children) | field(api, FieldKind.Object) }

    ///
    /// 下書きを見分けの付く 1 行に。FieldDraft は record なので Eq を持てない。
    ///
    def label(draft: FieldDraft): String =
        let target = draft#target |> Option.map(id -> "${TypeId.toInt64(id)}") |> Option.getWithDefault("-");
        "${ApiId.text(draft#apiId)} ${draft#name} ${draft#kind} ${draft#many}${draft#required}${draft#unique}${draft#localized} ${target} ${Util.Json.toCompactString(FieldConfig.toJson(draft#config))}"

    /// JSON にしてから下書きに戻し、1 行にする。
    def roundTrip(source: FieldDef): Option[String] =
        SchemaSnapshot.toDraft(ids(), SchemaSnapshot.ofField(names(), source)) |> Option.map(label)

    /// 元のフィールドを下書きの 1 行にする（往復の期待）。
    def expectedOf(source: FieldDef): Option[String] = Some(label(SchemaSnapshot.draftOf(source)))

    /// JSON の項目を引く。
    def get(key: String, json: Json): Option[Json] = match json {
        case Json.JObject(map) => Map.get(key, map)
        case _                 => None
    }

    // ---- 往復 ----

    ///
    /// 素のフィールドと、性質を全部立てたフィールドが往復する。
    ///
    @Test
    def testSnapshotRoundTripsPlainField(): Unit \ Assert =
        let flagged = { many = true, required = true, unique = true, localized = true | field("title", FieldKind.Text) };
        let sources = List#{field("title", FieldKind.Text), flagged, field("body", FieldKind.RichText), field("cover", FieldKind.Asset)};
        Assert.assertEq(expected = sources |> List.map(expectedOf), sources |> List.map(roundTrip))

    ///
    /// 参照先は apiId で残り、戻すと型 id に解ける。
    ///
    @Test
    def testSnapshotRoundTripsReference(): Unit \ Assert =
        Assert.assertEq(expected = expectedOf(reference("tag")), roundTrip(reference("tag")))

    ///
    /// config（選択肢・上限）が往復する。
    ///
    @Test
    def testSnapshotRoundTripsConfig(): Unit \ Assert =
        let capped = { config = { maxLength = Some(120) | FieldConfig.empty() } | field("title", FieldKind.Text) };
        let sources = List#{withOptions("status", List#{"DRAFT", "LIVE"}), capped};
        Assert.assertEq(expected = sources |> List.map(expectedOf), sources |> List.map(roundTrip))

    ///
    /// 入れ子も、木を平らにした 1 本ずつが往復する。親を消すと子も消えるので、子まで残っていないと戻せない。
    ///
    @Test
    def testSnapshotRoundTripsNestedFields(): Unit \ Assert =
        let tree = object("seo", List#{field("title", FieldKind.Text), object("og", List#{field("image", FieldKind.Asset)})});
        let snapshot = SchemaSnapshot.ofField(names(), tree);
        // JSON 側も同じ深さで辿れる
        let nested = get("children", snapshot) |> Option.flatMap(json -> match json {
            case Json.JArray(kids) => Vector.head(kids)
            case _                 => None
        });
        Assert.assertEq(
            expected = (4, expectedOf(field("title", FieldKind.Text))),
            (List.length(FieldTree.flatten(tree :: Nil)),
             nested |> Option.flatMap(json -> SchemaSnapshot.toDraft(ids(), json)) |> Option.map(label)))

    ///
    /// apiId や kind が読めない JSON は戻せない（None）。
    ///
    @Test
    def testSnapshotRefusesBrokenJson(): Unit \ Assert =
        let broken = List#{
            Json.JObject(Map#{ "kind" => Json.JString("text") }),
            Json.JObject(Map#{ "apiId" => Json.JString("title"), "kind" => Json.JString("unknown") }),
            Json.JString("title")
        };
        Assert.assertEq(expected = List#{None, None, None}, broken |> List.map(json -> SchemaSnapshot.toDraft(ids(), json) |> Option.map(label)))

    // ---- 型 ----

    ///
    /// 型の見出しにはフィールドが入らない。消した時の形には全部入る。
    ///
    @Test
    def testSnapshotOfTypeCarriesFieldsOnlyWhenDeleted(): Unit \ Assert =
        let blogs = CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", List#{field("title", FieldKind.Text)});
        Assert.assertEq(
            expected = (None, Some(1)),
            (get("fields", SchemaSnapshot.ofType(blogs)),
             get("fields", SchemaSnapshot.ofTypeWithFields(names(), blogs)) |> Option.flatMap(json -> match json {
                 case Json.JArray(fields) => Some(Vector.length(fields))
                 case _                   => None
             })))

    ///
    /// 並べ替えの前の並びは apiId の列で残る。
    ///
    @Test
    def testSnapshotOfOrderKeepsApiIds(): Unit \ Assert =
        let fields = List#{field("title", FieldKind.Text), field("body", FieldKind.Text)};
        Assert.assertEq(
            expected = Some(Json.JArray(Vector#{Json.JString("title"), Json.JString("body")})),
            get("fields", SchemaSnapshot.ofOrder(fields)))

}
