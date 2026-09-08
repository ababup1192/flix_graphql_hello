///
/// PostgreSQL の接続設定を環境変数から読む。
///
/// - CMS_DSN: `jdbc:postgresql://host:port/db`。必須
/// - CMS_DB_USER / CMS_DB_PASSWORD: 省略時は "cms"（docker-compose.yml と同じ）。表の所有者。migration に使う
/// - CMS_DB_APP_USER / CMS_DB_APP_PASSWORD: リクエストに使うアプリ用のロール（RLS が効く）。PASSWORD が無ければ所有者で繋ぐ
/// - CMS_DB_TIMEOUT_SECONDS: 接続ごとに DB 側で効かせる時間の上限（idle_in_transaction_session_timeout / statement_timeout / lock_timeout）。既定 30。0 で無効
/// - CMS_DB_LEAK_DETECTION_SECONDS: 借りたまま返さない接続を HikariCP が警告するまでの秒数。既定 0（無効）
///
mod DbConfig {

    /// CMS_DB_TIMEOUT_SECONDS の既定（秒）。
    pub def defaultTimeoutSeconds(): Int32 = 30

    ///
    /// プールの設定。接続数と待ちは sqlfx の既定のまま、漏れの検出だけ CMS_DB_LEAK_DETECTION_SECONDS で足す。
    ///
    pub def poolFromEnv(connection: Jdbc.ConnectionConfig): Pool.PoolConfig \ Sys.Env =
        { leakDetectionThresholdMs = leakDetectionSeconds(Sys.Env.getVar("CMS_DB_LEAK_DETECTION_SECONDS")) * 1000
        | Pool.defaultConfig(connection) }

    ///
    /// CMS_DB_LEAK_DETECTION_SECONDS の値を秒にする。無い・数字でない・負なら 0（無効）。
    ///
    pub def leakDetectionSeconds(raw: Option[String]): Int32 =
        raw |> Option.flatMap(Int32.fromString) |> Option.filter(seconds -> seconds >= 0) |> Option.getWithDefault(0)

    ///
    /// アプリ用のロールの接続設定。CMS_DB_APP_PASSWORD が無ければ None（所有者で繋ぐ。FORCE ROW LEVEL SECURITY なので policy 自体は効く）。
    ///
    pub def appFromEnv(owner: Jdbc.ConnectionConfig): Option[Jdbc.ConnectionConfig] \ Sys.Env =
        Sys.Env.getVar("CMS_DB_APP_PASSWORD") |> Option.map(password ->
            { url = owner#url, user = Sys.Env.getVar("CMS_DB_APP_USER") |> Option.getWithDefault("cms_app"), password = password })

    ///
    /// 環境変数から接続設定を組む。CMS_DSN が無ければ Err に理由を入れる。URL には CMS_DB_TIMEOUT_SECONDS の上限を付ける。
    ///
    pub def fromEnv(): Result[String, Jdbc.ConnectionConfig] \ Sys.Env =
        Sys.Env.getVar("CMS_DSN")
            |> Option.toOk("CMS_DSN が設定されていません（例: jdbc:postgresql://127.0.0.1:5432/cms）")
            |> Result.map(url -> {
                url      = withTimeouts(timeoutSeconds(Sys.Env.getVar("CMS_DB_TIMEOUT_SECONDS")), url),
                user     = Sys.Env.getVar("CMS_DB_USER") |> Option.getWithDefault("cms"),
                password = Sys.Env.getVar("CMS_DB_PASSWORD") |> Option.getWithDefault("cms")
            })

    ///
    /// CMS_DB_TIMEOUT_SECONDS の値を秒にする。無い・数字でない・負なら既定の 30。
    ///
    pub def timeoutSeconds(raw: Option[String]): Int32 =
        raw |> Option.flatMap(Int32.fromString) |> Option.filter(seconds -> seconds >= 0) |> Option.getWithDefault(defaultTimeoutSeconds())

    ///
    /// JDBC の URL に、接続ごとに DB 側で効く時間の上限（pgjdbc の `options` パラメータ）を付ける。
    /// idle_in_transaction_session_timeout / statement_timeout / lock_timeout を同じ秒数にする。
    /// 0 以下なら付けない。URL に既に `options=` があればそのまま（DSN に書いた物を優先する）。
    ///
    /// WhyNot: Tx ごとに `SET LOCAL` を流さないのは、Tx ごとに 1 往復増える上に、SQL を出さない Tx には効かないため。
    /// 接続パラメータなら接続を開く時の 1 回で済み、プールの全接続に漏れなく付く。
    ///
    /// WhyNot: 既にある `options=` に足さないのは、値の切れ目（`-c` の並び）を解釈し直す必要があり、
    /// DSN に手で書く人はそこに上限も書けるため。
    ///
    pub def withTimeouts(seconds: Int32, url: String): String =
        if (seconds <= 0 or String.contains(substr = "options=", url))
            url
        else
            let separator = if (String.contains(substr = "?", url)) "&" else "?";
            let settings = List#{"idle_in_transaction_session_timeout", "statement_timeout", "lock_timeout"}
                |> List.map(name -> "-c%20${name}=${seconds}s")
                |> List.join("%20");
            "${url}${separator}options=${settings}"

}
