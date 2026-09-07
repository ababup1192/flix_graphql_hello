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
    def blogsForPublish(): TypeId \ Db + CmsErr =
        let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
        discard ContentTypes.addField(blogs#id, { required = true | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
        discard ContentTypes.addField(blogs#id, { unique = true | CmsTestKit.fieldDraft("slug", FieldKind.Slug, { sourceField = CmsTestKit.apiId("title") |> Some | FieldConfig.empty() }) });
        discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("views", FieldKind.Number, FieldConfig.empty()));
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
            let created = ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("slug", Json.JString("hello"))}));
            let missing = CmsTestKit.failureMessage(() -> ContentEntries.publish(created#id, "tester", false));
            let withTitle = ContentEntries.update(created#id, CmsTestKit.entryData(List#{("title", Json.JString("Hello"))}), created#version);
            let published = ContentEntries.publish(created#id, "tester", false);
            let edited = ContentEntries.update(created#id, CmsTestKit.entryData(List#{("views", CmsTestKit.intJson(5))}), withTitle#version);
            let republished = ContentEntries.publish(created#id, "tester", false);
            let unpublished = ContentEntries.unpublish(created#id);
            let versions = ContentEntries.versions(created#id) |> List.map(version -> (version#version, version#reason, version#author));
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

    /// unique は公開中の値と照らす。同じ slug の 2 件目は invalid、取り下げれば通る。自分の再公開は通る。
    @Test
    def testPgPublishUnique(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"u1", "u2"}, () -> {
            let blogs = blogsForPublish();
            let first = ContentEntries.create(blogs, None, titled("One", "same"));
            let second = ContentEntries.create(blogs, None, titled("Two", "same"));
            discard ContentEntries.publish(first#id, "tester", false);
            let blocked = CmsTestKit.failureMessage(() -> ContentEntries.publish(second#id, "tester", false));
            let again = CmsTestKit.messageOr(entry -> entry#stage, () -> ContentEntries.publish(first#id, "tester", false));
            discard ContentEntries.unpublish(first#id);
            let freed = CmsTestKit.messageOr(entry -> entry#stage, () -> ContentEntries.publish(second#id, "tester", false));
            (blocked, again, freed)
        }));
        Assert.assertEq(expected = Ok(Ok((Err("fields.slug: 'same' は公開中の entry 'u1' が使っています"), Ok(Stage.Published), Ok(Stage.Published)))), result)

    /// 版は saveVersion で積め、restoreVersion で下書きに戻る。他の entry の版は notFound。
    @Test
    def testPgVersions(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"v1", "v2"}, () -> {
            let blogs = blogsForPublish();
            let created = ContentEntries.create(blogs, None, titled("Old", "old"));
            let other = ContentEntries.create(blogs, None, titled("Other", "other"));
            let saved = ContentEntries.saveVersion(created#id, "tester");
            let edited = ContentEntries.update(created#id, CmsTestKit.entryData(List#{("title", Json.JString("New"))}), created#version);
            let restored = ContentEntries.restoreVersion(created#id, saved#id, edited#version);
            let foreign = CmsErr.runWithResult(() -> ContentEntries.restoreVersion(other#id, saved#id, other#version)) |> Result.map(entry -> entry#version);
            (saved#reason, Map.get(CmsTestKit.apiId("title"), edited#data), Map.get(CmsTestKit.apiId("title"), restored#data), restored#version, foreign)
        }));
        Assert.assertEq(expected = Ok(Ok((VersionReason.Save, Some(Json.JString("New")), Some(Json.JString("Old")), 3, Err(CmsFailure.NotFound(Entity.Version, "1"))))), result)

    /// 公開するとコンテンツ API の既定（PUBLISHED）で引け、下書きの編集は公開側に出ない。消すと公開側からも消える。
    @Test
    def testPgPublishedVisibleInContentApi(): Unit \ {IO, Assert} =
        let seed = () -> CmsTestKit.withIds(List#{"c1"}, () -> {
            let blogs = blogsForPublish();
            let created = ContentEntries.create(blogs, None, titled("Public", "public"));
            discard ContentEntries.publish(created#id, "tester", false);
            discard ContentEntries.update(created#id, CmsTestKit.entryData(List#{("title", Json.JString("Edited"))}), created#version)
        });
        let outcome = PgTestSupport.withContentApiAndPool(seed, (pool, ask) -> {
            let published = ask("{ blog(id: \"c1\") { title stage } blogs { totalCount } }") |> fst;
            let draft = ask("{ blog(id: \"c1\", stage: DRAFT) { title } }") |> fst;
            discard PgTestSupport.mutate(pool, () -> ContentEntries.delete(CmsTestKit.entryId("c1")));
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
            let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(blogs#id, { required = true | CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()) });
            let slug = ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("slug", FieldKind.Slug, { sourceField = CmsTestKit.apiId("title") |> Some | FieldConfig.empty() }));
            let toggle = flag -> { name = None, required = None, unique = Some(flag), localized = None, config = None };
            let a = ContentEntries.create(blogs#id, None, titled("A", "same"));
            let c = ContentEntries.create(blogs#id, None, titled("C", "same"));
            discard ContentEntries.publish(a#id, "tester", false);
            let turnedOn = ContentTypes.updateField(slug#id, toggle(true)) |> (field -> field#unique);
            let blocked = CmsTestKit.failureMessage(() -> ContentEntries.publish(c#id, "tester", false));
            discard ContentTypes.updateField(slug#id, toggle(false));
            let freed = CmsTestKit.messageOr(entry -> entry#stage, () -> ContentEntries.publish(c#id, "tester", false));
            let again = ContentTypes.updateField(slug#id, toggle(true)) |> (field -> field#unique);
            (turnedOn, blocked, freed, again)
        }));
        Assert.assertEq(expected = Ok(Ok((true, Err("fields.slug: 'same' は公開中の entry 'a' が使っています"), Ok(Stage.Published), true))), result)

    /// 未公開の entry への unpublish は何もしない（updated_at も動かさない）。数値の unique は 1 と 1.0 を同じ値と見る。
    @Test
    def testPgUnpublishDraftAndNumericUnique(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"n1", "n2"}, () -> {
            let blogs = blogsForPublish();
            let codes = ContentTypes.addField(blogs, { unique = true | CmsTestKit.fieldDraft("code", FieldKind.Number, FieldConfig.empty()) });
            let first = ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("One")), ("slug", Json.JString("one")), ("code", CmsTestKit.floatJson(1.0))}));
            let second = ContentEntries.create(blogs, None, CmsTestKit.entryData(List#{("title", Json.JString("Two")), ("slug", Json.JString("two")), ("code", CmsTestKit.intJson(1))}));
            let untouched = ContentEntries.unpublish(first#id);
            discard ContentEntries.publish(first#id, "tester", false);
            let blocked = CmsTestKit.failureMessage(() -> ContentEntries.publish(second#id, "tester", false));
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
            discard ContentEntries.create(blogs, None, titled("A", "same"));
            discard ContentEntries.create(blogs, None, titled("B", "same"))
        }));
        Assert.assertEq(expected = Ok(Err("fields.slug: 'same' は公開中の entry 'a' が使っています")), PgTestSupport.withPool(raceSameSlug))

    ///
    /// T1 が A を公開して commit せずに待つあいだに T2 が B を公開しにいき、T1 を commit させてから T2 の結果を返す。
    ///
    def raceSameSlug(pool: Pool): Result[DbFailure, Result[String, Stage]] \ {IO, Chan, NonDet} =
        region rc {
            let (started, startedRx) = Channel.buffered(1);
            let (release, releaseRx) = Channel.buffered(1);
            let (done, doneRx) = Channel.buffered(1);
            spawn discard PgTestSupport.mutate(pool, () -> {
                discard ContentEntries.publish(CmsTestKit.entryId("a"), "tester", false);
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
    /// プール越しに 1 つの Tx で publish し、(DB の失敗, (業務エラーの文言, stage)) の形で返す。
    ///
    def publishOutcome(pool: Pool, id: String): Result[DbFailure, Result[String, Stage]] \ IO =
        DbError.runWithFailure(() -> CmsTestKit.messageOr(entry -> entry#stage, () -> Pool.withLazyTx(pool, () -> ContentEntries.publish(CmsTestKit.entryId(id), "tester", false))))
}
