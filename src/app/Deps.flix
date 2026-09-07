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
    /// 身元から決めた主体と、使用時刻を書く先。Runner が Session に主体を入れ、書く道（管理 API / Account API）では touch を呼ぶ。
    ///
    pub type alias Resolved = { actor = Actor, touch = Touch }

    ///
    /// 使用時刻を書く先。API キーか PAT の行。人（ログインの JWT）や匿名は無し。
    ///
    pub enum Touch with Eq, Order, ToString {
        case None
        case ApiKey(Int64)
        case PersonalToken(Int64)
    }

    ///
    /// 身元から今のプロジェクトでの主体を決める。DB を読む（ユーザーの作成と招待の受け入れもここで起きる）。
    ///
    /// - Bearer: 検証済みの本人。初回なら users を作る
    /// - ApiKey: pepper があれば hash で引き、このプロジェクトの生きた鍵なら scope の主体。それ以外は Anonymous
    /// - PersonalToken: pepper があれば hash で引き、生きていれば本人のこのプロジェクトでの主体（read なら読むだけ）。それ以外は Anonymous
    /// - Preview: pepper があれば署名と期限とプロジェクトを確かめ、合えばその entry のプレビュー。それ以外は Anonymous
    /// - Missing / Invalid: Anonymous
    ///
    pub def actorOf(deps: Deps, projectId: ProjectId, credential: Credential): Actor \ Db + IdGen + Time.Clock.Clock =
        resolve(deps, projectId, credential)#actor

    ///
    /// actorOf と同じ判断で、使用時刻を書く先も返す。
    ///
    pub def resolve(deps: Deps, projectId: ProjectId, credential: Credential): Resolved \ Db + IdGen + Time.Clock.Clock = match credential {
        case Credential.Bearer(issuer, subject, email, name) =>
            let user = Accounts.resolveUser(deps#auth#bootstrap, { issuer = issuer, subject = subject, email = email, name = name });
            { actor = Accounts.actorFor(user, projectId), touch = Touch.None }
        case Credential.ApiKey(raw) =>
            deps#auth#pepper |> Option.flatMap(pepper -> ApiKeys.resolve(pepper, raw, projectId, Time.Clock.now()))
                |> Option.map(found -> { actor = Actor.ApiKey(found#scope), touch = Touch.ApiKey(found#id) })
                |> Option.getWithDefault(anonymous())
        case Credential.PersonalToken(raw) =>
            resolvePersonalToken(deps, raw, user -> Accounts.actorFor(user, projectId))
        case Credential.Preview(raw) =>
            deps#auth#pepper |> Option.flatMap(pepper -> PreviewTokens.verify(pepper, raw, projectId, Time.Clock.now()))
                |> Option.map(id -> { actor = Actor.Preview(id), touch = Touch.None })
                |> Option.getWithDefault(anonymous())
        case Credential.Missing    => anonymous()
        case Credential.Invalid(_) => anonymous()
    }

    ///
    /// PAT から本人の主体。actorFor はプロジェクトの役割を組む（Account API はプロジェクト無しの主体を渡す）。
    /// 期限切れ・失効・知らないトークン・消えたユーザーは Anonymous。
    ///
    pub def resolvePersonalToken(deps: Deps, raw: String, actorFor: User -> Actor \ ef): Resolved \ ef + DbRead + Time.Clock.Clock =
        let found = deps#auth#pepper |> Option.flatMap(pepper -> PersonalTokens.resolve(pepper, raw, Time.Clock.now()));
        match found |> Option.flatMap(token -> Accounts.resolveUserById(token#userId) |> Option.map(user -> (token, user))) {
            case Some((token, user)) => { actor = Accounts.withPatScope(token#scope, actorFor(user)), touch = Touch.PersonalToken(token#id) }
            case None                => anonymous()
        }

    ///
    /// 使用時刻を書く。Runner が主体を決めた後（RLS の印が揃った後）に呼ぶ。
    ///
    pub def touch(resolved: Resolved): Unit \ DbWrite + Tenant = match resolved#touch {
        case Touch.None                 => ()
        case Touch.ApiKey(id)           => ApiKeys.touch(id)
        case Touch.PersonalToken(id)    => PersonalTokens.touch(id)
    }

    def anonymous(): Resolved = { actor = Actor.Anonymous, touch = Touch.None }

}
