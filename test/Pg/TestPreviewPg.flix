///
/// プレビュートークンを実 PostgreSQL で見る。トークンの entry の下書きは読め、他の entry の下書きと一覧は読めず、公開側は普通に読める。
/// 管理 API で発行すると previewUrl から url が組まれる。
///
mod TestPreviewPg {

    use Util.Json.Json

    def pepper(): ApiKeys.Pepper = { pepperId = "test", secret = "test-pepper" }

    /// 2100 年を「今」として発行する（検証は本物の時計で、期限はその 1 時間後なので切れない）。
    def farFuture(): Int64 = 4_102_444_800_000i64

    @Test
    def testPgPreviewTokenReadsOnlyItsEntry(): Unit \ {IO, Assert} =
        let seed = () -> CmsTestKit.withIds(List#{"e1", "e2"}, () -> {
            let blogs = ContentTypes.create({ previewUrl = Some("https://site.example/preview/{id}") | CmsTestKit.typeDraft("blogs", "記事") });
            discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("title", FieldKind.Text, FieldConfig.empty()));
            let first = ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("draft one"))}));
            discard ContentEntries.create(blogs#id, None, CmsTestKit.entryData(List#{("title", Json.JString("draft two"))}));
            PreviewTokens.issue(pepper(), first#id, 3600i64, farFuture())
        });
        let (own, other, listing, published, tampered, url) = PgTestSupport.withContentApiAndPool(seed, (pool, _) -> {
            let issued = PgTestSupport.mutate(pool, () -> CmsTestKit.withIds(Nil, () -> PreviewTokens.issue(pepper(), CmsTestKit.entryId("e1"), 3600i64, farFuture()))) |> PgTestSupport.seededOrBug;
            let cache = ContentEngine.create(PgTestSupport.deps());
            let engine = match ContentEngine.current(cache, pool, ProjectId.default()) { case Ok(found) => found case Err(message) => bug!(message) };
            let asPreview = queryText -> GraphqlTestKit.askEngineWith(engine, Context.withCredential(Credential.Preview(issued#token)), queryText);
            let asTampered = queryText -> GraphqlTestKit.askEngineWith(engine, Context.withCredential(Credential.Preview(issued#token + "x")), queryText);
            (asPreview("{ blog(id: \"e1\", stage: DRAFT) { id title } }"),
             asPreview("{ blog(id: \"e2\", stage: DRAFT) { id } }") |> snd,
             asPreview("{ blogs(stage: DRAFT) { totalCount } }") |> snd,
             asPreview("{ blogs { totalCount } }"),
             asTampered("{ blog(id: \"e1\", stage: DRAFT) { id } }") |> snd,
             issued#url)
        });
        Assert.assertEq(
            expected = (
                (Value.Obj(Map#{ "blog" => Value.Obj(Map#{ "id" => Value.Str("e1"), "title" => Value.Str("draft one") }) }), None),
                Some("この操作（readDraft）の権限がありません"),
                Some("この操作（readDraft）の権限がありません"),
                (Value.Obj(Map#{ "blogs" => Value.Obj(Map#{ "totalCount" => Value.Int(0) }) }), None),
                Some("この操作（readDraft）の権限がありません"),
                Some("https://site.example/preview/e1?preview=${issuedTokenPlaceholder()}")),
            (own, other, listing, published, tampered, url |> Option.map(found -> String.takeLeft(String.length("https://site.example/preview/e1?preview=") , found) + issuedTokenPlaceholder())))

    /// url の token 部分はその場で作られる乱数ではなく署名なので固定だが、長いので比較は前置きだけにする。
    def issuedTokenPlaceholder(): String = "<token>"

    ///
    /// 管理 API から発行できる（writer でも。readDraft を持つ）。既定は 1 時間後に切れ、上限は 1 日。
    ///
    @Test
    def testPgPreviewTokenViaAdminApi(): Unit \ {IO, Assert} =
        let (issued, tooLong) = PgTestSupport.withAdminApi(() -> CmsTestKit.withIds(List#{"e1"}, () -> {
            let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentEntries.create(blogs#id, None, CmsTestKit.entryData(Nil))
        }), (schema, _) -> {
            let ask = PgTestSupport.askOwner(schema);
            (ask("mutation { createPreviewToken(entryId: \"e1\") { entryId url } }"),
             ask("mutation { createPreviewToken(entryId: \"e1\", expiresInSeconds: 999999) { token } }") |> fst |> Value.path(List#{"createPreviewToken", "token"}) |> Value.asStr |> Option.map(token -> String.startsWith(prefix = "pv_", token)))
        });
        Assert.assertEq(
            expected = ((Value.Obj(Map#{ "createPreviewToken" => Value.Obj(Map#{ "entryId" => Value.Str("e1"), "url" => Value.Null }) }), None), Some(true)),
            (issued, tooLong))

}
