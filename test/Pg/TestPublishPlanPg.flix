///
/// 公開計画（publishPlan）と一括公開（publishMany）を実 PostgreSQL で見る。操作の列を最後の状態（stage と Webhook の outbox）まで追う。
///
mod TestPublishPlanPg {

    use Util.Json.Json

    /// 本文に id へのリンクを 1 つ持つ doc。
    def docLinkingTo(id: String): Json =
        Json.JObject(Map#{ "type" => Json.JString("doc"), "content" => Json.JArray(Vector#{
            Json.JObject(Map#{ "type" => Json.JString("paragraph"), "content" => Json.JArray(Vector#{
                Json.JObject(Map#{ "type" => Json.JString("text"), "text" => Json.JString("関連記事"),
                    "marks" => Json.JArray(Vector#{ Json.JObject(Map#{ "type" => Json.JString("link"), "attrs" => Json.JObject(Map#{ "entryId" => Json.JString(id) }) }) }) })
            }) })
        }) })

    ///
    /// profiles(p1) と blogs(b1, b2, b3)。entry.published を受ける Webhook が 1 つ。
    ///
    ///   b1 { title: <title>, profile: p1, body: link → b2 }
    ///   b2 { title: "two", body: link → b3 }
    ///   b3 { title: "three" }
    ///
    def seedGraph(title: String): String \ Db + CmsErr + Tenant + IdGen + Session =
        let issued = Webhooks.create(Session.grant(), { name = "site", url = "https://example.com/hook", events = List#{WebhookEvent.EntryPublished}, active = true });
        let profiles = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("profiles", "書き手"));
        discard ContentTypes.addField(Session.grant(), profiles#id, CmsTestKit.fieldDraft("name", FieldKind.Text, FieldConfig.empty()));
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, { required = true | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
        discard ContentTypes.addField(Session.grant(), blogs#id, { target = Some(profiles#id) | CmsTestKit.fieldDraft("profile", FieldKind.Reference, FieldConfig.empty()) });
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("body", FieldKind.RichText, FieldConfig.empty()));
        discard ContentEntries.create(Session.grant(), profiles#id, Some(CmsTestKit.entryId("p1")), CmsTestKit.entryData(List#{("name", Json.JString("山田"))}));
        discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b3")), CmsTestKit.entryData(List#{("title", Json.JString("three"))}));
        discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b2")), CmsTestKit.entryData(List#{("title", Json.JString("two")), ("body", docLinkingTo("b3"))}));
        discard ContentEntries.create(Session.grant(), blogs#id, Some(CmsTestKit.entryId("b1")), CmsTestKit.entryData(List#{("title", Json.JString(title)), ("profile", Json.JString("p1")), ("body", docLinkingTo("b2"))}));
        issued#webhook#publicId

    /// 計画を (id, 理由, その entry の違反の数) の列にする。
    def stepsOf(plan: PublishPlan): List[(String, PlanReason, Int32)] =
        plan#steps |> List.map(step -> (EntryId.text(step#entry#id), step#reason, List.length(step#report#violations)))

    /// 4 つの entry の stage。
    def stages(): List[(String, Stage)] \ DbRead + CmsErr + Tenant + Session =
        List#{"p1", "b1", "b2", "b3"} |> List.map(id -> (id, ContentEntries.get(Session.grant(), CmsTestKit.entryId(id))#stage))

    /// 計画は参照先が先（b1 の直接の参照先は id 順に b2, p1。b2 の先に b3）で、要求した b1 だけ REQUESTED。
    /// publishMany は同じ順で全部公開し、entry.published が 4 件積まれる。何度呼んでも計画は同じ（書き込まない）。
    ///
    ///   plan([b1]) → publishMany([b1]) → 全部 PUBLISHED、deliveries 4
    @Test
    def testPgPublishPlanThenPublishMany(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let webhookId = seedGraph("one");
            let plan = ContentEntries.publishPlan(Session.grant(), CmsTestKit.entryIds(List#{"b1"}), true);
            let published = ContentEntries.publishMany(Session.grant(), CmsTestKit.entryIds(List#{"b1"}), "tester", true);
            (stepsOf(plan), plan#violations,
             published |> List.map(entry -> EntryId.text(entry#id)),
             stages(),
             Webhooks.deliveries(Session.grant(), webhookId, 20, None) |> List.length)
        });
        Assert.assertEq(
            expected = (
                List#{ ("b3", PlanReason.Dependency, 0), ("b2", PlanReason.Dependency, 0), ("p1", PlanReason.Dependency, 0), ("b1", PlanReason.Requested, 0) },
                Nil,
                List#{ "b3", "b2", "p1", "b1" },
                List#{ ("p1", Stage.Published), ("b1", Stage.Published), ("b2", Stage.Published), ("b3", Stage.Published) },
                4),
            result)

    /// 要求した物に違反（b1 の required）があれば、計画は違反を見せ、publishMany は entry id 付きの path で invalid になり、
    /// 依存の側（b2, b3, p1）も含めて 1 つも公開されず、Webhook にも積まれない。
    @Test
    def testPgPublishManyPublishesNothingOnViolation(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            let webhookId = seedGraph("");
            let plan = ContentEntries.publishPlan(Session.grant(), CmsTestKit.entryIds(List#{"b2", "b1"}), true);
            let failed = CmsTestKit.failureMessage(() -> ContentEntries.publishMany(Session.grant(), CmsTestKit.entryIds(List#{"b2", "b1"}), "tester", true));
            (stepsOf(plan), failed, stages(), Webhooks.deliveries(Session.grant(), webhookId, 20, None) |> List.length)
        });
        Assert.assertEq(
            expected = (
                List#{ ("b3", PlanReason.Dependency, 0), ("b2", PlanReason.Requested, 0), ("p1", PlanReason.Dependency, 0), ("b1", PlanReason.Requested, 1) },
                Err("b1.fields.title: 公開には値が要ります"),
                List#{ ("p1", Stage.Draft), ("b1", Stage.Draft), ("b2", Stage.Draft), ("b3", Stage.Draft) },
                0),
            result)

    /// withDependencies: false では計画の外の未公開の参照先が違反になり、publishMany も同じ文言で止まる。
    /// 参照先を一緒に要求すれば（b3 と b2）通る。循環（b3 の本文が b2 へ戻る）は違反で、順は出る。
    @Test
    def testPgPublishPlanWithoutDependenciesAndCycles(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> {
            discard seedGraph("one");
            let outside = ContentEntries.publishPlan(Session.grant(), CmsTestKit.entryIds(List#{"b2"}), false);
            let blocked = CmsTestKit.failureMessage(() -> ContentEntries.publishMany(Session.grant(), CmsTestKit.entryIds(List#{"b2"}), "tester", false));
            let together = ContentEntries.publishPlan(Session.grant(), CmsTestKit.entryIds(List#{"b2", "b3"}), false);
            discard ContentEntries.update(Session.grant(), CmsTestKit.entryId("b3"), CmsTestKit.entryData(List#{("body", docLinkingTo("b2"))}), 1);
            let cycle = ContentEntries.publishPlan(Session.grant(), CmsTestKit.entryIds(List#{"b2"}), true);
            (outside#violations, blocked, stepsOf(together), together#violations, stepsOf(cycle), cycle#violations)
        });
        Assert.assertEq(
            expected = (
                Violation.Violation("b2.references", "参照先 'b3' が未公開です（withDependencies: true で一緒に公開できます）") :: Nil,
                Err("b2.references: 参照先 'b3' が未公開です（withDependencies: true で一緒に公開できます）"),
                List#{ ("b3", PlanReason.Requested, 0), ("b2", PlanReason.Requested, 0) },
                Nil,
                List#{ ("b3", PlanReason.Dependency, 0), ("b2", PlanReason.Requested, 0) },
                Violation.Violation("references", "参照が循環しています: b2 → b3 → b2") :: Nil),
            result)

    /// 管理 API を通した形。publishPlan は SDL の型で返り、publishMany は 1 つの mutation（1 つの Tx）で通らなければ errors で止まり、
    /// 通れば公開した順の entry を返す。
    @Test
    def testPgPublishPlanViaAdminApi(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> discard seedGraph(""), (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            let plan = ask("{ publishPlan(ids: [\"b1\"]) { ok steps { entry { id } reason report { ok violations { path message } unpublishedDependencies { id } } } violations { path message } } }");
            let (_, failed) = ask("mutation { publishMany(ids: [\"b1\"]) { id } }");
            let (stagesAfterFailure, _) = ask("{ b2: entry(id: \"b2\") { stage } b3: entry(id: \"b3\") { stage } }");
            let (fixed, _) = ask("mutation { updateEntry(id: \"b1\", fields: { title: \"one\" }, expectedVersion: 1) { version } }");
            let (published, _) = ask("mutation { publishMany(ids: [\"b1\"]) { id stage } }");
            (plan, failed, stagesAfterFailure, fixed, published)
        });
        let step = (id, reason, violations, dependencies) -> Value.Obj(Map#{
            "entry" => Value.Obj(Map#{ "id" => Value.Str(id) }),
            "reason" => Value.Str(reason),
            "report" => Value.Obj(Map#{ "ok" => Value.Bool(List.isEmpty(violations)), "violations" => Value.List(violations), "unpublishedDependencies" => Value.List(dependencies |> List.map(found -> Value.Obj(Map#{ "id" => Value.Str(found) }))) }) });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "publishPlan" => Value.Obj(Map#{
                    "ok" => Value.Bool(false),
                    "steps" => Value.List(List#{
                        step("b3", "DEPENDENCY", Nil, Nil),
                        step("b2", "DEPENDENCY", Nil, List#{"b3"}),
                        step("p1", "DEPENDENCY", Nil, Nil),
                        step("b1", "REQUESTED", Value.Obj(Map#{ "path" => Value.Str("fields.title"), "message" => Value.Str("公開には値が要ります") }) :: Nil, List#{"b2", "p1"}) }),
                    "violations" => Value.List(Nil) }) }), None),
                Some("b1.fields.title: 公開には値が要ります"),
                Value.Obj(Map#{ "b2" => Value.Obj(Map#{ "stage" => Value.Str("DRAFT") }), "b3" => Value.Obj(Map#{ "stage" => Value.Str("DRAFT") }) }),
                Value.Obj(Map#{ "updateEntry" => Value.Obj(Map#{ "version" => Value.Int(2) }) }),
                Value.Obj(Map#{ "publishMany" => Value.List(List#{"b3", "b2", "p1", "b1"} |> List.map(id -> Value.Obj(Map#{ "id" => Value.Str(id), "stage" => Value.Str("PUBLISHED") }))) })),
            outcome)

}
