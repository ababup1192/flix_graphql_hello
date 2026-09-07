///
/// asset を実 PostgreSQL と MinIO で通す。署名付き URL に本当に PUT し、confirm がストレージで確かめ、消せば無くなる。
///
mod TestAssetsPg {

    use Net.HttpRequest
    use Net.HttpResponse
    use Util.Json.Json

    /// 署名付き URL へ置く。宣言した Content-Type と大きさで送る。成功なら status。
    def putTo(url: String, mime: String, body: String): Result[String, Int32] \ IO =
        Net.Http.runWithIO(() ->
            Net.Http.send(HttpRequest.put(url, body) |> HttpRequest.withContentType(mime))
                |> Result.map(HttpResponse.status)
                |> Result.mapErr(err -> "${err}"))

    ///
    /// 発行 → PUT → confirm → 一覧 → 削除、の 1 本。
    ///
    ///   createUpload("photo x.png", 5 bytes)  → pending、URL
    ///   PUT "hello"                            → 200
    ///   confirm(width 10, height 20, alt)      → ready、size は HEAD の 5
    ///   list                                   → 1 件
    ///   delete                                 → 行も中身も無い
    @Test
    def testPgAssetUploadRoundTrip(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"asset001"}, () -> {
            let upload = Assets.createUpload({ fileName = "photo x.png", mime = "image/png", size = 5i64 });
            let beforeConfirm = CmsTestKit.failureMessage(() -> Assets.confirm(upload#asset#id, { width = None, height = None, alt = None }));
            let putStatus = putTo(upload#uploadUrl, "image/png", "hello");
            let ready = Assets.confirm(upload#asset#id, { width = Some(10), height = Some(20), alt = Some("写真") });
            let listed = Assets.list(10, 0);
            Assets.delete(upload#asset#id);
            (upload#asset#status, upload#asset#key, upload#expiresInSeconds,
             beforeConfirm, putStatus,
             (ready#status, ready#size, ready#width, ready#height, ready#alt),
             (List.length(listed#assets), listed#totalCount),
             Assets.find(upload#asset#id) |> Option.isEmpty,
             ObjectStore.head(upload#asset#key))
        }));
        Assert.assertEq(
            expected = Ok(Ok((
                AssetStatus.Pending, "1/asset001/photo-x.png", 600,
                Err("id: 'asset001' はまだアップロードが終わっていません"), Ok(200),
                (AssetStatus.Ready, 5i64, Some(10), Some(20), "写真"),
                (1, 1i64),
                true,
                Ok(None)))),
            result)

    /// 見本の本文。段落 1 つと asset010 の image。
    def sampleDoc(): Json =
        Json.JObject(Map#{ "type" => Json.JString("doc"), "content" => Json.JArray(Vector#{
            Json.JObject(Map#{ "type" => Json.JString("paragraph"), "content" => Json.JArray(Vector#{ Json.JObject(Map#{ "type" => Json.JString("text"), "text" => Json.JString("本文") }) }) }),
            Json.JObject(Map#{ "type" => Json.JString("image"), "attrs" => Json.JObject(Map#{ "assetId" => Json.JString("asset010"), "alt" => Json.JString("表紙") }) })
        }) })

    ///
    /// blogs { cover: ASSET, body: RICH_TEXT } に b1 を作り、asset を置いて公開する。
    ///
    ///   b1 = { cover: asset010, body: doc [ paragraph "本文", image asset010 ] }
    ///   publish（asset は pending）    → invalid
    ///   PUT + confirm                  → publish OK
    ///   deleteAsset(asset010)          → invalid（b1 が使っている）
    ///
    /// 戻り値はその 3 つの結果。
    ///
    def seedPublished(): (Result[String, Unit], Result[String, Int32], Result[String, Unit]) \ Db + CmsErr + Tenant + ObjectStore + IO =
        CmsTestKit.withIds(List#{"asset010"}, () -> {
            let blogs = ContentTypes.create(CmsTestKit.typeDraft("blogs", "記事"));
            discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("cover", FieldKind.Asset, FieldConfig.empty()));
            discard ContentTypes.addField(blogs#id, CmsTestKit.fieldDraft("body", FieldKind.RichText, FieldConfig.empty()));
            let upload = Assets.createUpload({ fileName = "cover.png", mime = "image/png", size = 5i64 });
            let entry = ContentEntries.create(blogs#id, Some(CmsTestKit.entryId("b1")), CmsTestKit.entryData(List#{("cover", Json.JString("asset010")), ("body", sampleDoc())}));
            let beforeReady = CmsTestKit.failureMessage(() -> ContentEntries.publish(entry#id, "tester", false));
            let putStatus = putTo(upload#uploadUrl, "image/png", "hello");
            discard Assets.confirm(upload#asset#id, { width = Some(640), height = Some(480), alt = None });
            discard ContentEntries.publish(entry#id, "tester", false);
            (beforeReady, putStatus, CmsTestKit.failureMessage(() -> Assets.delete(upload#asset#id)))
        })

    /// pending の asset を指す entry は公開できず、ready になれば公開でき、使われている asset は消せない。
    @Test
    def testPgAssetInEntry(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(seedPublished);
        Assert.assertEq(
            expected = Ok(Ok((
                Err("assets: asset 'asset010' がありません（消されているか、アップロードが終わっていません）"),
                Ok(200),
                Err("id: entry 'b1' が使っています。先に外してください")))),
            result)

    /// コンテンツ API は cover を Asset（url / width）に、body を RichText（html / text）に展開する。html の image は配信 URL。
    @Test
    def testPgAssetInContentApi(): Unit \ {IO, Assert} =
        let fetched = PgTestSupport.withContentApi(() -> discard seedPublished(), ask ->
            ask("{ blog(id: \"b1\") { cover { url width } body { html text headings { level text id } } } }"));
        Assert.assertEq(
            expected = (Value.Obj(Map#{ "blog" => Value.Obj(Map#{
                "cover" => Value.Obj(Map#{ "url" => Value.Str("http://127.0.0.1:9000/cms/1/asset010/cover.png"), "width" => Value.Int(640) }),
                "body" => Value.Obj(Map#{ "html" => Value.Str("<p>本文</p><img src=\"http://127.0.0.1:9000/cms/1/asset010/cover.png\" alt=\"表紙\" width=\"640\" height=\"480\">"), "text" => Value.Str("本文"), "headings" => Value.List(Nil) })
            }) }), None),
            fetched)

    /// 宣言と違う Content-Type で置こうとすると、署名が合わず拒まれる（403）。
    @Test
    def testPgUploadRejectsWrongContentType(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"asset002"}, () -> {
            let upload = Assets.createUpload({ fileName = "doc.pdf", mime = "application/pdf", size = 5i64 });
            putTo(upload#uploadUrl, "image/png", "hello")
        }));
        Assert.assertEq(expected = Ok(Ok(Ok(403))), result)

    /// 別のプロジェクトの asset は見えないし、confirm も消す事もできない。
    @Test
    def testPgAssetIsolation(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> CmsTestKit.withIds(List#{"asset003"}, () -> {
            let upload = Assets.createUpload({ fileName = "a.png", mime = "image/png", size = 5i64 });
            let shop = Projects.create(OrgId.default(), "shop", "店");
            Tenant.runWith(shop, () ->
                (Assets.find(upload#asset#id) |> Option.isEmpty,
                 CmsTestKit.failureMessage(() -> Assets.delete(upload#asset#id))))
        }));
        Assert.assertEq(expected = Ok(Ok((true, Err("asset 'asset003' が見つかりません")))), result)

}
