///
/// ContentTypeRows: content_types / content_fields の行とドメインの値の往復。純粋（DbErr は Result に落として見る）。
///
/// 観点:
/// - 往復: Draft → INSERT の引数 → 行 → ContentType / FieldDef（kind の全 case、previewUrl の None ↔ ""、target / parent の None / Some、config）
/// - 境界: kind / apiId / singular / plural が規則の外なら DbErr。config は壊れていても落ちない
/// - UPDATE の Changes: Some の項目だけ SET に出る
///
mod TestContentTypeRows {

    use Util.Json.Json

    // ---- 部品 ----

    def at(millis: Int64): Timestamp.Timestamp = Timestamp.fromEpochMillis(millis)

    def allKinds(): List[FieldKind] =
        List#{FieldKind.Text, FieldKind.TextArea, FieldKind.Slug, FieldKind.Number, FieldKind.Boolean, FieldKind.Select, FieldKind.Reference, FieldKind.Object, FieldKind.Blocks, FieldKind.Asset, FieldKind.RichText, FieldKind.Date}

    /// 全項目を埋めた config。
    def fullConfig(): FieldConfig =
        { maxLength = Some(120), sourceField = Some(CmsTestKit.apiId("title")), min = Some(-1.5), max = Some(99.25), integer = Some(true), options = List#{"A", "B"} }

    def flattenConfig(config: FieldConfig): (Option[Int32], Option[ApiId], Option[Float64], Option[Float64], Option[Bool], List[String]) =
        (config#maxLength, config#sourceField, config#min, config#max, config#integer, config#options)

    def flattenType(found: ContentType): (TypeId, ApiId, TypeKind, String, TypeName, ApiId, Option[String], Int32, Timestamp.Timestamp, Timestamp.Timestamp) =
        (found#id, found#apiId, found#kind, found#name, found#singular, found#plural, found#previewUrl, List.length(found#fields), found#createdAt, found#updatedAt)

    def flattenField(field: FieldDef): (FieldId, TypeId, ApiId, String, FieldKind, Bool, Bool, Bool, Bool, Option[TypeId], Option[FieldId], Int32, (Option[Int32], Option[ApiId], Option[Float64], Option[Float64], Option[Bool], List[String])) =
        (field#id, field#typeId, field#apiId, field#name, field#kind, field#many, field#required, field#unique, field#localized, field#target, field#parent, field#position, flattenConfig(field#config))

    /// content_types の行。INSERT の引数に id と時刻を足す。
    def typeRow(names: Naming.TypeNames, draft: ContentTypeDraft): { id = Int64, apiId = String, kind = String, name = String, singular = String, plural = String, previewUrl = String, createdAt = Timestamp.Timestamp, updatedAt = Timestamp.Timestamp } =
        { +id = 5i64, +createdAt = at(1725000000123i64), +updatedAt = at(1725000000456i64) | ContentTypeRows.typeInsert(names, draft) }

    /// content_fields の行。INSERT の引数に id と、後追いの UPDATE で入る target / parent を足す。
    def fieldRow(draft: FieldDraft, position: Int32): { id = Int64, projectId = Int64, typeId = Int64, parentFieldId = Option[Int64], apiId = String, name = String, kind = String, isMany = Bool, isRequired = Bool, isUnique = Bool, isLocalized = Bool, targetTypeId = Option[Int64], config = Json, position = Int32 } =
        { +id = 11i64, +parentFieldId = draft#parent |> Option.map(FieldId.toInt64), +targetTypeId = draft#target |> Option.map(TypeId.toInt64)
          | Tenant.runWith(ProjectId.ProjectId(7i64), () -> ContentTypeRows.fieldInsert(TypeId.TypeId(5i64), position, draft)) }

    // ---- content_types ----

    /// Draft → typeInsert → 行 → ContentType で apiId / kind / 名前 / previewUrl / 時刻が同じ。previewUrl の None は列では "" で、読めば None に戻る。
    @Test
    def testContentTypeRoundTrip(): Unit \ Assert =
        let names = CmsTestKit.names("blog", "Blog", "blogs");
        let table = List#{(TypeKind.Collection, None), (TypeKind.Singleton, Some("https://example.com/preview/{id}"))};
        let expected = table |> List.map(match (kind, previewUrl) ->
            Ok((TypeId.TypeId(5i64), names#apiId, kind, "ブログ", names#singular, names#plural, previewUrl, 1, at(1725000000123i64), at(1725000000456i64))));
        Assert.assertEq(expected = expected,
            table |> List.map(match (kind, previewUrl) -> {
                let draft = { kind = kind, previewUrl = previewUrl | CmsTestKit.typeDraft("blog", "ブログ") };
                DbErr.runWithResult(() -> ContentTypeRows.toContentType(typeRow(names, draft), List#{CmsTestKit.fieldDef("title", FieldKind.Text)}) |> flattenType)
            }))

    /// 行の id は typeIdOf でも同じ物。
    @Test
    def testTypeIdOf(): Unit \ Assert =
        Assert.assertEq(expected = TypeId.TypeId(5i64), ContentTypeRows.typeIdOf(typeRow(CmsTestKit.names("blog", "Blog", "blogs"), CmsTestKit.typeDraft("blog", "ブログ"))))

    /// 知らない kind、規則外の apiId（UpperCamel）、singular（lowerCamel）、plural（UpperCamel）は DbErr。
    @Test
    def testToContentTypeRejects(): Unit \ Assert =
        let good = typeRow(CmsTestKit.names("blog", "Blog", "blogs"), CmsTestKit.typeDraft("blog", "ブログ"));
        let table = List#{
            { kind = "page" | good },
            { apiId = "Blog" | good },
            { singular = "blog" | good },
            { plural = "Blogs" | good }
        };
        Assert.assertEq(expected = List.repeat(List.length(table), true),
            table |> List.map(row -> DbErr.runWithResult(() -> ContentTypeRows.toContentType(row, Nil)) |> Result.isErr))

    // ---- content_fields ----

    /// 全 kind の Draft → fieldInsert → 行 → FieldDef で kind / 性質 / target / parent / config / position が同じ。projectId は Tenant から。
    @Test
    def testFieldDefRoundTrip(): Unit \ Assert =
        let drafts = allKinds() |> List.mapWithIndex((index, kind) ->
            { many = Int32.remainder(index, 2) == 0, required = index > 3, unique = index == 2, localized = index == 0,
              target = if (kind == FieldKind.Reference) Some(TypeId.TypeId(9i64)) else None,
              parent = if (index > 6) Some(FieldId.FieldId(3i64)) else None
              | CmsTestKit.fieldDraft("f${index}", kind, fullConfig()) });
        let expected = drafts |> List.mapWithIndex((index, draft) ->
            Ok((7i64, (FieldId.FieldId(11i64), TypeId.TypeId(5i64), draft#apiId, draft#name, draft#kind, draft#many, draft#required, draft#unique, draft#localized, draft#target, draft#parent, index, flattenConfig(fullConfig())))));
        Assert.assertEq(expected = expected,
            drafts |> List.mapWithIndex((index, draft) -> {
                let row = fieldRow(draft, index);
                DbErr.runWithResult(() -> (row#projectId, ContentTypeRows.toFieldDef(row) |> flattenField))
            }))

    /// 空の config は空のまま戻り、children は空。
    @Test
    def testFieldDefEmptyConfig(): Unit \ Assert =
        let row = fieldRow(CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()), 0);
        Assert.assertEq(expected = Ok((flattenConfig(FieldConfig.empty()), 0)),
            DbErr.runWithResult(() -> {
                let field = ContentTypeRows.toFieldDef(row);
                (flattenConfig(field#config), List.length(Children.toList(field#children)))
            }))

    /// 知らない kind と規則外の apiId は DbErr。config が壊れていても DbErr にはならない（項目が None に落ちるだけ）。
    @Test
    def testToFieldDefRejects(): Unit \ Assert =
        let good = fieldRow(CmsTestKit.fieldDraft("title", FieldKind.Text, fullConfig()), 0);
        Assert.assertEq(expected = (true, true, Ok(None)),
            (DbErr.runWithResult(() -> ContentTypeRows.toFieldDef({ kind = "markdown" | good })) |> Result.isErr,
             DbErr.runWithResult(() -> ContentTypeRows.toFieldDef({ apiId = "Title" | good })) |> Result.isErr,
             DbErr.runWithResult(() -> ContentTypeRows.toFieldDef({ config = Json.JString("broken") | good })#config#maxLength)))

    // ---- UPDATE の Changes ----

    /// 型の変更は Some の列だけが SET に出て、順番は name / singular / plural / preview_url。全部 None なら空。
    @Test
    def testTypeChangesSql(): Unit \ Assert =
        let all = { name = Some("N"), singular = Some(CmsTestKit.typeName("Post")), plural = Some(CmsTestKit.apiId("posts")), previewUrl = Some("") };
        let some = { name = None, singular = None, plural = Some(CmsTestKit.apiId("posts")), previewUrl = None };
        let none = { name = None, singular = None, plural = None, previewUrl = None };
        Assert.assertEq(expected = (("name = $1, singular = $2, plural = $3, preview_url = $4", List#{SqlValue.Str("N"), SqlValue.Str("Post"), SqlValue.Str("posts"), SqlValue.Str("")}),
                                    ("plural = $1", List#{SqlValue.Str("posts")}),
                                    true),
            (Fragment.appendChanges(ContentTypeRows.typeChanges(all), Nil),
             Fragment.appendChanges(ContentTypeRows.typeChanges(some), Nil),
             Fragment.isEmptyChanges(ContentTypeRows.typeChanges(none))))

    /// フィールドの変更は Some の列だけが SET に出て、config は JSON 1 つで丸ごと置く。全部 None なら空。
    @Test
    def testFieldChangesSql(): Unit \ Assert =
        let all = { name = Some("N"), required = Some(true), unique = Some(false), localized = Some(true), config = Some(FieldConfig.empty()) };
        let none = { name = None, required = None, unique = None, localized = None, config = None };
        Assert.assertEq(expected = (("name = $1, is_required = $2, is_unique = $3, is_localized = $4, config = $5", List#{SqlValue.Str("N"), SqlValue.Bool(true), SqlValue.Bool(false), SqlValue.Bool(true), SqlValue.Json("{}")}), true),
            (Fragment.appendChanges(ContentTypeRows.fieldChanges(all), Nil),
             Fragment.isEmptyChanges(ContentTypeRows.fieldChanges(none))))

}
