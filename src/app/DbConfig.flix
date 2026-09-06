///
/// PostgreSQL の接続設定を環境変数から読む。
///
/// - CMS_DSN: `jdbc:postgresql://host:port/db`。必須
/// - CMS_DB_USER / CMS_DB_PASSWORD: 省略時は "cms"（docker-compose.yml と同じ）
///
mod DbConfig {

    ///
    /// 環境変数から接続設定を組む。CMS_DSN が無ければ Err に理由を入れる。
    ///
    pub def fromEnv(): Result[String, Jdbc.ConnectionConfig] \ Sys.Env =
        Sys.Env.getVar("CMS_DSN")
            |> Option.toOk("CMS_DSN が設定されていません（例: jdbc:postgresql://127.0.0.1:5432/cms）")
            |> Result.map(url -> {
                url      = url,
                user     = Sys.Env.getVar("CMS_DB_USER") |> Option.getWithDefault("cms"),
                password = Sys.Env.getVar("CMS_DB_PASSWORD") |> Option.getWithDefault("cms")
            })

}
