///
/// asset を実 PostgreSQL と MinIO で通す。署名付き URL に本当に PUT し、confirm がストレージで確かめ、消せば無くなる。
///
mod TestAssetsPg {

    use Net.HttpRequest
    use Net.HttpResponse

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
            let shop = Projects.create("shop", "店");
            Tenant.runWith(shop, () ->
                (Assets.find(upload#asset#id) |> Option.isEmpty,
                 CmsTestKit.failureMessage(() -> Assets.delete(upload#asset#id))))
        }));
        Assert.assertEq(expected = Ok(Ok((true, Err("asset 'asset003' が見つかりません")))), result)

}
