///
/// 公開の dry-run（publishReport）と影響の見える化（impact）を実 PostgreSQL で見る。
///
mod TestImpactPg {

    use Util.Json.Json

    /// 本文に b2 へのリンクを 1 つ持つ doc。
    def docLinkingTo(id: String): Json =
        Json.JObject(Map#{ "type" => Json.JString("doc"), "content" => Json.JArray(Vector#{
            Json.JObject(Map#{ "type" => Json.JString("paragraph"), "content" => Json.JArray(Vector#{
                Json.JObject(Map#{ "type" => Json.JString("text"), "text" => Json.JString("関連記事"),
                    "marks" => Json.JArray(Vector#{ Json.JObject(Map#{ "type" => Json.JString("link"), "attrs" => Json.JObject(Map#{ "entryId" => Json.JString(id) }) }) }) })
            }) })
        }) })

    ///
    /// profiles(p1) と blogs(b1, b2, b3)。
    ///
    ///   b1 { title: "", profile: p1, body: link → b2 }   required の title が空、参照先 p1 と b2 は未公開
    ///   b2 { title: "two", body: link → b3 }
    ///   b3 { title: "three" }
    ///
    def seedGraph(): (EntryId, EntryId, EntryId, EntryId) \ Db + CmsErr + Tenant + IdGen + Session =
        let profiles = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("profiles", "書き手"));
        discard ContentTypes.addField(Session.grant(), profiles#id, CmsTestKit.fieldDraft("name", FieldKind.Text, FieldConfig.empty()));
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, { required = true | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
        discard ContentTypes.addField(Session.grant(), blogs#id, { target = Some(profiles#id) | CmsTestKit.fieldDraft("profile", FieldKind.Reference, FieldConfig.empty()) });
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.RichText, FieldConfig.empty()));
        let p1 = ContentEntries.create(Session.grant(), profiles#id, Some(CmsTestKit.entryId("p1")), CmsTestKit.entryData(List#{("name", Json.JString("山田"))}));
        let b3 = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b3")), CmsTestKit.entryData(List#{("title", Json.JString("three"))}));
        let b2 = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b2")), CmsTestKit.entryData(List#{("title", Json.JString("two")), ("body", docLinkingTo("b3"))}));
        let b1 = ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b1")), CmsTestKit.entryData(List#{("title", Json.JString("")), ("profile", Json.JString("p1")), ("body", docLinkingTo("b2"))}));
        (p1#id, b1#id, b2#id, b3#id)

    /// publishReport は required の違反と、未公開の参照先（フィールドの参照と本文のリンク）を全部一度に返し、何も書かない。
    /// impact(PUBLISH) は再帰的に一緒に公開される物（b2 と、b2 の本文がリンクする b3、p1）を返す。
    @Test
    def testPgPublishReportAndPublishImpact(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let (_, b1, _, _) = seedGraph();
            let report = ContentEntries.publishReport(Session.grant(), b1);
            let cascades = ContentEntries.impact(Session.grant(), b1, ImpactAction.Publish);
            (report#violations,
             report#unpublishedDependencies |> List.map(entry -> EntryId.text(entry#id)) |> List.sort,
             cascades#cascades |> List.map(entry -> EntryId.text(entry#id)) |> List.sort,
             ContentEntries.find(Session.grant(), b1) |> Option.map(entry -> entry#stage))
        });
        Assert.assertEq(
            expected = (
                Violation.Violation("fields.title", "公開には値が要ります") :: Nil,
                List#{ "b2", "p1" },
                List#{ "b2", "b3", "p1" },
                Some(Stage.Draft)),
            result)

    /// 公開した後、b2 を取り下げる影響は「b1 の body（本文のリンク）が壊れる」。削除なら下書きの参照も出る。
    /// 本文のリンクが未公開の物を指したままでは公開できない（withDependencies で一緒に公開できる）。
    @Test
    def testPgUnpublishAndDeleteImpact(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let (p1, b1, b2, _) = seedGraph();
            discard ContentEntries.update(Session.grant(), b1, CmsTestKit.entryData(List#{("title", Json.JString("one"))}), 1);
            let blockedByLink = CmsTestKit.failureMessage(() -> ContentEntries.publish(Session.grant(), b2, "tester", false));
            discard ContentEntries.publish(Session.grant(), b1, "tester", true);
            let unpublishB2 = ContentEntries.impact(Session.grant(), b2, ImpactAction.Unpublish);
            let deleteP1 = ContentEntries.impact(Session.grant(), p1, ImpactAction.Delete);
            let describe = referrer -> (EntryId.text(referrer#entry#id), ApiId.text(referrer#via), referrer#stage);
            (blockedByLink,
             unpublishB2#breaks |> List.map(describe),
             deleteP1#breaks |> List.map(describe) |> List.sort)
        });
        Assert.assertEq(
            expected = (
                Err("references: 参照先 'b3' が未公開です（withDependencies: true で一緒に公開できます）"),
                List#{ ("b1", "body", Stage.Published) },
                List#{ ("b1", "profile", Stage.Draft), ("b1", "profile", Stage.Published) }),
            result)


    /// 循環（b2 ⇄ b3 が互いに本文でリンク）でも impact(PUBLISH) は止まり、各 1 回だけ出る。
    /// dry-run は unique（ロック無し）と、消された参照先（ゴミ箱の p1）を required と一緒に全部返す。無い id は notFound。
    @Test
    def testPgImpactCyclesAndReportCollectsAll(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let (p1, b1, b2, b3) = seedGraph();
            let blogs = ContentEntries.get(Session.grant(), b1)#typeId;
            discard ContentTypes.addField(Session.grant(), blogs, { unique = true | CmsTestKit.fieldDraft("slug", FieldKind.Text, FieldConfig.empty()) });
            discard ContentEntries.update(Session.grant(), b3, CmsTestKit.entryData(List#{("body", docLinkingTo("b2")), ("slug", Json.JString("same"))}), 1);
            discard ContentEntries.publish(Session.grant(), b3, "tester", true);
            discard ContentEntries.update(Session.grant(), b1, CmsTestKit.entryData(List#{("slug", Json.JString("same"))}), 1);
            ContentEntries.delete(Session.grant(), Session.tryGrant(), p1);
            let cycle = ContentEntries.impact(Session.grant(), b2, ImpactAction.Publish);
            let report = ContentEntries.publishReport(Session.grant(), b1);
            (cycle#cascades |> List.map(entry -> EntryId.text(entry#id)),
             report#violations |> List.map(violation -> { let Violation.Violation(path, _) = violation; path }),
             CmsTestKit.failureMessage(() -> ContentEntries.impact(Session.grant(), CmsTestKit.entryId("nope"), ImpactAction.Delete)))
        });
        Assert.assertEq(
            expected = (
                Nil,
                List#{ "fields.title", "fields.slug", "references" },
                Err("entry 'nope' が見つかりません")),
            result)

    /// impact(PUBLISH) の cascades は、withDependencies で実際に一緒に公開される物と一致する。
    @Test
    def testPgPublishCascadesMatchImpact(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let (p1, b1, b2, b3) = seedGraph();
            discard ContentEntries.update(Session.grant(), b1, CmsTestKit.entryData(List#{("title", Json.JString("one"))}), 1);
            let cascades = ContentEntries.impact(Session.grant(), b1, ImpactAction.Publish)#cascades |> List.map(entry -> EntryId.text(entry#id)) |> List.sort;
            discard ContentEntries.publish(Session.grant(), b1, "tester", true);
            let publishedOthers = List#{p1, b2, b3} |> List.filter(id -> ContentEntries.get(Session.grant(), id)#stage == Stage.Published) |> List.map(EntryId.text) |> List.sort;
            (cascades, publishedOthers)
        });
        Assert.assertEq(expected = (List#{ "b2", "b3", "p1" }, List#{ "b2", "b3", "p1" }), result)

    /// 管理 API を通した形。publishCheck / impact が SDL の型で返る。依存は直接の物が id 順、cascades は依存の順（b2 → その先の b3 → p1）。
    @Test
    def testPgImpactViaAdminApi(): Unit \ {IO, Assert} =
        let (check, impact) = PgTestSupport.withAdminApi(() -> discard seedGraph(), (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            (ask("{ publishCheck(id: \"b1\") { ok violations { path message } unpublishedDependencies { id } } }"),
             ask("{ impact(id: \"b1\", action: PUBLISH) { breaks { via } cascades { id } } }"))
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "publishCheck" => Value.Obj(Map#{
                    "ok" => Value.Bool(false),
                    "violations" => Value.List(Value.Obj(Map#{ "path" => Value.Str("fields.title"), "message" => Value.Str("公開には値が要ります") }) :: Nil),
                    "unpublishedDependencies" => Value.List(Value.Obj(Map#{ "id" => Value.Str("b2") }) :: Value.Obj(Map#{ "id" => Value.Str("p1") }) :: Nil) }) }), None),
                (Value.Obj(Map#{ "impact" => Value.Obj(Map#{
                    "breaks" => Value.List(Nil),
                    "cascades" => Value.List(Value.Obj(Map#{ "id" => Value.Str("b2") }) :: Value.Obj(Map#{ "id" => Value.Str("b3") }) :: Value.Obj(Map#{ "id" => Value.Str("p1") }) :: Nil) }) }), None)),
            (check, impact))

}
