///
/// リクエストが持ってきた Credential。誰が確かめたかを区別する（認証（Authentication）が DB の役割と突き合わせて認証済みユーザーにする）。
///
/// - Bearer(issuer, subject, email, name): 発行元の JWT を検証済みの本人
/// - ApiKey(生の鍵): 公開 API の鍵。hash はここではしない
/// - PersonalToken(生のトークン): `Authorization: Bearer cmspat_...` の Personal Access Token。hash はここではしない
/// - Missing: 何も付いていない（公開の読み取り、または未ログイン）
/// - Invalid(理由): 付いていたが検証に落ちた。中身は含めない
///
pub enum Credential with Eq, Order, ToString {
    case Bearer(String, String, String, String)
    case ApiKey(String)
    case PersonalToken(String)
    /// X-Preview-Token の生の値
    case Preview(String)
    case Missing
    case Invalid(String)
}

///
/// リクエストのヘッダから Credential を組む。検証（JWT の署名など）は verify に任せ、ここは「どのヘッダを何として読むか」だけ。
///
/// 優先順: `Authorization: Bearer cmspat_...`（PAT）→ トークンのヘッダ（ログインの JWT。dev モードは X-Dev-User）→ X-Api-Key → X-Preview-Token → 無し。
///
/// WhyNot: PAT を tokenHeader の設定に関わらず Authorization から読むのは、Cloudflare Access のように JWT が別のヘッダで来る環境でも、
/// CLI は同じ `Authorization: Bearer` で叩けるようにするため。cmspat_ で始まらない Bearer は今まで通り JWT として検証する。
///
mod Credentials {

    ///
    /// ヘッダから Credential。verify はログインの JWT（か dev の email）から本人を出す。
    ///
    pub def ofHeaders(tokenHeader: String, verify: String -> Result[String, Principal] \ ef, headers: List[(String, String)]): Credential \ ef =
        match (personalTokenOf(headers), AuthConfig.tokenOf(tokenHeader, headers), AuthConfig.apiKeyOf(headers), AuthConfig.previewTokenOf(headers)) {
            case (Some(raw), _, _, _)     => Credential.PersonalToken(raw)
            case (None, Some(token), _, _) => match verify(token) {
                case Ok(principal) => Credential.Bearer(principal#issuer, principal#subject, principal#email, principal#name)
                case Err(reason)   => Credential.Invalid(reason)
            }
            case (None, None, Some(key), _)     => Credential.ApiKey(key)
            case (None, None, None, Some(raw))  => Credential.Preview(raw)
            case (None, None, None, None)       => Credential.Missing
        }

    ///
    /// Credential を読む middleware。ヘッダから組んで RouteRequest に入れ、next に渡す。認証（Credential → Actor）は runRoute がプロジェクトと同じ Tx で行う。
    ///
    pub def wrap(tokenHeader: String, verify: String -> Result[String, Principal] \ ef1, next: Handler[ef2]): Handler[ef1 + ef2] =
        routeRequest -> next({ credential = ofHeaders(tokenHeader, verify, routeRequest#request#headers) | routeRequest })

    ///
    /// `Authorization: Bearer cmspat_...` の生のトークン。その形でなければ None。
    ///
    pub def personalTokenOf(headers: List[(String, String)]): Option[String] =
        AuthConfig.tokenOf("Authorization", headers) |> Option.filter(value -> String.startsWith(prefix = PersonalTokens.prefix(), value))

}
