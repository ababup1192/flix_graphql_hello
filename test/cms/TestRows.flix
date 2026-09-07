///
/// 行とドメインの値のあいだの変換。kind / stage / reason の文字列の往復と、規則外の値の扱い。純粋（DbErr は結果に落として見る）。
///
mod TestRows {

    use Util.Json.Json

    /// FieldKind と TypeKind は DB の文字列と往復し、知らない文字列は None。
    @Test
    def testRowsKindRoundTrip(): Unit \ Assert =
        let kinds = List#{FieldKind.Text, FieldKind.TextArea, FieldKind.Slug, FieldKind.Number, FieldKind.Boolean, FieldKind.Select, FieldKind.Reference, FieldKind.Object, FieldKind.Blocks};
        Assert.assertEq(expected = (List.map(Some, kinds), None, Some(TypeKind.Singleton), None),
            (kinds |> List.map(kind -> ContentTypeRows.fieldKindFromDb(ContentTypeRows.fieldKindToDb(kind))),
             ContentTypeRows.fieldKindFromDb("richText"),
             ContentTypeRows.typeKindFromDb(ContentTypeRows.typeKindToDb(TypeKind.Singleton)),
             ContentTypeRows.typeKindFromDb("page")))

    /// Stage と VersionReason も同じく往復し、知らない文字列は None。
    @Test
    def testRowsStageAndReasonRoundTrip(): Unit \ Assert =
        Assert.assertEq(expected = (Some(Stage.Published), Some(Stage.Draft), None, Some(VersionReason.Save), Some(VersionReason.Publish), None),
            (EntryRows.stageFromDb(EntryRows.stageToDb(Stage.Published)),
             EntryRows.stageFromDb(EntryRows.stageToDb(Stage.Draft)),
             EntryRows.stageFromDb("archived"),
             EntryRows.reasonFromDb(EntryRows.reasonToDb(VersionReason.Save)),
             EntryRows.reasonFromDb(EntryRows.reasonToDb(VersionReason.Publish)),
             EntryRows.reasonFromDb("restore")))

    /// count と position の行は無ければ 0。RETURNING の行が無い、値が読めない、は DbErr（結果の Err）になる。
    @Test
    def testRowsMissing(): Unit \ {Assert, IO} =
        let noIdRow: Option[{ id = Int64 }] = None;
        let noStage: Option[Stage] = None;
        Assert.assertEq(expected = (0i64, 7i64, 0, 3, true, true, Ok("ok")),
            (Rows.total(None), Rows.total(Some({ total = Some(7i64) })),
             Rows.nextPosition(None), Rows.nextPosition(Some({ next = Some(3) })),
             DbError.runWithFailure(() -> Rows.expectId(noIdRow)) |> Result.isErr,
             DbError.runWithFailure(() -> Rows.orRaise("entries.stage", "archived", noStage)) |> Result.isErr,
             DbError.runWithFailure(() -> Rows.orRaise("entries.stage", "ok", Some("ok")))))

}
