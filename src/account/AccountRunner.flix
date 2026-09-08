///
/// Account API のリゾルバが使う効果の和。DB の読み書き、CMS の業務エラー、主体、時計。Tenant が無いのが管理 API との違いで、
/// プロジェクトのユースケース（型に Tenant が付く）はここから呼べない。
///
pub type alias AccountEff = Db + CmsErr + IdGen + Session + Time.Clock.Clock

///
/// Account API の Runner。リゾルバ 1 つを「最初の SQL で借りる接続 1 本・Tx 1 つ」に包み、身元から主体を決め、失敗を GraphQL のエラーに写す。
///
mod AccountRunner {

    ///
    /// プールと依存から Runner を作る。プロジェクトを持たないのでエンジンは 1 つ。
    ///
    pub def make(pool: Pool, deps: Deps): Runner[AccountEff] =
        (context, f) -> runOne(pool, deps, context, f)

    ///
    /// 1 フィールドぶん。Invalid（ログインの JWT が付いていたが検証に落ちた）と ApiKey は SQL を出さずに断る。PAT は本人として通し、
    /// 死んだ PAT（期限切れ・失効・知らない）はリゾルバの SQL を出さずに同じ形で断る。
    ///
    /// WhyNot: API キーを Anonymous 扱いにして通さないのは、鍵はプロジェクトの読み取り用で、組織の操作に使う理由が無く、
    /// 黙って匿名になると「鍵が効いていない」と読み違えるため。
    ///
    def runOne(pool: Pool, deps: Deps, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AccountEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        match context#credential {
            case Credential.Invalid(reason) => Err(GraphqlErrors.unauthenticated("認証に失敗しました: ${reason}"))
            case Credential.ApiKey(_)       => Err(GraphqlErrors.requiresLogin("Account API は API キーでは使えません。ログインしてください"))
            case Credential.Preview(_)      => Err(GraphqlErrors.requiresLogin("Account API はプレビュートークンでは使えません。ログインしてください"))
            case credential =>
                let outcome =
                    IdGen.runWithRandom(() -> Time.Clock.runWithIO(() ->
                        DbRunner.transact(pool, None, () -> match RequestIdentity.resolveForAccount(deps, credential) {
                            case Err(rejection) => Err(GraphqlErrors.unauthenticated(RequestIdentity.rejectionMessage(rejection)))
                            case Ok(resolved)   => { RequestIdentity.touch(resolved); Session.runWith(resolved#actor, () -> DbRunner.guarded(f)) }
                        })));
                DbRunner.toFieldResult(outcome)
        }

}
