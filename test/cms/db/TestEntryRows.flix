///
/// EntryRows: entries / entry_contents / entry_versions / entry_links の行とドメインの値の往復。純粋（DbErr は Result に落として見る）。
///
/// 観点:
/// - 往復: EntryData ↔ JSONB（ネスト・配列・null・Unicode・空文字・空の Map）、Entry → 行 → Entry、Entry → versionInsert → toVersion
/// - 境界: stage / reason / id / data が規則の外なら DbErr（既定値に落とさない）
///
mod TestEntryRows {

    use Util.Json.Json

    // ---- 部品 ----

    /// ms まで持つ時刻。マイクロ秒の列に ms が丸められずに残る事を見る。
    def at(millis: Int64): Timestamp.Timestamp = Timestamp.fromEpochMillis(millis)

    def text(s: String): Json = Json.JString(s)

    def obj(pairs: List[(String, Json)]): Json = Json.JObject(List.toMap(pairs))

    def arr(items: List[Json]): Json = Json.JArray(List.toVector(items))

    /// 入れ子・配列・null・Unicode・空文字を全部含む中身。
    def richData(): EntryData =
        CmsTestKit.entryData(List#{
            ("title", text("こんにちは 🌏")),
            ("empty", text("")),
            ("nothing", Json.JNull),
            ("count", CmsTestKit.intJson(3)),
            ("flag", Json.JBool(true)),
            ("tags", arr(List#{text("a"), text(""), Json.JNull})),
            ("author", obj(List#{("name", text("山田")), ("links", arr(List#{obj(List#{("url", text("https://example.com/?q=日本"))})}))})),
            ("blocks", arr(List#{obj(List#{("blockType", text("hero")), ("body", obj(Nil))}), obj(Nil)}))
        })

    /// Entry の値。表の行にする側の元。
    def entry(stage: Stage, data: EntryData): Entry =
        { id = CmsTestKit.entryId("post-01_A"), typeId = TypeId.TypeId(42i64), version = 7, stage = stage, data = data,
          publishedAt = Some(at(1725000000123i64)), changedSincePublish = false, contentStage = stage, linked = Linked.empty(),
          createdAt = at(1725000000001i64), updatedAt = at(1725000000999i64) }

    /// Entry を entries ⋈ entry_contents の行に。published の行の中身は別に渡す。
    def rowOf(source: Entry, publishedData: Option[EntryData]): { id = String, typeId = Int64, version = Int32, stage = String, publishedAt = Option[Timestamp.Timestamp], createdAt = Timestamp.Timestamp, updatedAt = Timestamp.Timestamp, data = Json, publishedData = Option[Json] } =
        { id = EntryId.text(source#id), typeId = TypeId.toInt64(source#typeId), version = source#version, stage = EntryRows.stageToDb(source#stage),
          publishedAt = source#publishedAt, createdAt = source#createdAt, updatedAt = source#updatedAt,
          data = EntryRows.dataToJson(source#data), publishedData = publishedData |> Option.map(EntryRows.dataToJson) }

    /// 比べる為に Entry を組（レコードは Eq を持たない）に開く。
    def flatten(source: Entry): (EntryId, TypeId, Int32, Stage, EntryData, Option[Timestamp.Timestamp], Bool, Stage, Timestamp.Timestamp, Timestamp.Timestamp) =
        (source#id, source#typeId, source#version, source#stage, source#data, source#publishedAt, source#changedSincePublish, source#contentStage, source#createdAt, source#updatedAt)

    def flattenVersion(version: EntryVersion): (VersionId, EntryId, Int32, EntryData, String, VersionReason, Timestamp.Timestamp) =
        (version#id, version#entryId, version#version, version#data, version#author, version#reason, version#createdAt)

    // ---- JSONB（EntryData） ----

    /// EntryData は JSON と往復して同じ値に戻る。空の Map、入れ子、配列、null、Unicode、空文字。
    @Test
    def testEntryDataJsonRoundTrip(): Unit \ Assert =
        let table = List#{
            Map.empty(),
            CmsTestKit.entryData(List#{("title", text(""))}),
            CmsTestKit.entryData(List#{("body", Json.JNull)}),
            CmsTestKit.entryData(List#{("nested", obj(List#{("deep", obj(List#{("deeper", arr(List#{obj(Nil), arr(Nil)}))}))}))}),
            richData()
        };
        Assert.assertEq(expected = List.map(Ok, table),
            table |> List.map(data -> DbErr.runWithResult(() -> EntryRows.dataFromJson(EntryRows.dataToJson(data)))))

    /// 書き出す JSON のキーは apiId の文字列で、値はそのまま。
    @Test
    def testEntryDataToJsonShape(): Unit \ Assert =
        Assert.assertEq(expected = obj(List#{("title", text("t")), ("tags", arr(List#{text("x")}))}),
            EntryRows.dataToJson(CmsTestKit.entryData(List#{("title", text("t")), ("tags", arr(List#{text("x")}))})))

    /// オブジェクトでない JSON と、apiId の規則に合わないキー（大文字始まり・空・記号）は DbErr。
    @Test
    def testEntryDataFromJsonRejects(): Unit \ Assert =
        let table = List#{
            Json.JNull,
            arr(Nil),
            text("{}"),
            obj(List#{("Title", text("t"))}),
            obj(List#{("", text("t"))}),
            obj(List#{("api-id", text("t"))}),
            obj(List#{("ok", text("t")), ("9lives", text("t"))})
        };
        Assert.assertEq(expected = List.repeat(List.length(table), true),
            table |> List.map(json -> DbErr.runWithResult(() -> EntryRows.dataFromJson(json)) |> Result.isErr))

    // ---- entries の行 ↔ Entry ----

    /// Entry → 行 → Entry で id / 版 / stage / 中身 / 時刻（ms）が同じ。
    /// changedSincePublish は「published で、published の行の中身と違う」時だけ true（published の行が無いのも違う扱い）。
    @Test
    def testToEntryRoundTrip(): Unit \ Assert =
        let table = List#{
            (Stage.Draft, None, false),
            (Stage.Draft, Some(Map.empty()), false),
            (Stage.Published, Some(richData()), false),
            (Stage.Published, Some(Map.empty()), true),
            (Stage.Published, None, true)
        };
        let expected = table |> List.map(match (stage, _, changed) -> Ok(flatten({ changedSincePublish = changed | entry(stage, richData()) })));
        Assert.assertEq(expected = expected,
            table |> List.map(match (stage, publishedData, _) -> DbErr.runWithResult(() -> EntryRows.toEntry(stage, rowOf(entry(stage, richData()), publishedData)) |> flatten)))

    /// 知らない stage、規則外の id、オブジェクトでない data、キーが規則外の published の行は DbErr。
    @Test
    def testToEntryRejects(): Unit \ Assert =
        let good = rowOf(entry(Stage.Published, richData()), Some(richData()));
        let table = List#{
            { stage = "archived" | good },
            { id = "has space" | good },
            { id = "" | good },
            { data = Json.JNull | good },
            { publishedData = Some(obj(List#{("Bad", text(""))})) | good }
        };
        Assert.assertEq(expected = List.repeat(List.length(table), true),
            table |> List.map(row -> DbErr.runWithResult(() -> EntryRows.toEntry(Stage.Published, row)) |> Result.isErr))

    // ---- entry_versions ----

    /// Entry → versionInsert の引数 → 行 → EntryVersion で、entry id / 版 / 中身 / author / reason が同じ。projectId は Tenant から。
    @Test
    def testVersionRoundTrip(): Unit \ Assert =
        let source = entry(Stage.Draft, richData());
        let table = List#{(VersionReason.Publish, "alice"), (VersionReason.Save, "")};
        let expected = table |> List.map(match (reason, author) ->
            Ok((7i64, (VersionId.VersionId(99i64), source#id, 7, richData(), author, reason, at(1725000000123i64)))));
        Assert.assertEq(expected = expected,
            table |> List.map(match (reason, author) -> {
                let insert = Tenant.runWith(ProjectId.ProjectId(7i64), () -> EntryRows.versionInsert(source, author, reason));
                DbErr.runWithResult(() -> (insert#projectId, EntryRows.toVersion({ +id = 99i64, +createdAt = at(1725000000123i64) | insert }) |> flattenVersion))
            }))

    /// 知らない reason、規則外の entry id、オブジェクトでない data は DbErr。
    @Test
    def testToVersionRejects(): Unit \ Assert =
        let good = { id = 1i64, entryId = "post-01", version = 1, data = obj(Nil), author = "a", reason = "save", createdAt = at(0i64) };
        let table = List#{
            { reason = "restore" | good },
            { entryId = "post 01" | good },
            { data = arr(Nil) | good }
        };
        Assert.assertEq(expected = List.repeat(List.length(table), true),
            table |> List.map(row -> DbErr.runWithResult(() -> EntryRows.toVersion(row)) |> Result.isErr))

    // ---- entry_links ----

    /// 参照先は規則に合えば Some、合わなければ None。参照元の文字列はそのまま。
    @Test
    def testLinkRows(): Unit \ Assert =
        Assert.assertEq(expected = (Some(CmsTestKit.entryId("target-1")), None, "from-1"),
            (EntryRows.toTargetId({ toEntryId = "target-1" }),
             EntryRows.toTargetId({ toEntryId = "target 1" }),
             EntryRows.referrerText({ fromEntryId = "from-1" })))

}
