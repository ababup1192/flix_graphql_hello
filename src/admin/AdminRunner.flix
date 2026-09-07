///
/// 管理 API のリゾルバが使う効果の和。DB の読み書き、CMS の業務エラー、id の採番、今のプロジェクト、主体、asset の保存先。
///
pub type alias AdminEff = {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr, IdGen, Tenant, Session, ObjectStore, Time.Clock.Clock}

///
/// 管理 API の Runner。リゾルバ 1 つの実行を「最初の SQL で借りる接続 1 本・Tx 1 つ」に包み、身元から主体を決め、失敗を GraphQL のエラーに写す。
/// 純粋なフィールド（ContentType.name など）は SQL を出さないのでプールに触らない。
///
mod AdminRunner {

    ///
    /// プールと依存とプロジェクトから Runner を作る。エンジンはプロジェクトごとに 1 つ（AdminEngine）。
    ///
    pub def make(pool: Pool, deps: Deps, projectId: ProjectId): Runner[AdminEff] =
        (context, f) -> runOne(pool, deps, projectId, context, f)

    ///
    /// 1 フィールドぶん。身元が Invalid（ログインの JWT が付いていたが検証に落ちた）なら SQL を出さずに理由を返し、
    /// PAT が死んでいれば（期限切れ・失効・知らない）リゾルバの SQL を出さずに同じ形で断る。
    /// 主体は Tx の中で決める（初回ログインの users の作成と招待の受け入れが同じ Tx に入る）。API キーと PAT の使用時刻もここで書く。
    ///
    def runOne(pool: Pool, deps: Deps, projectId: ProjectId, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AdminEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        match context#credential {
            case Credential.Invalid(reason) => Err("認証に失敗しました: ${reason}")
            case credential =>
                let outcome =
                    IdGen.runWithRandom(() ->
                        Tenant.runWith(projectId, () ->
                            Net.Http.runWithIO(() -> Time.Clock.runWithIO(() -> ObjectStore.runWith(deps#storage, () ->
                                DbRunner.transact(pool, Some(projectId), () -> match RequestIdentity.resolveForProject(deps, projectId, credential) {
                                    case Err(rejection) => Err(RequestIdentity.rejectionMessage(rejection))
                                    case Ok(resolved)   => { RequestIdentity.touch(resolved); Session.runWith(resolved#actor, f) }
                                }))))));
                DbRunner.toFieldResult(outcome)
        }

}
