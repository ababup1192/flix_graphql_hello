///
/// 公開の流れを実 PostgreSQL で通しで動かす。publish / unpublish / CHANGED / unique / 版。
///
mod TestPublishPg {

    import java.lang.Thread

    use Util.Json.Json
    use CmsErr.CmsFailure
    use DbError.DbFailure

    ///
    /// blogs（title: required / slug: unique / views）を作って id を返す。
    ///
    def blogsForPublish(): TypeId \ Db + CmsErr + IdGen + Tenant + Session =
        let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(Session.grant(), blogs#id, { required = true | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
        discard ContentTypes.addField(Session.grant(), blogs#id, { unique = true | CmsTestKit.fieldDraft("slug", FieldKind.Slug, { sourceField = CmsTestKit.apiId("title") |> Some | FieldConfig.empty() }) });
        discard ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("views", FieldKind.Number, FieldConfig.empty()));
        blogs#id

    def titled(title: String, slug: String): EntryData =
        CmsTestKit.entryData(List#{("title", Json.JString(title)), ("slug", Json.JString(slug))})

    /// publish は required が無いと invalid、通れば stage が published になり版が積まれる。編集すると CHANGED、再公開で戻る。unpublish で draft に戻る。
    ///
    ///   create(title 無し) → publish ✗ → update(title) → publish ✓ v2 → update(views) → CHANGED → publish ✓ → unpublish → DRAFT
    @Test
    def testPgPublishLifecycle(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"p1"}, () -> {
            let blogs = blogsForPublish();
            let created = ContentEntries.create(Session.grant(), blogs, None, CmsTestKit.entryData(List#{("slug", Json.JString("hello"))}));
            let missing = CmsTestKit.failureMessage(() -> ContentEntries.publish(Session.grant(), created#id, "tester", false));
            let withTitle = ContentEntries.update(Session.grant(), created#id, CmsTestKit.entryData(List#{("title", Json.JString("Hello"))}), created#version);
            let published = ContentEntries.publish(Session.grant(), created#id, "tester", false);
            let edited = ContentEntries.update(Session.grant(), created#id, CmsTestKit.entryData(List#{("views", CmsTestKit.intJson(5))}), withTitle#version);
            let republished = ContentEntries.publish(Session.grant(), created#id, "tester", false);
            let unpublished = ContentEntries.unpublish(Session.grant(), created#id);
            let versions = ContentEntries.versions(Session.grant(), created#id) |> List.map(version -> (version#version, version#reason, version#author));
            (missing,
             (published#stage, published#changedSincePublish, Option.nonEmpty(published#publishedAt)),
             (edited#stage, edited#changedSincePublish),
             (republished#stage, republished#changedSincePublish),
             (unpublished#stage, Option.isEmpty(unpublished#publishedAt)),
             versions)
        }));
        Assert.assertEq(expected = Ok(Ok((
            Err("fields.title: 公開には値が要ります"),
            (Stage.Published, false, true),
            (Stage.Published, true),
            (Stage.Published, false),
            (Stage.Draft, true),
            List#{(3, VersionReason.Publish, "tester"), (2, VersionReason.Publish, "tester")}))), result)

    /// 公開中と同じ中身に戻すと CHANGED は消える（判定は下書きと公開中の中身の等値で、書いた時刻ではない）。
    ///
    ///   create(Hello/hello) → publish → update(title: Edited) → CHANGED → update(title: Hello) → PUBLISHED
    @Test
    def testPgRevertToPublishedContentClearsChanged(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"c1"}, () -> {
            let blogs = blogsForPublish();
            let created = ContentEntries.create(Session.grant(), blogs, None, titled("Hello", "hello"));
            let published = ContentEntries.publish(Session.grant(), created#id, "tester", false);
            let edited = ContentEntries.update(Session.grant(), created#id, CmsTestKit.entryData(List#{("title", Json.JString("Edited"))}), published#version);
            let reverted = ContentEntries.update(Session.grant(), created#id, CmsTestKit.entryData(List#{("title", Json.JString("Hello"))}), edited#version);
            ((edited#stage, edited#changedSincePublish), (reverted#stage, reverted#changedSincePublish))
        }));
        Assert.assertEq(expected = Ok(Ok(((Stage.Published, true), (Stage.Published, false)))), result)

    /// unique は公開中の値と照らす。同じ slug の 2 件目は invalid、取り下げれば通る。自分の再公開は通る。
    @Test
    def testPgPublishUnique(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"u1", "u2"}, () -> {
            let blogs = blogsForPublish();
            let first = ContentEntries.create(Session.grant(), blogs, None, titled("One", "same"));
            let second = ContentEntries.create(Session.grant(), blogs, None, titled("Two", "same"));
            discard ContentEntries.publish(Session.grant(), first#id, "tester", false);
            let blocked = CmsTestKit.failureMessage(() -> ContentEntries.publish(Session.grant(), second#id, "tester", false));
            let again = CmsTestKit.messageOr(entry -> entry#stage, () -> ContentEntries.publish(Session.grant(), first#id, "tester", false));
            discard ContentEntries.unpublish(Session.grant(), first#id);
            let freed = CmsTestKit.messageOr(entry -> entry#stage, () -> ContentEntries.publish(Session.grant(), second#id, "tester", false));
            (blocked, again, freed)
        }));
        Assert.assertEq(expected = Ok(Ok((Err("fields.slug: 'same' は公開中の entry 'u1' が使っています"), Ok(Stage.Published), Ok(Stage.Published)))), result)

    /// 版は saveVersion で積め、restoreVersion で下書きに戻る。他の entry の版は notFound。
    @Test
    def testPgVersions(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"v1", "v2"}, () -> {
            let blogs = blogsForPublish();
            let created = ContentEntries.create(Session.grant(), blogs, None, titled("Old", "old"));
            let other = ContentEntries.create(Session.grant(), blogs, None, titled("Other", "other"));
            let saved = ContentEntries.saveVersion(Session.grant(), created#id, "tester");
            let edited = ContentEntries.update(Session.grant(), created#id, CmsTestKit.entryData(List#{("title", Json.JString("New"))}), created#version);
            let restored = ContentEntries.restoreVersion(Session.grant(), created#id, saved#id, edited#version);
            let foreign = CmsErr.runWithResult(() -> ContentEntries.restoreVersion(Session.grant(), other#id, saved#id, other#version)) |> Result.map(entry -> entry#version);
            (saved#reason, Map.get(CmsTestKit.apiId("title"), edited#data), Map.get(CmsTestKit.apiId("title"), restored#data), restored#version, foreign)
        }));
        Assert.assertEq(expected = Ok(Ok((VersionReason.Save, Some(Json.JString("New")), Some(Json.JString("Old")), 3, Err(CmsFailure.NotFound(Entity.Version, "1"))))), result)

    /// 差分: CHANGED の entry で PUBLISHED → DRAFT を取ると、変えたフィールド 1 件だけ出る。未公開の entry の PUBLISHED は空なので、初回公開の差分は全部 Added。
    ///
    ///   create(Old/old) → publish → update(title: New) → diff(PUBLISHED, DRAFT) = [title: Changed(Old, New)]
    ///   create(Alone/alone) だけ                        → diff(PUBLISHED, DRAFT) = [title: Added(Alone), slug: Added(alone)]
    @Test
    def testPgDiffPublishedToDraft(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"d1", "d2"}, () -> {
            let blogs = blogsForPublish();
            let created = ContentEntries.create(Session.grant(), blogs, None, titled("Old", "old"));
            let unpublished = ContentEntries.create(Session.grant(), blogs, None, titled("Alone", "alone"));
            let published = ContentEntries.publish(Session.grant(), created#id, "tester", false);
            discard ContentEntries.update(Session.grant(), created#id, CmsTestKit.entryData(List#{("title", Json.JString("New"))}), published#version);
            let changed = ContentEntries.diff(Session.grant(), created#id, VersionRef.Published, VersionRef.Draft);
            let firstPublish = ContentEntries.diff(Session.grant(), unpublished#id, VersionRef.Published, VersionRef.Draft);
            (changed, firstPublish)
        }));
        Assert.assertEq(expected = Ok(Ok((
            FieldChange.FieldChange("title", Change.Changed(Json.JString("Old"), Json.JString("New"))) :: Nil,
            FieldChange.FieldChange("title", Change.Added(Json.JString("Alone"))) :: FieldChange.FieldChange("slug", Change.Added(Json.JString("alone"))) :: Nil))), result)

    /// 差分: versionId 同士で restore 前後の差が読める。restore した後の下書きは元のバージョンと同じ（差分無し）。他の entry のバージョンは notFound。
    ///
    ///   create(Old) → saveVersion(v1) → update(New) → saveVersion(v2) → restore(v1)
    ///     diff(v1, v2)    = [title: Changed(Old, New)]
    ///     diff(v1, DRAFT) = []
    ///     other の diff(v1, DRAFT) = NotFound(Version, "1")
    @Test
    def testPgDiffBetweenVersions(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"b1", "b2"}, () -> {
            let blogs = blogsForPublish();
            let created = ContentEntries.create(Session.grant(), blogs, None, titled("Old", "old"));
            let other = ContentEntries.create(Session.grant(), blogs, None, titled("Other", "other"));
            let first = ContentEntries.saveVersion(Session.grant(), created#id, "tester");
            let edited = ContentEntries.update(Session.grant(), created#id, CmsTestKit.entryData(List#{("title", Json.JString("New"))}), created#version);
            let second = ContentEntries.saveVersion(Session.grant(), created#id, "tester");
            discard ContentEntries.restoreVersion(Session.grant(), created#id, first#id, edited#version);
            let between = ContentEntries.diff(Session.grant(), created#id, VersionRef.Version(first#id), VersionRef.Version(second#id));
            let restored = ContentEntries.diff(Session.grant(), created#id, VersionRef.Version(first#id), VersionRef.Draft);
            let foreign = CmsErr.runWithResult(() -> ContentEntries.diff(Session.grant(), other#id, VersionRef.Version(first#id), VersionRef.Draft));
            (between, restored, foreign)
        }));
        Assert.assertEq(expected = Ok(Ok((
            FieldChange.FieldChange("title", Change.Changed(Json.JString("Old"), Json.JString("New"))) :: Nil,
            Nil,
            Err(CmsFailure.NotFound(Entity.Version, "1"))))), result)

    /// 差分（GraphQL 越し）: RICH_TEXT の差分は kind = TEXT で lines に出て、before / after / children は null。versionId を渡す形も通る。
    ///
    ///   createEntry(body: "a") → publishEntry → updateEntry(body: "b") → saveVersion
    ///     text: diff(PUBLISHED → DRAFT) = [body: TEXT, lines = [DEL a, ADD b]]
    ///     same: diff(versionId → DRAFT) = []
    @Test
    def testPgDiffRichTextViaAdminApi(): Unit \ {IO, Assert} =
        let outcome = PgTestSupport.withAdminApi(() -> (), (api, _) -> {
            let ask = PgTestSupport.askOwner(api);
            let typeId = GraphqlTestKit.stringAt(List#{"createContentType", "id"}, ask("mutation { createContentType(input: { apiId: \"posts\", name: \"投稿\" }) { id } }"));
            discard ask("mutation { addField(typeId: \"${typeId}\", input: { apiId: \"body\", name: \"本文\", kind: RICH_TEXT }) { id } }");
            let created = ask("mutation { createEntry(typeId: \"${typeId}\", fields: { body: ${CmsTestKit.docOf("a")} }) { id version } }");
            let entryId = GraphqlTestKit.stringAt(List#{"createEntry", "id"}, created);
            let published = ask("mutation { publishEntry(id: \"${entryId}\") { version } }");
            let version = GraphqlTestKit.intAt(List#{"publishEntry", "version"}, published);
            discard ask("mutation { updateEntry(id: \"${entryId}\", fields: { body: ${CmsTestKit.docOf("b")} }, expectedVersion: ${version}) { version } }");
            let saved = ask("mutation { saveVersion(id: \"${entryId}\") { id } }");
            let versionId = GraphqlTestKit.stringAt(List#{"saveVersion", "id"}, saved);
            ask("{ entry(id: \"${entryId}\") { text: diff(from: { stage: PUBLISHED }, to: { stage: DRAFT }) { path kind before after children { path } lines { kind text } } same: diff(from: { versionId: \"${versionId}\" }, to: { stage: DRAFT }) { path } } }")
        });
        let change = GraphqlTestKit.listAt(List#{"entry", "text"}, outcome) |> List.head |> Option.getWithDefault(Value.Null);
        let picked = GraphqlTestKit.pick(List#{List#{"path"}, List#{"kind"}, List#{"before"}, List#{"after"}, List#{"children"}, List#{"lines"}}, change);
        let same = GraphqlTestKit.valueAt(List#{"entry", "same"}, outcome);
        CmsTestKit.assertSameValue(
            Value.List(List#{
                Value.Str("body"), Value.Str("TEXT"), Value.Null, Value.Null, Value.Null,
                Value.List(List#{diffLine("DEL", "a"), diffLine("ADD", "b")}),
                Value.List(Nil)}),
            Value.List(picked ::: same :: Nil))

    /// GraphQL の DiffLine（{ kind, text }）の応答。
    def diffLine(kind: String, text: String): Value =
        Value.Obj(Map#{ "kind" => Value.Str(kind), "text" => Value.Str(text) })

    /// 復元した下書きは公開し直せる。公開側は復元した中身になり、CHANGED は消える。
    ///
    ///   create(Old/old) → publish → update(New/new) → publish → restore(最初の公開の版) → publish ✓ → 公開側 = Old
    @Test
    def testPgRestoreThenRepublish(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"r1"}, () -> {
            let blogs = blogsForPublish();
            let created = ContentEntries.create(Session.grant(), blogs, None, titled("Old", "old"));
            let first = ContentEntries.publish(Session.grant(), created#id, "tester", false);
            let edited = ContentEntries.update(Session.grant(), created#id, titled("New", "new"), first#version);
            discard ContentEntries.publish(Session.grant(), created#id, "tester", false);
            let oldest = ContentEntries.versions(Session.grant(), created#id) |> List.last |> Option.map(version -> version#id) |> Option.getWithDefault(VersionId.VersionId(0i64));
            let restored = ContentEntries.restoreVersion(Session.grant(), created#id, oldest, edited#version);
            let republished = CmsTestKit.messageOr(entry -> (entry#stage, entry#changedSincePublish), () -> ContentEntries.publish(Session.grant(), created#id, "tester", false));
            let publicSide = ContentEntries.findByStage(ContentTypes.get(Session.grant(), blogs), created#id, ContentEntries.StageAccess.Published) |> Option.map(entry -> Map.get(CmsTestKit.apiId("title"), entry#data));
            ((restored#changedSincePublish, Map.get(CmsTestKit.apiId("slug"), restored#data)), republished, publicSide)
        }));
        Assert.assertEq(expected = Ok(Ok(((true, Some(Json.JString("old"))), Ok((Stage.Published, false)), Some(Some(Json.JString("Old")))))), result)

    /// 復元した中身の unique が他の公開中の entry と重なる時、復元は下書きなので通るが、公開は拒まれ、公開側は動かない。
    ///
    ///   A(same) → saveVersion → update(A: free) → publish A → B(same) → publish B → restore A(版 same) ✓ → publish A ✗
    @Test
    def testPgRestoreUniqueCollisionRejectedOnPublish(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"a", "b"}, () -> {
            let blogs = blogsForPublish();
            let a = ContentEntries.create(Session.grant(), blogs, None, titled("A", "same"));
            let saved = ContentEntries.saveVersion(Session.grant(), a#id, "tester");
            let freed = ContentEntries.update(Session.grant(), a#id, titled("A", "free"), a#version);
            discard ContentEntries.publish(Session.grant(), a#id, "tester", false);
            let b = ContentEntries.create(Session.grant(), blogs, None, titled("B", "same"));
            discard ContentEntries.publish(Session.grant(), b#id, "tester", false);
            let restored = ContentEntries.restoreVersion(Session.grant(), a#id, saved#id, freed#version);
            let blocked = CmsTestKit.failureMessage(() -> ContentEntries.publish(Session.grant(), a#id, "tester", false));
            let publicSide = ContentEntries.findByStage(ContentTypes.get(Session.grant(), blogs), a#id, ContentEntries.StageAccess.Published) |> Option.map(entry -> Map.get(CmsTestKit.apiId("slug"), entry#data));
            (Map.get(CmsTestKit.apiId("slug"), restored#data), blocked, publicSide)
        }));
        Assert.assertEq(expected = Ok(Ok((Some(Json.JString("same")), Err("fields.slug: 'same' は公開中の entry 'b' が使っています"), Some(Some(Json.JString("free")))))), result)

    /// 復元しただけでは配信は積まれず、復元した物を公開すると entry.published が 1 件積まれる。
    @Test
    def testPgRestoreThenPublishEmitsWebhook(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"w1"}, () -> {
            let issued = Webhooks.create(Session.grant(), { name = "site", url = "https://example.com/hook", events = List#{WebhookEvent.EntryPublished}, active = true });
            let blogs = blogsForPublish();
            let created = ContentEntries.create(Session.grant(), blogs, Some(CmsTestKit.entryId("r1")), titled("Old", "old"));
            let saved = ContentEntries.saveVersion(Session.grant(), created#id, "tester");
            let edited = ContentEntries.update(Session.grant(), created#id, titled("New", "new"), created#version);
            discard ContentEntries.restoreVersion(Session.grant(), created#id, saved#id, edited#version);
            let events = () -> Webhooks.deliveries(Session.grant(), issued#webhook#publicId, 10) |> List.map(delivery -> delivery#event);
            let afterRestore = events();
            discard ContentEntries.publish(Session.grant(), created#id, "tester", false);
            (afterRestore, events())
        }));
        Assert.assertEq(expected = Ok(Ok((Nil, List#{WebhookEvent.EntryPublished}))), result)

    /// 公開するとコンテンツ API の既定（PUBLISHED）で引け、下書きの編集は公開側に出ない。消すと公開側からも消える。
    @Test
    def testPgPublishedVisibleInContentApi(): Unit \ {IO, Assert} =
        let seed = () -> CmsTestKit.withIds(List#{"c1"}, () -> {
            let blogs = blogsForPublish();
            let created = ContentEntries.create(Session.grant(), blogs, None, titled("Public", "public"));
            discard ContentEntries.publish(Session.grant(), created#id, "tester", false);
            discard ContentEntries.update(Session.grant(), created#id, CmsTestKit.entryData(List#{("title", Json.JString("Edited"))}), created#version)
        });
        let outcome = PgTestSupport.withContentApiAndPool(seed, (pool, ask) -> {
            let published = ask("{ blog(id: \"c1\") { title stage } blogs { totalCount } }") |> fst;
            let draft = ask("{ blog(id: \"c1\", stage: DRAFT) { title } }") |> fst;
            discard PgTestSupport.mutate(pool, () -> ContentEntries.delete(Session.grant(), Session.tryGrant(), CmsTestKit.entryId("c1")));
            let afterDelete = ask("{ blogs { totalCount } }") |> fst;
            (published, draft, afterDelete)
        });
        Assert.assertEq(
            expected = (
                Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "title" => Value.Str("Public"), "stage" => Value.Str("PUBLISHED") }), "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }),
                Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "title" => Value.Str("Edited") }) }),
                Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) })),
            outcome)

    /// unique は後から付け外しできる。付ける時に既存の重複は見ず、次に公開する entry がその時点で引っかかる。外せば同じ値を公開できる。
    ///
    ///   A(same) を公開 → unique ON → C(same) 公開 ✗ → unique OFF → C 公開 ✓ → unique ON ✓（重複があっても付けられる）
    @Test
    def testPgUniqueToggle(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"a", "c"}, () -> {
            let blogs = ContentTypes.create(Session.grant(), CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(Session.grant(), blogs#id, { required = true | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
            let slug = ContentTypes.addField(Session.grant(), blogs#id, CmsTestKit.fieldDraft("slug", FieldKind.Slug, { sourceField = CmsTestKit.apiId("title") |> Some | FieldConfig.empty() }));
            let toggle = flag -> { name = None, required = None, unique = Some(flag), localized = None, config = None };
            let a = ContentEntries.create(Session.grant(), blogs#id, None, titled("A", "same"));
            let c = ContentEntries.create(Session.grant(), blogs#id, None, titled("C", "same"));
            discard ContentEntries.publish(Session.grant(), a#id, "tester", false);
            let turnedOn = ContentTypes.updateField(Session.grant(), slug#id, toggle(true)) |> (field -> field#unique);
            let blocked = CmsTestKit.failureMessage(() -> ContentEntries.publish(Session.grant(), c#id, "tester", false));
            discard ContentTypes.updateField(Session.grant(), slug#id, toggle(false));
            let freed = CmsTestKit.messageOr(entry -> entry#stage, () -> ContentEntries.publish(Session.grant(), c#id, "tester", false));
            let again = ContentTypes.updateField(Session.grant(), slug#id, toggle(true)) |> (field -> field#unique);
            (turnedOn, blocked, freed, again)
        }));
        Assert.assertEq(expected = Ok(Ok((true, Err("fields.slug: 'same' は公開中の entry 'a' が使っています"), Ok(Stage.Published), true))), result)

    /// 未公開の entry への unpublish は何もしない（updated_at も動かさない）。数値の unique は 1 と 1.0 を同じ値と見る。
    @Test
    def testPgUnpublishDraftAndNumericUnique(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"n1", "n2"}, () -> {
            let blogs = blogsForPublish();
            let codes = ContentTypes.addField(Session.grant(), blogs, { unique = true | CmsTestKit.fieldDraft("code", FieldKind.Number, FieldConfig.empty()) });
            let first = ContentEntries.create(Session.grant(), blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("One")), ("slug", Json.JString("one")), ("code", CmsTestKit.floatJson(1.0))}));
            let second = ContentEntries.create(Session.grant(), blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("Two")), ("slug", Json.JString("two")), ("code", CmsTestKit.intJson(1))}));
            let untouched = ContentEntries.unpublish(Session.grant(), first#id);
            discard ContentEntries.publish(Session.grant(), first#id, "tester", false);
            let blocked = CmsTestKit.failureMessage(() -> ContentEntries.publish(Session.grant(), second#id, "tester", false));
            (ApiId.text(codes#apiId), untouched#updatedAt == first#updatedAt, blocked)
        }));
        Assert.assertEq(expected = Ok(Ok(("code", true, Err("fields.code: '1' は公開中の entry 'n1' が使っています")))), result)

    /// 同じ値を同時に公開しても 1 件しか通らない。先の Tx が commit するまで後の Tx は advisory lock で待ち、commit 後に先の公開を見て invalid になる。
    /// ロックが無ければ、後の Tx は commit 前の先の公開が見えず、両方通ってしまう。
    ///
    ///   T1: Tx 開始 → publish(A) → 「進んだ」を送る → 「commit してよい」を待つ → commit
    ///   T2: 「進んだ」を受けてから publish(B) → ロックで待つ → T1 の commit 後に A を見て ✗
    @Test
    def testPgUniqueLockSerializesConcurrentPublish(): Unit \ {IO, Assert, Chan, NonDet} =
        PgTestSupport.seed(() -> CmsTestKit.withIds(List#{"a", "b"}, () -> {
            let blogs = blogsForPublish();
            discard ContentEntries.create(Session.grant(), blogs, None, titled("A", "same"));
            discard ContentEntries.create(Session.grant(), blogs, None, titled("B", "same"))
        }));
        Assert.assertEq(expected = Err("fields.slug: 'same' は公開中の entry 'a' が使っています"), PgTestSupport.withPool(raceSameSlug))

    ///
    /// T1 が A を公開して commit せずに待つあいだに T2 が B を公開しにいき、T1 を commit させてから T2 の結果を返す。
    ///
    def raceSameSlug(pool: Pool): Result[String, Stage] \ {IO, Chan, NonDet} =
        region rc {
            let (started, startedRx) = Channel.buffered(1);
            let (release, releaseRx) = Channel.buffered(1);
            let (done, doneRx) = Channel.buffered(1);
            spawn discard PgTestSupport.mutate(pool, () -> {
                discard ContentEntries.publish(Session.grant(), CmsTestKit.entryId("a"), "tester", false);
                Channel.send((), started);
                Channel.recv(releaseRx)
            }) @ rc;
            Channel.recv(startedRx);
            spawn Channel.send(publishOutcome(pool, "b"), done) @ rc;
            // T2 がロックで待つ所まで進むのを待ってから T1 を commit させる
            Thread.sleep(500i64);
            Channel.send((), release);
            Channel.recv(doneRx)
        }


    ///
    /// プール越しに 1 つの Tx で publish し、(失敗の文言, stage) の形で返す。
    ///
    def publishOutcome(pool: Pool, id: String): Result[String, Stage] \ IO =
        PgTestSupport.mutate(pool, () -> ContentEntries.publish(Session.grant(), CmsTestKit.entryId(id), "tester", false))
            |> Result.map(entry -> entry#stage)
            |> Result.mapErr(ApplicationFailure.describe)
}
