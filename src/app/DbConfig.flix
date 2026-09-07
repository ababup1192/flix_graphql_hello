///
/// PostgreSQL の接続設定を環境変数から読む。
///
/// - CMS_DSN: `jdbc:postgresql://host:port/db`。必須
/// - CMS_DB_USER / CMS_DB_PASSWORD: 省略時は "cms"（docker-compose.yml と同じ）。表の所有者。migration に使う
/// - CMS_DB_APP_USER / CMS_DB_APP_PASSWORD: リクエストに使うアプリ用のロール（RLS が効く）。PASSWORD が無ければ所有者で繋ぐ
///
mod DbConfig {

    ///
    /// アプリ用のロールの接続設定。CMS_DB_APP_PASSWORD が無ければ None（所有者で繋ぐ。FORCE ROW LEVEL SECURITY なので policy 自体は効く）。
    ///
    pub def appFromEnv(owner: Jdbc.ConnectionConfig): Option[Jdbc.ConnectionConfig] \ Sys.Env =
        Sys.Env.getVar("CMS_DB_APP_PASSWORD") |> Option.map(password ->
            { url = owner#url, user = Sys.Env.getVar("CMS_DB_APP_USER") |> Option.getWithDefault("cms_app"), password = password })

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
