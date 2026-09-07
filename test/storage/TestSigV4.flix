///
/// SigV4 の署名。期待値は AWS の文書「Examples: Signature Calculations」の例と、
/// 同じ手順を Python（hmac / hashlib）で計算した値。
///
mod TestSigV4 {

    /// AWS の文書の例で使う鍵（公開されている見本の鍵）。
    def docCredentials(): SigV4.Credentials =
        { accessKey = "AKIAIOSFODNN7EXAMPLE", secretKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", regionName = "us-east-1" }

    /// 文書の例の時刻。2013-05-24 00:00:00 UTC。
    def docTime(): SigV4.Timestamp = { date = "20130524", time = "20130524T000000Z" }

    /// MinIO 向けの鍵（docker-compose.yml と同じ）。
    def minioCredentials(): SigV4.Credentials =
        { accessKey = "cms", secretKey = "cms-secret", regionName = "us-east-1" }

    // ---- 部品 ----

    /// 空文字の SHA-256 は決まった値（本文の無いリクエストのペイロードハッシュ）。
    @Test
    def testSha256OfEmpty(): Unit \ Assert =
        Assert.assertEq(expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", Sha256.hex(""))

    /// AWS 流のエンコード。`/` も `:` も空白も UTF-8 のバイトごとに %XX、`-_.~` と英数字は残す。
    @Test
    def testUriEncode(): Unit \ Assert =
        Assert.assertEq(
            expected = "a-b_c.d~e%2Ff%3Ag%20h%E3%81%82",
            SigV4.uriEncode("a-b_c.d~e/f:g hあ"))

    /// エポックミリ秒 → 署名の時刻。うるう年と年末をまたぐ値も含める。
    @Test
    def testTimestampOf(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                ("20130524", "20130524T000000Z"),
                ("20240229", "20240229T235959Z"),
                ("19700101", "19700101T000000Z")
            },
            List#{ 1369353600000i64, 1709251199000i64, 0i64 }
                |> List.map(SigV4.timestampOf)
                |> List.map(at -> (at#date, at#time)))

    // ---- 署名付き URL ----

    /// AWS の文書「Example: Presigned URL」。GET test.txt、host だけ署名、86400 秒。
    @Test
    def testPresignMatchesAwsDoc(): Unit \ Assert =
        let url = SigV4.presign(docCredentials(), docTime(), 86400,
            { method = "GET", scheme = "https", host = "examplebucket.s3.amazonaws.com", path = "/test.txt", headers = Map.empty() });
        Assert.assertEq(
            expected = "https://examplebucket.s3.amazonaws.com/test.txt"
                ++ "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
                ++ "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
                ++ "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400"
                ++ "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
                ++ "&X-Amz-SignedHeaders=host",
            url)

    /// ブラウザが直接置く PUT。content-type と content-length も署名に入れ、パスの空白はエンコードされる。
    /// MinIO のパス形式（host の後にバケット）。
    @Test
    def testPresignPutSignsContentHeaders(): Unit \ Assert =
        let url = SigV4.presign(minioCredentials(), docTime(), 600,
            { method = "PUT", scheme = "http", host = "127.0.0.1:9000", path = "/cms/1/abc123/photo x.png",
              headers = Map#{ "content-type" => "image/png", "content-length" => "1234" } });
        Assert.assertEq(
            expected = "http://127.0.0.1:9000/cms/1/abc123/photo%20x.png"
                ++ "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
                ++ "&X-Amz-Credential=cms%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
                ++ "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=600"
                ++ "&X-Amz-Signature=0d7c5d61b824133fcefa43068fd7384657037855c2d9c4a46105524c00827c06"
                ++ "&X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost",
            url)

    // ---- Authorization ヘッダ ----

    /// AWS の文書「Example: GET Object」。Range ヘッダ付き。x-amz-date と x-amz-content-sha256 は
    /// authorize が足すので、渡すのは range だけ。
    @Test
    def testAuthorizeMatchesAwsDoc(): Unit \ Assert =
        let headers = SigV4.authorize(docCredentials(), docTime(),
            { method = "GET", scheme = "https", host = "examplebucket.s3.amazonaws.com", path = "/test.txt",
              headers = Map#{ "range" => "bytes=0-9" } });
        Assert.assertEq(
            expected = Map#{
                "x-amz-date" => "20130524T000000Z",
                "x-amz-content-sha256" => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "authorization" => "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                    ++ "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                    ++ "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
            },
            headers)

    /// サーバからの DELETE（本文なし）。
    @Test
    def testAuthorizeDelete(): Unit \ Assert =
        let headers = SigV4.authorize(minioCredentials(), docTime(),
            { method = "DELETE", scheme = "http", host = "127.0.0.1:9000", path = "/cms/1/abc123/photo x.png", headers = Map.empty() });
        Assert.assertEq(
            expected = Some("AWS4-HMAC-SHA256 Credential=cms/20130524/us-east-1/s3/aws4_request, "
                ++ "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                ++ "Signature=74dfefb30313dc2d95f780a7e0034dbeea046ee8e252ec96d1fa84219e6c9e38"),
            Map.get("authorization", headers))

}
