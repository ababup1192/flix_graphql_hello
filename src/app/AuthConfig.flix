///
/// 認証の設定を環境変数から読む。
///
/// - CMS_AUTH: `jwks`（発行元の JWT を検証）か `dev`（X-Dev-User を信じる。127.0.0.1 と CMS_VERSION=dev の時だけ）か `none`（管理 API を閉じる）
/// - CMS_AUTH_ISSUER / CMS_AUTH_JWKS_URL / CMS_AUTH_AUDIENCE: jwks の時に必須
/// - CMS_AUTH_HEADER: JWT の入っているヘッダ。省略時 `Cf-Access-Jwt-Assertion`。`Authorization` なら `Bearer ` を剥がす
/// - CMS_BOOTSTRAP_OWNER: 最初の owner の email
/// - CMS_API_KEY_PEPPER: API キーのハッシュに混ぜる秘密（省略時は鍵の機能が使えない）
/// - CMS_API_KEY_PEPPER_ID: pepper の版。省略時 v1
///
mod AuthConfig {

    ///
    /// 本人確認のやり方。
    ///
    pub enum Mode {
        /// 発行元の JWT を JWKS で検証
        case Jwks(TokenVerifier.Config)
        /// 開発モード。X-Dev-User を信じる
        case Dev
        /// 管理 API を閉じる（公開 API だけ動かす）
        case Closed
    }

    ///
    /// 認証の設定一式。
    ///
    pub type alias AuthConfig = {
        mode = Mode,
        tokenHeader = String,
        bootstrap = Accounts.Bootstrap,
        signup = Signup,
        pepper = Option[ApiKeys.Pepper]
    }

    ///
    /// 環境変数から。jwks なのに 3 点が無い、dev なのに CMS_VERSION が dev でない、は Err。
    ///
    pub def fromEnv(): Result[String, AuthConfig] \ Sys.Env =
        let version = Sys.Env.getVar("CMS_VERSION") |> Option.getWithDefault("dev");
        forM (
            mode   <- modeOf(Sys.Env.getVar("CMS_AUTH") |> Option.getWithDefault("none"), version);
            signup <- signupOf(Sys.Env.getVar("CMS_SIGNUP") |> Option.getWithDefault("open"))
        ) yield {
            mode = mode,
            tokenHeader = Sys.Env.getVar("CMS_AUTH_HEADER") |> Option.getWithDefault("Cf-Access-Jwt-Assertion"),
            bootstrap = { ownerEmail = Sys.Env.getVar("CMS_BOOTSTRAP_OWNER") |> Option.map(String.toLowerCase) },
            signup = signup,
            pepper = Sys.Env.getVar("CMS_API_KEY_PEPPER") |> Option.map(secret -> { pepperId = Sys.Env.getVar("CMS_API_KEY_PEPPER_ID") |> Option.getWithDefault("v1"), secret = secret })
        }

    /// CMS_SIGNUP。open は誰でも組織を作れ、closed は既定の組織の owner だけ。
    def signupOf(text: String): Result[String, Signup] = match text {
        case "open"   => Ok(Signup.Open)
        case "closed" => Ok(Signup.Closed)
        case other    => Err("CMS_SIGNUP '${other}' は知りません（open / closed）")
    }

    def modeOf(text: String, version: String): Result[String, Mode] \ Sys.Env = match text {
        case "jwks" =>
            forM (
                issuer <- required("CMS_AUTH_ISSUER");
                jwksUrl <- required("CMS_AUTH_JWKS_URL");
                audience <- required("CMS_AUTH_AUDIENCE")
            ) yield Mode.Jwks({ issuer = issuer, jwksUrl = jwksUrl, audience = audience })
        case "dev" =>
            if (version == "dev") Ok(Mode.Dev)
            else Err("CMS_AUTH=dev は CMS_VERSION=dev の時だけ使えます（本番のイメージでは X-Dev-User を信じない）")
        case "none" => Ok(Mode.Closed)
        case other  => Err("CMS_AUTH '${other}' は知りません（jwks / dev / none）")
    }

    def required(name: String): Result[String, String] \ Sys.Env =
        Sys.Env.getVar(name) |> Option.toOk("${name} が設定されていません（CMS_AUTH=jwks には要ります）")

    ///
    /// リクエストからトークンを取り出す。`Authorization` なら `Bearer ` を剥がす。無ければ None。
    ///
    pub def tokenOf(headerName: String, headers: List[(String, String)]): Option[String] =
        Http.findHeader(headerName, headers)
            |> Option.map(value -> if (String.startsWith(prefix = "Bearer ", value)) String.drop(7, value) else value)
            |> Option.filter(value -> not String.isEmpty(value))

    ///
    /// リクエストから API キー（X-Api-Key）。
    ///
    /// X-Preview-Token の値。
    pub def previewTokenOf(headers: List[(String, String)]): Option[String] =
        Http.findHeader("X-Preview-Token", headers) |> Option.filter(value -> not String.isEmpty(value))

    pub def apiKeyOf(headers: List[(String, String)]): Option[String] =
        Http.findHeader("X-Api-Key", headers) |> Option.filter(value -> not String.isEmpty(value))

}
