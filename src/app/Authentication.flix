///
/// 認証: リクエストの Credential から認証済みユーザー（Actor）を決める。リクエストに 1 回、Main.runRoute がプロジェクトの解決と同じ Tx で呼ぶ
/// （初回ログインの users の作成と招待の受け入れが同じ Tx に入る。API キーの解決と membership の検索はプロジェクトの RLS の印の下で行う）。
///
/// - Bearer: 検証済みの本人（ログインの JWT）。初回なら users を作る
/// - ApiKey: pepper があれば hash で引き、このプロジェクトの生きた鍵なら scope の認証済みユーザー。それ以外は Anonymous（log に credential.kind = invalid の印と、失効・期限切れ・未知の理由）
/// - PersonalToken: hash で引き、生きていれば本人（read なら読むだけ）。期限切れ・失効・知らない物は Rejection（黙って匿名にしない）
/// - Preview: pepper があれば署名と期限とプロジェクトを確かめ、合えばその entry のプレビュー。それ以外は Anonymous（同じ印）
/// - Missing: Anonymous
/// - Invalid: 管理 API と Account API では Rejection（ログインの JWT が付いていたが検証に落ちた。SQL を出さずに断る）。コンテンツ API では Anonymous（同じ印）
///
/// WhyNot: コンテンツ API で壊れたログインの JWT を断らないのは、公開の読み取り API は資格証明の良し悪しを教える場所ではなく、
/// CDN の前に置く API がヘッダを無視するのと同じ扱いが正しいため。古い JWT がブラウザに残っている公開サイトを壊さない
/// （private なら匿名として guardVisibility が UNAUTHENTICATED で断る）。
///
/// WhyNot: 知らない鍵を匿名に落としても断らないのは、公開プロジェクトでは鍵が無くても読めるので API の振る舞いとしては匿名で正しいため。
/// ログでは総当たりと区別が要るので、匿名に落とした理由を印で残す。
///
/// WhyNot: 鍵と PAT の使用時刻（last_used_at）を業務の Tx でなく認証の Tx で書くのは、業務が失敗してもトークンは使われたので残すのが正しいため。
/// コンテンツ API では書かない（CDN 越しに大量に来る読み取りの道に UPDATE を足さない。「鍵が生きているか」は管理 API の使用で分かる）。
///

///
/// 認証に落ちた理由。Runner の手前で形にする（/graphql は 200 + errors[] の 1 件、/mcp は 401）。
///
/// - Invalid(理由): ログインの JWT が付いていたが検証に落ちた（UNAUTHENTICATED）
/// - DeadToken: PAT が期限切れ・失効・知らない物（UNAUTHENTICATED）
/// - NotForAccount(何): Account API に API キーやプレビュートークンで来た（REQUIRES_LOGIN）
/// - PrivateProject: private なプロジェクトのコンテンツ API に匿名で来た（UNAUTHENTICATED）
/// - NotMember: private なプロジェクトのコンテンツ API にメンバーでない人が来た（FORBIDDEN）
///
pub enum Rejection with Eq, Order, ToString {
    case Invalid(String)
    case DeadToken(PatRejection)
    case NotForAccount(String)
    case PrivateProject
    case NotMember
}

mod Rejection {

    /// GraphQL の extensions.code。
    pub def code(rejection: Rejection): ErrorCode = match rejection {
        case Rejection.Invalid(_)       => ErrorCode.Unauthenticated
        case Rejection.DeadToken(_)     => ErrorCode.Unauthenticated
        case Rejection.NotForAccount(_) => ErrorCode.RequiresLogin
        case Rejection.PrivateProject   => ErrorCode.Unauthenticated
        case Rejection.NotMember        => ErrorCode.Forbidden
    }

    /// 人が読む文言。
    pub def message(rejection: Rejection): String = match rejection {
        case Rejection.Invalid(reason)      => "認証に失敗しました: ${reason}"
        case Rejection.DeadToken(found)     => "認証に失敗しました: ${PatRejection.describe(found)}"
        case Rejection.NotForAccount(what)  => "Account API は ${what}では使えません。ログインしてください"
        case Rejection.PrivateProject       => "このプロジェクトは非公開です。API キーを X-Api-Key で渡してください"
        case Rejection.NotMember            => "このプロジェクトのメンバーではありません"
    }

    /// 付いていた鍵やトークンが検証に落ちた物か（ログの credential.kind を invalid に上書きする物）。
    pub def isCredentialFailure(rejection: Rejection): Bool = match rejection {
        case Rejection.Invalid(_)   => true
        case Rejection.DeadToken(_) => true
        case _                      => false
    }

}

///
/// 認証の結果。認証済みユーザーと、ログの span に足す属性（user.id / api_key.name。生の値と email は入れない）。
///
pub type alias Authenticated = { actor = Actor, log = Log.Fields }

mod Authentication {

    ///
    /// 何も付いていない。エンジンの要らない道（/health）とテストの既定。
    ///
    pub def anonymous(): Authenticated = { actor = Actor.Anonymous, log = Log.Fields.empty() }

    ///
    /// 認証の結果をリクエストの行の属性に。通れば user.id / api_key.name、鍵やトークンが検証に落ちていれば credential.kind = invalid。
    ///
    pub def logFields(auth: Result[Rejection, Authenticated]): Log.Fields = match auth {
        case Ok(found)       => found#log
        case Err(rejection)  => if (Rejection.isCredentialFailure(rejection)) LogFields.rejectedCredential(Log.Fields.empty()) else Log.Fields.empty()
    }

    ///
    /// エンジンごとの認証。呼ぶ側が Tx を張り、projectId の RLS の印を置いた後に呼ぶ。
    /// Admin はこのプロジェクトでの役割で、鍵と PAT の使用時刻を書く。Content は同じ認証済みユーザーで使用時刻は書かず、壊れたログインの JWT は匿名に落とし、
    /// private なプロジェクトの匿名とメンバーでない人を断る。Account はプロジェクトを見ず、鍵とプレビュートークンを断る。
    ///
    pub def resolve(deps: Deps, engine: Engine, scope: Option[ProjectId], credential: Credential): Result[Rejection, Authenticated] \ Db + IdGen + Time.Clock.Clock =
        match (engine, scope, credential) {
            // 壊れたログインの JWT: コンテンツ API は匿名に落として可視性だけ見る。他は SQL を出さずに断る
            case (Engine.Content, Some(projectId), Credential.Invalid(_)) => guardVisibility(projectId, rejected()#auth)
            case (_, _, Credential.Invalid(reason))          => Err(Rejection.Invalid(reason))
            // エンジンごとの解決。Admin は使用時刻を書き、Content は private なプロジェクトの匿名とメンバー外を断る
            case (Engine.Account, _, found)                  => resolveForAccount(deps, found)
            case (Engine.Admin, Some(projectId), found)      => resolveForProject(deps, projectId, found) |> Result.map(resolved -> { touch(resolved); resolved#auth })
            case (Engine.Content, Some(projectId), found)    => resolveForProject(deps, projectId, found) |> Result.flatMap(resolved -> guardVisibility(projectId, resolved#auth))
            // プロジェクトの要るエンジンにプロジェクト無しで来る事は無い（Main.runRoute が先に解決する）
            case (Engine.Admin, None, _)                     => bug!("管理 API はプロジェクト無しでは認証できない")
            case (Engine.Content, None, _)                   => bug!("コンテンツ API はプロジェクト無しでは認証できない")
        }

    ///
    /// 認証済みユーザーと、使用時刻を書く先。
    ///
    type alias Resolved = { auth = Authenticated, usage = Usage }

    ///
    /// 使用時刻（last_used_at）を書く先。人（ログインの JWT）や匿名は書く物が無い。
    ///
    enum Usage {
        case NotRecorded
        case ApiKeyRow(Int64, ProjectId)
        case PersonalTokenRow(Int64)
    }

    ///
    /// このプロジェクトでの認証済みユーザー（管理 API・コンテンツ API）。
    ///
    def resolveForProject(deps: Deps, projectId: ProjectId, credential: Credential): Result[Rejection, Resolved] \ Db + IdGen + Time.Clock.Clock = match credential {
        case Credential.Bearer(issuer, subject, email, name) =>
            let user = resolveUser(deps, issuer, subject, email, name);
            Ok(resolved(Accounts.actorFor(user, projectId, Login.Interactive), Usage.NotRecorded, Log.Fields.empty() |> LogFields.user(user)))
        case Credential.ApiKey(raw) =>
            Ok(match deps#auth#pepper |> Option.toOk(ApiKeyRejection.Unknown) |> Result.flatMap(pepper -> ApiKeys.resolve(pepper, raw, projectId, Time.Clock.now())) {
                case Ok(found)      => resolved(Actor.ApiKey(found#name, found#scope), Usage.ApiKeyRow(found#id, projectId), Log.Fields.empty() |> LogFields.apiKey(found#name))
                case Err(rejection) => rejectedApiKey(rejection)
            })
        case Credential.PersonalToken(raw) =>
            resolvePersonalToken(deps, raw, (user, login) -> Accounts.actorFor(user, projectId, login))
        case Credential.Preview(raw) =>
            Ok(deps#auth#pepper |> Option.flatMap(pepper -> PreviewTokens.verify(pepper, raw, projectId, Time.Clock.now()))
                |> Option.map(id -> resolved(Actor.Preview(id), Usage.NotRecorded, Log.Fields.empty() |> Log.Fields.str("id", EntryId.text(id))))
                |> Option.getWithDefault(rejected()))
        case Credential.Missing    => Ok(anonymousResolved())
        case Credential.Invalid(reason) => Err(Rejection.Invalid(reason))
    }

    ///
    /// プロジェクトを選ぶ前の認証済みユーザー（Account API）。役割は空。鍵とプレビューは断る。
    ///
    /// WhyNot: API キーを Anonymous 扱いにして通さないのは、鍵はプロジェクトの読み取り用で、組織の操作に使う理由が無く、
    /// 黙って匿名になると「鍵が効いていない」と読み違えるため。
    ///
    def resolveForAccount(deps: Deps, credential: Credential): Result[Rejection, Authenticated] \ Db + IdGen + Time.Clock.Clock = match credential {
        case Credential.Bearer(issuer, subject, email, name) =>
            let user = resolveUser(deps, issuer, subject, email, name);
            Ok({ actor = Accounts.actorWithoutProject(user, Login.Interactive), log = Log.Fields.empty() |> LogFields.user(user) })
        case Credential.PersonalToken(raw) => resolvePersonalToken(deps, raw, Accounts.actorWithoutProject) |> Result.map(found -> { touch(found); found#auth })
        case Credential.ApiKey(_)          => Err(Rejection.NotForAccount("API キー"))
        case Credential.Preview(_)         => Err(Rejection.NotForAccount("プレビュートークン"))
        case Credential.Missing            => Ok(anonymous())
        case Credential.Invalid(reason)    => Err(Rejection.Invalid(reason))
    }

    ///
    /// private なプロジェクトは、鍵か役割を持つ人しか読めない。匿名は UNAUTHENTICATED、メンバーでない人は FORBIDDEN。
    ///
    def guardVisibility(projectId: ProjectId, auth: Authenticated): Result[Rejection, Authenticated] \ DbRead =
        match (Projects.visibilityOf(projectId), auth#actor) {
            case (Visibility.Public, _)                         => Ok(auth)
            case (Visibility.Private, Actor.Anonymous)          => Err(Rejection.PrivateProject)
            case (Visibility.Private, Actor.User(_, _, Nil, _)) => Err(Rejection.NotMember)
            case (Visibility.Private, _)                        => Ok(auth)
        }

    ///
    /// 使用時刻を書く。認証済みユーザーを決めた後（RLS の本人の印が揃った後）に呼ぶ。
    ///
    def touch(found: Resolved): Unit \ DbWrite = match found#usage {
        case Usage.NotRecorded              => ()
        case Usage.ApiKeyRow(id, projectId) => discard ApiKeys.touch(id, projectId)
        case Usage.PersonalTokenRow(id)     => discard PersonalTokens.touch(id)
    }

    def resolveUser(deps: Deps, issuer: String, subject: String, email: String, name: String): User \ Db + IdGen =
        Accounts.resolveUser(deps#auth#bootstrap, { issuer = issuer, subject = subject, email = email, name = name })

    ///
    /// PAT から本人。actorFor がプロジェクトの役割を組む。pepper が無い・消えたユーザーは Unknown。
    ///
    def resolvePersonalToken(deps: Deps, raw: String, actorFor: (User, Login) -> Actor \ ef): Result[Rejection, Resolved] \ ef + DbRead + Time.Clock.Clock =
        match deps#auth#pepper {
            case None         => Err(Rejection.DeadToken(PatRejection.Unknown))
            case Some(pepper) => match PersonalTokens.resolve(pepper, raw, Time.Clock.now()) {
                case Err(rejection) => Err(Rejection.DeadToken(rejection))
                case Ok(token)      => match Accounts.resolveUserById(token#userId) {
                    case None       => Err(Rejection.DeadToken(PatRejection.Unknown))
                    case Some(user) => Ok(resolved(actorFor(user, Login.PersonalToken(token#scope)), Usage.PersonalTokenRow(token#id), Log.Fields.empty() |> LogFields.user(user)))
                }
            }
        }

    def resolved(actor: Actor, usage: Usage, log: Log.Fields): Resolved = { auth = { actor = actor, log = log }, usage = usage }

    def anonymousResolved(): Resolved = resolved(Actor.Anonymous, Usage.NotRecorded, Log.Fields.empty())

    /// 付いていた鍵やトークンが知らない物・死んだ物だった時の匿名。ログに印を残す。
    def rejected(): Resolved = resolved(Actor.Anonymous, Usage.NotRecorded, LogFields.rejectedCredential(Log.Fields.empty()))

    /// API キーが失効・期限切れ・知らない物だった時の匿名。印に加えて理由を残す。
    def rejectedApiKey(rejection: ApiKeyRejection): Resolved = resolved(Actor.Anonymous, Usage.NotRecorded, LogFields.rejectedApiKey(rejection, Log.Fields.empty()))

}
