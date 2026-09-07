///
/// asset のバイト列を置く先（S3 互換ストレージ）との境界。
///
/// Flix は中身を通さない。ブラウザが署名付き URL へ直接 PUT し、サーバは「置かれたか」を HEAD で
/// 確かめ、消す時に DELETE を送るだけ。effect にしてあるので、handler を差し替えると
/// 本物（`runWithS3`: MinIO も R2 も同じ）とテスト用（`runWithFake`）を選べる。
///
pub eff ObjectStore {
    /// `key` に `mime` / `size` の中身を置ける署名付き PUT URL。宣言と違う中身は置けない。保存先が無ければ Err
    def presignPut(key: String, mime: String, size: Int64): Result[String, String]
    /// `key` が置かれていればその size。無ければ None。通信に失敗すれば Err
    def head(key: String): Result[String, Option[Int64]]
    /// `key` を消す。無くても Ok
    def delete(key: String): Result[String, Unit]
    /// `key` の配信 URL
    def publicUrl(key: String): String
}

mod ObjectStore {
    use Net.Http.Http
    use Net.HttpRequest
    use Net.HttpResponse
    use StorageConfig.StorageConfig
    use Time.Clock

    /// 署名付き URL の有効期限。アップロードの開始までの猶予で、転送時間ではない。
    pub def uploadExpirySeconds(): Int32 = 600

    ///
    /// S3 互換 API で動かす。時刻は Clock、通信は Http に任せる。
    ///
    pub def runWithS3(config: StorageConfig, f: Unit -> a \ ef): a \ (ef - ObjectStore) + { Http, Clock } =
        run f() with handler ObjectStore {
            def presignPut(key, mime, size, resume) =
                let at = SigV4.timestampOf(Clock.now());
                let headers = Map#{ "content-type" => mime, "content-length" => Int64.toString(size) };
                resume(Ok(SigV4.presign(credentialsOf(config), at, uploadExpirySeconds(), requestOf(config, "PUT", key, headers))))
            def head(key, resume) =
                resume(send(config, "HEAD", key) |> Result.flatMap(sizeOf))
            def delete(key, resume) =
                resume(send(config, "DELETE", key) |> Result.flatMap(response ->
                    if (HttpResponse.isSuccess(response) or HttpResponse.status(response) == 404) Ok()
                    else Err("削除に失敗しました（HTTP ${HttpResponse.status(response)}）")))
            def publicUrl(key, resume) =
                resume("${config#publicUrl}/${key}")
        }

    ///
    /// テスト用。`present` にある key だけが置かれている事にする。URL は署名せず、形だけ返す。
    ///
    pub def runWithFake(present: Map[String, Int64], f: Unit -> a \ ef): a \ ef - ObjectStore =
        run f() with handler ObjectStore {
            def presignPut(key, mime, size, resume) = resume(Ok("fake://upload/${key}?mime=${mime}&size=${size}"))
            def head(key, resume) = resume(Ok(Map.get(key, present)))
            def delete(_, resume) = resume(Ok())
            def publicUrl(key, resume) = resume("fake://public/${key}")
        }

    ///
    /// 保存先が設定されていない時（ASSET_ENDPOINT 無し）。asset の操作は全部 Err で、配信 URL は key そのまま。
    ///
    pub def runUnconfigured(f: Unit -> a \ ef): a \ ef - ObjectStore =
        run f() with handler ObjectStore {
            def presignPut(_, _, _, resume) = resume(Err(unconfiguredMessage()))
            def head(_, resume) = resume(Err(unconfiguredMessage()))
            def delete(_, resume) = resume(Err(unconfiguredMessage()))
            def publicUrl(key, resume) = resume(key)
        }

    ///
    /// 設定があれば S3、無ければ未設定の handler。
    ///
    pub def runWith(storage: Option[StorageConfig], f: Unit -> a \ ef): a \ (ef - ObjectStore) + { Http, Clock } = match storage {
        case Some(config) => runWithS3(config, f)
        case None         => runUnconfigured(f)
    }

    def unconfiguredMessage(): String = "asset の保存先が設定されていません（ASSET_ENDPOINT など）"

    ///
    /// endpoint（`http://127.0.0.1:9000` など）を scheme と host に分ける。パスは捨てる。
    ///
    pub def splitEndpoint(endpoint: String): (String, String) =
        match String.indexOf(substr = "://", endpoint) {
            case None => ("https", endpoint)
            case Some(i) =>
                let rest = String.drop(i + 3, endpoint);
                let host = rest |> String.splitOn(substr = "/") |> List.head |> Option.getWithDefault(rest);
                (String.take(i, endpoint), host)
        }

    /// 本文なしのリクエストを署名して送る。通信の失敗は Err。
    def send(config: StorageConfig, method: String, key: String): Result[String, HttpResponse] \ { Http, Clock } =
        let at = SigV4.timestampOf(Clock.now());
        let req = requestOf(config, method, key, Map.empty());
        let signed = SigV4.authorize(credentialsOf(config), at, req);
        let base = if (method == "HEAD") HttpRequest.head(urlOf(config, key)) else HttpRequest.delete(urlOf(config, key));
        Map.foldLeftWithKey((acc, name, value) -> HttpRequest.setHeader(name, value, acc), base, signed)
            |> Net.Http.send
            |> Result.mapErr(err -> "ストレージに繋がりません: ${err}")

    /// HEAD の応答を size に読む。404 は None、他の失敗は Err。
    def sizeOf(response: HttpResponse): Result[String, Option[Int64]] =
        if (HttpResponse.status(response) == 404) Ok(None)
        else if (HttpResponse.isSuccess(response)) Ok(HttpResponse.contentLength(response))
        else Err("ストレージが応答を返しました（HTTP ${HttpResponse.status(response)}）")

    /// 署名の対象。パス形式（host の後にバケット）。R2 も MinIO もこれで通る。
    def requestOf(config: StorageConfig, method: String, key: String, headers: Map[String, String]): SigV4.Request =
        let (scheme, host) = splitEndpoint(config#endpoint);
        { method = method, scheme = scheme, host = host, path = "/${config#bucket}/${key}", headers = headers }

    /// 送信先 URL。key はセグメントごとにエンコードする。
    def urlOf(config: StorageConfig, key: String): String =
        let encoded = key |> String.splitOn(substr = "/") |> List.map(SigV4.uriEncode) |> List.join("/");
        "${config#endpoint}/${config#bucket}/${encoded}"

    def credentialsOf(config: StorageConfig): SigV4.Credentials =
        { accessKey = config#accessKey, secretKey = config#secretKey, regionName = config#regionName }

}
