///
/// 公開の流れを実 PostgreSQL で通しで動かす。publish / unpublish / CHANGED / unique / 版。
///
mod TestPublishPg {

    use Util.Json.Json
    use CmsErr.CmsFailure

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
        let outcome = PgTestSupport.withPool(pool -> {
            discard PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"c1"}, () -> {
                let blogs = blogsForPublish();
                let created = ContentEntries.create(blogs, None, titled("Public", "public"));
                discard ContentEntries.publish(created#id, "tester", false);
                discard ContentEntries.update(created#id, CmsTestKit.entryData(List#{("title", Json.JString("Edited"))}), created#version)
            }));
            let cache = ContentEngine.create();
            let ask = queryText -> GraphqlTestKit.askEngine(PgTestSupport.engineOrBug(cache, pool), queryText) |> fst;
            let published = ask("{ blog(id: \"c1\") { title stage } blogs { totalCount } }");
            let draft = ask("{ blog(id: \"c1\", stage: DRAFT) { title } }");
            discard DbError.runWithFailure(() -> CmsErr.runWithResult(() -> Pool.withLazyTx(pool, () -> ContentEntries.delete(CmsTestKit.entryId("c1")))));
            let afterDelete = ask("{ blogs { totalCount } }");
            (published, draft, afterDelete)
        });
        Assert.assertEq(
            expected = (
                Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "title" => Value.Str("Public"), "stage" => Value.Str("PUBLISHED") }), "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(1) }) }),
                Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "title" => Value.Str("Edited") }) }),
                Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) })),
            outcome)

}
