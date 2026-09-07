///
/// ObjectStore の純粋な部分（endpoint の分解）と、テスト用 handler の振る舞い。
/// 本物の S3 API に当たるのは test/Pg/TestAssetsPg。
///
mod TestObjectStore {

    /// endpoint は scheme と host（ポート込み）に分かれ、後ろのパスは捨てる。scheme が無ければ https。
    @Test
    def testSplitEndpoint(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                ("http", "127.0.0.1:9000"),
                ("https", "abc.r2.cloudflarestorage.com"),
                ("https", "example.com"),
                ("https", "host.example")
            },
            List#{
                "http://127.0.0.1:9000",
                "https://abc.r2.cloudflarestorage.com/",
                "https://example.com/some/path",
                "host.example"
            } |> List.map(ObjectStore.splitEndpoint))

    /// テスト用 handler は present にある key だけを「置かれている」と答える。
    @Test
    def testFakeHead(): Unit \ Assert =
        Assert.assertEq(
            expected = (Ok(Some(12i64)), Ok(None), "fake://public/1/a/x.png"),
            ObjectStore.runWithFake(Map#{ "1/a/x.png" => 12i64 }, () ->
                (ObjectStore.head("1/a/x.png"), ObjectStore.head("1/b/y.png"), ObjectStore.publicUrl("1/a/x.png"))))

}
