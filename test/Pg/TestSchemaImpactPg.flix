///
/// スキーマの変更に当たる entry の数え上げを実 PostgreSQL で見る。
///
/// 「値がある」の定義は EntryValidation.hasValue が持ち、SQL（SchemaCounts.pathOf の jsonpath）は
/// その写し。**写しがずれていないかをここで突き合わせる。** 種類を並べるのではなく、
/// 同じ中身に対して規則と SQL が同じ数を出す事を見るので、思いついていない形でも落ちる。
///
mod TestSchemaImpactPg {

    use Util.Json.Json

    ///
    /// 「値がある」かどうかが分かれる中身の見本。(apiId, 種類, 配列か, 値)。
    /// 種類は値に合わせる（中身の検査に引っかかると、数え上げとは別の理由で違反が出てしまう）。
    ///
    def samples(): List[(String, FieldKind, Bool, Json)] =
        List#{
            ("text",        FieldKind.Text,    false, Json.JString("x")),
            ("empty",       FieldKind.Text,    false, Json.JString("")),
            ("zero",        FieldKind.Number,  false, CmsTestKit.intJson(0)),
            ("flagFalse",   FieldKind.Boolean, false, Json.JBool(false)),
            ("emptyArray",  FieldKind.Text,    true,  Json.JArray(Vector#{})),
            ("filledArray", FieldKind.Text,    true,  Json.JArray(Vector#{Json.JString("a")})),
            ("emptyObject", FieldKind.Object,  false, Json.JObject(Map#{}))
        }

    def sampleData(): EntryData =
        CmsTestKit.entryData(samples() |> List.map(match (api, _, _, value) -> (api, value)))

    ///
    /// 見本の値を 1 つずつ持つ entry を作る。返すのは型の id。
    ///
    def seedSamples(): TypeId \ Db + CmsErr + Tenant + IdGen + Session =
        let probes = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("probes", "見本"));
        samples() |> List.forEach(match (api, kind, many, _) ->
            discard ContentTypes.addField(Session.grant(), probes#id, { many = many | CmsTestKit.fieldDraft(api, kind, FieldConfig.empty()) }));
        discard ContentEntries.create(Session.grant(), probes#id, Some(CmsTestKit.entryId("p1")), sampleData());
        probes#id

    ///
    /// 規則が「値がある」と言うフィールドの apiId。
    ///
    /// 全部 required にして公開の検査を通し、「公開には値が要ります」が出なかった物が値のある物。
    /// hasValue を直に呼ばないのは非 pub のため（公開されている口で確かめる方が写しの相手として正しい）。
    ///
    def byRule(): List[String] =
        let fields = samples() |> List.map(match (api, kind, many, _) ->
            { required = true, many = many | CmsTestKit.fieldDef(api, kind) });
        let missing = EntryValidation.publish(fields, sampleData()) |> CmsTestKit.violationPaths;
        samples() |> List.filterMap(match (api, _, _, _) ->
            if (List.memberOf("fields.${api}", missing)) None else Some(api))

    ///
    /// SQL が「値がある」と数えるフィールドと、EntryValidation が言うフィールドが一致する。
    ///
    /// ここがずれると、押す前に「0 件」と出た後で公開や保存が落ちる。
    ///
    @Test
    def testPgCountMatchesHasValue(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"p1"}, () -> {
            let probes = seedSamples();
            let owner = ContentTypes.get(Session.grant(), probes);
            let counted = owner#fields |> List.filterMap(field -> {
                let (fields, _) = SchemaCounts.forChanges(List#{SchemaChange.FieldRemoved(field)});
                match List.head(fields) {
                    case Some(count) => if (count#draft#total > 0i64) Some(ApiId.text(field#apiId)) else None
                    case None        => None
                }
            });
            List.sort(counted)
        }));
        Assert.assertEq(expected = Ok(Ok(List.sort(byRule()))), result)

    ///
    /// 入れ子（OBJECT の子）の値も数える。最上位のキーだけを見ると、子フィールドを消す時に
    /// いつも 0 件になり「安全です」と嘘をつく。
    ///
    @Test
    def testPgCountReachesNestedValues(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"n1"}, () -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            let hero = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("hero", FieldKind.Object, FieldConfig.empty()));
            let headline = ContentTypes.addField(Session.grant(), blogs#id, { parent = Some(hero#id) | CmsTestKit.fieldDraft("headline", FieldKind.Text, FieldConfig.empty()) });
            discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("n1")),
                CmsTestKit.entryData(List#{("hero", Json.JObject(Map#{ "headline" => Json.JString("深い所") }))}));
            let (fields, _) = SchemaCounts.forChanges(List#{SchemaChange.FieldRemoved(headline)});
            fields |> List.map(count -> (ApiId.text(count#apiId), count#draft#total, count#published#total))
        }));
        Assert.assertEq(expected = Ok(Ok(List#{("headline", 1i64, 0i64)})), result)

    ///
    /// required を立てた時は「公開中だが値が無い」数を、unique を立てた時は「公開中で重なっている」数を数える。
    /// 立てていない性質は数えない（要らない SQL を打たない）。
    ///
    @Test
    def testPgCountTightenedFlags(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1", "b2", "b3"}, () -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            let title = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let note = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("note", FieldKind.Text, FieldConfig.empty()));
            // b1 と b2 は title が同じ、b3 は title が空
            List#{("b1", "same"), ("b2", "same"), ("b3", "")} |> List.forEach(match (id, value) -> {
                let entry = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId(id)), CmsTestKit.entryData(List#{("title", Json.JString(value)), ("note", Json.JString("n"))}));
                discard ContentEntries.publish(Session.grant(), entry#id, "tester", false)
            });
            let required = SchemaCounts.forChanges(List#{SchemaChange.FieldRequired(title)}) |> fst;
            let unique = SchemaCounts.forChanges(List#{SchemaChange.FieldUnique(title)}) |> fst;
            let untouched = SchemaCounts.forChanges(List#{SchemaChange.FieldRemoved(note)}) |> fst;
            (required |> List.map(count -> count#missingPublished#total),
             unique |> List.map(count -> count#duplicatePublished#total),
             untouched |> List.map(count -> (count#missingPublished#total, count#duplicatePublished#total)))
        }));
        // b3 の title が空なので required は 1 件、b1 と b2 が重なるので unique は 2 件、
        // note は性質を締めていないのでどちらも数えない
        Assert.assertEq(expected = Ok(Ok((List#{1i64}, List#{2i64}, List#{(0i64, 0i64)}))), result)


    // ---- config を締めた時 ----

    ///
    /// config を締めた時に外れる値の見本。(apiId, 種類, 値, 変更前の config, 変更後の config)。
    /// 絵文字はコードポイントで数える（UTF-16 なら 2 倍になる）ので、境界として入れる。
    ///
    def narrowedSamples(): List[(String, FieldKind, Json, FieldConfig, FieldConfig)] =
        let none = FieldConfig.empty();
        let cap = n -> { maxLength = Some(n) | none };
        let range = (low, high, integer) -> { min = low, max = high, integer = integer | none };
        let opts = options -> { options = options | none };
        List#{
            ("textOver",   FieldKind.Text,   Json.JString("あいうえお"),     cap(10),                     cap(3)),
            ("textFits",   FieldKind.Text,   Json.JString("abc"),            cap(10),                     cap(3)),
            ("emojiFits",  FieldKind.Text,   Json.JString("😀😀😀"),          cap(10),                     cap(3)),
            ("emojiOver",  FieldKind.Text,   Json.JString("😀😀😀😀"),        cap(10),                     cap(3)),
            ("textNoCap",  FieldKind.Text,   Json.JString("longer than five"), none,                      cap(5)),
            ("numLow",     FieldKind.Number, CmsTestKit.intJson(1),          none,                        range(Some(5.0), None, None)),
            ("numHigh",    FieldKind.Number, CmsTestKit.intJson(10),         range(None, Some(100.0), None), range(None, Some(5.0), None)),
            ("numFits",    FieldKind.Number, CmsTestKit.intJson(7),          range(Some(1.0), Some(100.0), None), range(Some(5.0), Some(10.0), None)),
            ("numFrac",    FieldKind.Number, Json.JNumber(Float64.tryToBigDecimal(2.5) |> Option.getWithDefault(Int32.toBigDecimal(0))), none, range(None, None, Some(true))),
            ("numInt",     FieldKind.Number, CmsTestKit.intJson(3),          none,                        range(None, None, Some(true))),
            ("pickGone",   FieldKind.Select, Json.JString("B"),              opts(List#{"A", "B"}),       opts(List#{"A", "C"})),
            ("pickKept",   FieldKind.Select, Json.JString("A"),              opts(List#{"A", "B"}),       opts(List#{"A"}))
        }

    def narrowedData(): EntryData =
        CmsTestKit.entryData(narrowedSamples() |> List.map(match (api, _, value, _, _) -> (api, value)))

    /// 見本を変更前の config で作り、下書きを 1 件置く。返すのは型の id。
    def seedNarrowed(): TypeId \ Db + CmsErr + Tenant + IdGen + Session =
        let probes = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("probes", "見本"));
        narrowedSamples() |> List.forEach(match (api, kind, _, was, _) ->
            discard ContentTypes.addField(Session.grant(), probes#id, CmsTestKit.fieldDraft(api, kind, was)));
        discard ContentEntries.create(Session.grant(), probes#id, Some(CmsTestKit.entryId("p1")), narrowedData());
        probes#id

    ///
    /// 規則が「下書きとして保存できない」と言うフィールドの apiId。変更後の config で draft の検査に通す。
    ///
    def blockedByRule(): List[String] =
        let fields = narrowedSamples() |> List.map(match (api, kind, _, _, now) -> { config = now | CmsTestKit.fieldDef(api, kind) });
        let broken = EntryValidation.draft(fields, narrowedData()) |> CmsTestKit.violationPaths;
        narrowedSamples() |> List.filterMap(match (api, _, _, _, _) ->
            if (List.memberOf("fields.${api}", broken)) Some(api) else None)

    ///
    /// 見本の半分は規則に止まり、半分は通る。突き合わせが空同士で通ってしまわないための固定。
    ///
    @Test
    def testNarrowedSamplesSplit(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{"emojiOver", "numFrac", "numHigh", "numLow", "pickGone", "textNoCap", "textOver"},
            List.sort(blockedByRule()))

    ///
    /// SQL が「新しい config から外れる」と数えるフィールドと、EntryValidation.draft が止めるフィールドが一致する。
    ///
    /// ここがずれると、押す前に「安全」と出た後で、その entry が保存できなくなる。
    ///
    @Test
    def testPgCountMatchesNarrowedConfig(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"p1"}, () -> {
            let probes = seedNarrowed();
            let owner = ContentTypes.get(Session.grant(), probes);
            let counted = owner#fields |> List.filterMap(field -> {
                let now = narrowedSamples() |> List.findMap(match (api, _, _, _, config) -> if (api == ApiId.text(field#apiId)) Some(config) else None) |> Option.getWithDefault(field#config);
                let (fields, _) = SchemaCounts.forChanges(List#{SchemaChange.FieldConfigNarrowed({ config = now | field }, field#config)});
                match List.head(fields) {
                    case Some(count) => if (count#outsideConfig#total > 0i64) Some(ApiId.text(field#apiId)) else None
                    case None        => None
                }
            });
            List.sort(counted)
        }));
        Assert.assertEq(expected = Ok(Ok(List.sort(blockedByRule()))), result)


    // ---- 見本 ----

    ///
    /// 件数は全件、見本は sampleSize 件まで。7 件に値があれば total は 7、id は 5 つ。
    /// 見本は更新の新しい順（画面で「他 N 件」の前に出るのは直近に触った物）。
    ///
    @Test
    def testPgCountKeepsTotalButSamplesEntries(): Unit \ {IO, Assert} =
        let ids = List#{"s1", "s2", "s3", "s4", "s5", "s6", "s7"};
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(ids, () -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            let body = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.Text, FieldConfig.empty()));
            ids |> List.forEach(id -> discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId(id)), CmsTestKit.entryData(List#{("body", Json.JString(id))})));
            let (fields, _) = SchemaCounts.forChanges(List#{SchemaChange.FieldRemoved(body)});
            fields |> List.map(count -> (count#draft#total, List.length(count#draft#entries), count#published#total, List.length(count#published#entries)))
        }));
        Assert.assertEq(expected = Ok(Ok(List#{(7i64, 5, 0i64, 0)})), result)

}
