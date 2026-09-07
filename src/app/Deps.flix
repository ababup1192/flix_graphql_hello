///
/// Runner に渡す、リクエストをまたいで同じ物。asset の保存先と認証の設定。
///
/// - storage: asset の保存先。無ければ asset の操作だけ Err
/// - auth: 本人確認のやり方、bootstrap の owner、API キーの pepper
///
pub type alias Deps = { storage = Option[StorageConfig.StorageConfig], auth = AuthConfig.AuthConfig }

mod Deps {

    ///
    /// テスト用。認証は閉じ、bootstrap の owner と pepper は決め打ち。
    ///
    pub def forTest(storage: Option[StorageConfig.StorageConfig]): Deps =
        { storage = storage,
          auth = { mode = AuthConfig.Mode.Closed, tokenHeader = "Authorization",
                   bootstrap = { ownerEmail = Some("owner@test") },
                   signup = Signup.Open,
                   pepper = Some({ pepperId = "test", secret = "test-pepper" }) } }

    ///
    /// 身元から今のプロジェクトでの主体を決める。DB を読む（ユーザーの作成と招待の受け入れもここで起きる）。
    ///
    /// - Bearer: 検証済みの本人。初回なら users を作る
    /// - ApiKey: pepper があれば hash で引き、このプロジェクトの生きた鍵なら scope の主体。それ以外は Anonymous
    /// - Missing / Invalid: Anonymous
    ///
    pub def actorOf(deps: Deps, projectId: ProjectId, credential: Credential): Actor \ Db + IdGen = match credential {
        case Credential.Bearer(issuer, subject, email, name) =>
            let user = Accounts.resolveUser(deps#auth#bootstrap, { issuer = issuer, subject = subject, email = email, name = name });
            Accounts.actorFor(user, projectId)
        case Credential.ApiKey(raw) =>
            deps#auth#pepper |> Option.flatMap(pepper -> ApiKeys.resolve(pepper, raw, projectId)) |> Option.map(Actor.ApiKey) |> Option.getWithDefault(Actor.Anonymous)
        case Credential.Missing    => Actor.Anonymous
        case Credential.Invalid(_) => Actor.Anonymous
    }

}
