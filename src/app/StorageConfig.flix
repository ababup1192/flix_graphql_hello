///
/// asset を置く S3 互換ストレージ（本番は Cloudflare R2、手元は MinIO）の設定を環境変数から読む。
///
/// - ASSET_ENDPOINT: S3 API の URL。例 `http://127.0.0.1:9000`、R2 は `https://{accountId}.r2.cloudflarestorage.com`
/// - ASSET_BUCKET: バケット名
/// - ASSET_ACCESS_KEY / ASSET_SECRET_KEY: 署名に使う鍵
/// - ASSET_REGION: 署名の region。MinIO は `us-east-1`、R2 は `auto`。省略時は `auto`
/// - ASSET_PUBLIC_URL: 配信 URL の前置き。例 `http://127.0.0.1:9000/cms`、R2 はカスタムドメイン
///
/// ASSET_ENDPOINT が無ければ asset の機能は「未設定」として動く（None）。セルフホストで画像を使わない
/// 構成を、環境変数を並べずに立てられるようにするため。
///
mod StorageConfig {

    ///
    /// S3 互換ストレージへの接続と配信の設定。
    ///
    /// - endpoint: S3 API の URL（末尾の `/` 無し）
    /// - bucket: バケット名
    /// - accessKey / secretKey: 署名に使う鍵
    /// - regionName: 署名に入れる region
    /// - publicUrl: 配信 URL の前置き（末尾の `/` 無し）
    ///
    pub type alias StorageConfig = {
        endpoint = String,
        bucket = String,
        accessKey = String,
        secretKey = String,
        regionName = String,
        publicUrl = String
    }

    ///
    /// 環境変数から設定を組む。ASSET_ENDPOINT が無ければ Ok(None)。
    /// ASSET_ENDPOINT があるのに他の必須項目が無ければ Err に足りない名前を入れる。
    ///
    pub def fromEnv(): Result[String, Option[StorageConfig]] \ Sys.Env =
        match Sys.Env.getVar("ASSET_ENDPOINT") {
            case None => Ok(None)
            case Some(endpoint) =>
                forM (
                    bucket <- required("ASSET_BUCKET");
                    accessKey <- required("ASSET_ACCESS_KEY");
                    secretKey <- required("ASSET_SECRET_KEY");
                    publicUrl <- required("ASSET_PUBLIC_URL")
                ) yield Some({
                    endpoint = trimSlash(endpoint),
                    bucket = bucket,
                    accessKey = accessKey,
                    secretKey = secretKey,
                    regionName = Sys.Env.getVar("ASSET_REGION") |> Option.getWithDefault("auto"),
                    publicUrl = trimSlash(publicUrl)
                })
        }

    /// 必須の環境変数。無ければその名前を Err に入れる。
    def required(name: String): Result[String, String] \ Sys.Env =
        Sys.Env.getVar(name) |> Option.toOk("${name} が設定されていません（ASSET_ENDPOINT があるので asset の設定が要ります）")

    /// URL の末尾の `/` を落とす。key を後ろに繋ぐ時に `//` にならないように。
    def trimSlash(url: String): String =
        if (String.endsWith(suffix = "/", url)) String.dropRight(1, url) else url

}
