///
/// 管理 API のリゾルバが使う効果の和。DB の読み書き、CMS の業務エラー、id の採番、今のプロジェクト、認証済みユーザー、asset の保存先。
///
pub type alias AdminEff = Db + CmsErr + IdGen + Tenant + Session + ObjectStore + Time.Clock.Clock + Log

///
/// 管理 API の Runner。リゾルバ 1 つの実行を「最初の SQL で借りる接続 1 本・Tx 1 つ」に包み、認証して、失敗を GraphQL のエラーに写す。
/// 純粋なフィールド（ContentType.name など）は SQL を出さないのでプールに触らない。
///
mod AdminRunner {

    ///
    /// プールと依存とプロジェクトから Runner を作る。エンジンはプロジェクトごとに 1 つ（AdminEngine）。
    ///
    pub def make(pool: Pool, deps: Deps, projectId: ProjectId): Runner[AdminEff] =
        (context, f) -> runOne(pool, deps, projectId, context, f)

    ///
    /// 1 フィールドぶん。Credential が Invalid（ログインの JWT が付いていたが検証に落ちた）なら SQL を出さずに理由を返し、
    /// PAT が死んでいれば（期限切れ・失効・知らない）リゾルバの SQL を出さずに同じ形で断る。
    /// 認証は自分の Tx で行い（初回ログインの users の作成と招待の受け入れが同じ Tx に入る）、API キーと PAT の使用時刻もそこで書く。
    /// Log は deps の出力先で入れ直し、リクエストの span（context の log）と認証の属性を行に付ける。
    ///
    def runOne(pool: Pool, deps: Deps, projectId: ProjectId, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AdminEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        match context#credential {
            case Credential.Invalid(reason) => Err(GraphqlErrors.unauthenticated("認証に失敗しました: ${reason}"))
            case credential =>
                AppEnv.runWith(deps, context#log, projectId, () -> {
                    let requestId = LogFields.requestIdOf(context#log);
                    match authenticate(pool, deps, projectId, context#observe, credential) {
                        case Err(failure)       => DbRunner.toFieldResult(requestId, Err(failure))
                        case Ok(Err(rejection)) => { (context#observe)(LogFields.rejectedCredential(Log.Fields.empty())); Err(GraphqlErrors.unauthenticated(RequestIdentity.rejectionMessage(rejection))) }
                        case Ok(Ok(resolved))   => {
                            (context#observe)(resolved#log);
                            Log.withFields(resolved#log, () -> DbRunner.transactObserved(pool, Some(projectId), context#observe, resolved#actor, f) |> DbRunner.toFieldResult(requestId))
                        }
                    }
                })
        }

    ///
    /// 認証（Credential → Actor）を自分の Tx で行い、鍵と PAT の使用時刻を書く。
    ///
    def authenticate(pool: Pool, deps: Deps, projectId: ProjectId, observe: Log.Fields -> Unit \ IO, credential: Credential): Result[ApplicationFailure, Result[PatRejection, RequestIdentity.Resolved]] \ IO + IdGen + Time.Clock.Clock =
        DbRunner.withTxObserved(pool, Some(projectId), observe, () ->
            RequestIdentity.resolveForProject(deps, projectId, credential) |> Result.map(resolved -> { RequestIdentity.touch(resolved); resolved }))
            |> Result.mapErr(ApplicationFailure.Infrastructure)

}
