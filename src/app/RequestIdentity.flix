///
/// リクエストの身元（Credential）から主体（Actor）を決める。Runner が Tx の中で呼ぶ（初回ログインの users の作成と招待の受け入れが同じ Tx に入る）。
///
/// - Bearer: 検証済みの本人（ログインの JWT）。初回なら users を作る
/// - ApiKey: pepper があれば hash で引き、このプロジェクトの生きた鍵なら scope の主体。それ以外は Anonymous
/// - PersonalToken: hash で引き、生きていれば本人（read なら読むだけ）。期限切れ・失効・知らない物は Err（黙って匿名にしない）
/// - Preview: pepper があれば署名と期限とプロジェクトを確かめ、合えばその entry のプレビュー。それ以外は Anonymous
/// - Missing / Invalid: Anonymous（Invalid は Runner が先に断る）
///
mod RequestIdentity {

    ///
    /// 決めた主体と、使用時刻を書く先、ログの span に足す身元の属性（user.id / api_key.name。生の値と email は入れない）。
    ///
    pub type alias Resolved = { actor = Actor, usage = Usage, log = Log.Fields }

    ///
    /// 使用時刻（last_used_at）を書く先。人（ログインの JWT）や匿名は書く物が無い。
    ///
    pub enum Usage with Eq, Order, ToString {
        case NotRecorded
        case ApiKeyRow(Int64, ProjectId)
        case PersonalTokenRow(Int64)
    }

    ///
    /// このプロジェクトでの主体（管理 API・コンテンツ API）。
    ///
    pub def resolveForProject(deps: Deps, projectId: ProjectId, credential: Credential): Result[PatRejection, Resolved] \ Db + IdGen + Time.Clock.Clock = match credential {
        case Credential.Bearer(issuer, subject, email, name) =>
            let user = resolveUser(deps, issuer, subject, email, name);
            Ok({ actor = Accounts.actorFor(user, projectId, Login.Interactive), usage = Usage.NotRecorded, log = Log.Fields.empty() |> LogFields.user(user) })
        case Credential.ApiKey(raw) =>
            Ok(deps#auth#pepper |> Option.flatMap(pepper -> ApiKeys.resolve(pepper, raw, projectId, Time.Clock.now()))
                |> Option.map(found -> { actor = Actor.ApiKey(found#name, found#scope), usage = Usage.ApiKeyRow(found#id, projectId), log = Log.Fields.empty() |> LogFields.apiKey(found#name) })
                |> Option.getWithDefault(anonymous()))
        case Credential.PersonalToken(raw) =>
            resolvePersonalToken(deps, raw, (user, login) -> Accounts.actorFor(user, projectId, login))
        case Credential.Preview(raw) =>
            Ok(deps#auth#pepper |> Option.flatMap(pepper -> PreviewTokens.verify(pepper, raw, projectId, Time.Clock.now()))
                |> Option.map(id -> { actor = Actor.Preview(id), usage = Usage.NotRecorded, log = Log.Fields.empty() |> Log.Fields.str("id", EntryId.text(id)) })
                |> Option.getWithDefault(anonymous()))
        case Credential.Missing    => Ok(anonymous())
        case Credential.Invalid(_) => Ok(anonymous())
    }

    ///
    /// プロジェクトを選ぶ前の主体（Account API）。役割は空。鍵とプレビューは Runner が先に断るので匿名。
    ///
    pub def resolveForAccount(deps: Deps, credential: Credential): Result[PatRejection, Resolved] \ Db + IdGen + Time.Clock.Clock = match credential {
        case Credential.Bearer(issuer, subject, email, name) =>
            let user = resolveUser(deps, issuer, subject, email, name);
            Ok({ actor = Accounts.actorWithoutProject(user, Login.Interactive), usage = Usage.NotRecorded, log = Log.Fields.empty() |> LogFields.user(user) })
        case Credential.PersonalToken(raw) => resolvePersonalToken(deps, raw, Accounts.actorWithoutProject)
        case Credential.ApiKey(_)          => Ok(anonymous())
        case Credential.Preview(_)         => Ok(anonymous())
        case Credential.Missing            => Ok(anonymous())
        case Credential.Invalid(_)         => Ok(anonymous())
    }

    ///
    /// 使用時刻を書く。主体を決めた後（RLS の印が揃った後）に呼ぶ。
    ///
    /// WhyNot: 拒まれたリクエストで別の Tx を開いてまで残さないのは、これが棚卸し用の目安だから。
    /// 業務エラーはリクエストの Tx ごと巻き戻るので、失敗した試行は残らない。それを追うのは監査ログの仕事。
    ///
    pub def touch(resolved: Resolved): Unit \ DbWrite = match resolved#usage {
        case Usage.NotRecorded                  => ()
        case Usage.ApiKeyRow(id, projectId)     => discard ApiKeys.touch(id, projectId)
        case Usage.PersonalTokenRow(id)         => discard PersonalTokens.touch(id)
    }

    /// 認証に失敗した時の GraphQL のエラー文言。Credential.Invalid と同じ形。
    pub def rejectionMessage(rejection: PatRejection): String =
        "認証に失敗しました: ${PatRejection.describe(rejection)}"

    def resolveUser(deps: Deps, issuer: String, subject: String, email: String, name: String): User \ Db + IdGen =
        Accounts.resolveUser(deps#auth#bootstrap, { issuer = issuer, subject = subject, email = email, name = name })

    ///
    /// PAT から本人の主体。actorFor がプロジェクトの役割を組む。pepper が無い・消えたユーザーは Unknown。
    ///
    def resolvePersonalToken(deps: Deps, raw: String, actorFor: (User, Login) -> Actor \ ef): Result[PatRejection, Resolved] \ ef + DbRead + Time.Clock.Clock =
        match deps#auth#pepper {
            case None         => Err(PatRejection.Unknown)
            case Some(pepper) => match PersonalTokens.resolve(pepper, raw, Time.Clock.now()) {
                case Err(rejection) => Err(rejection)
                case Ok(token)      => match Accounts.resolveUserById(token#userId) {
                    case None       => Err(PatRejection.Unknown)
                    case Some(user) => Ok({ actor = actorFor(user, Login.PersonalToken(token#scope)), usage = Usage.PersonalTokenRow(token#id), log = Log.Fields.empty() |> LogFields.user(user) })
                }
            }
        }

    def anonymous(): Resolved = { actor = Actor.Anonymous, usage = Usage.NotRecorded, log = Log.Fields.empty() }

}
