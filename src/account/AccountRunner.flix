///
/// Account API のリゾルバが使う効果の和。DB の読み書き、CMS の業務エラー、主体、時計。Tenant が無いのが管理 API との違いで、
/// プロジェクトのユースケース（型に Tenant が付く）はここから呼べない。
///
pub type alias AccountEff = {SqlRead, SqlWrite, TransientDbErr, DbErr, CmsErr, IdGen, Session, Time.Clock.Clock}

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
    /// 1 フィールドぶん。Invalid（トークンが付いていたが検証に落ちた）と ApiKey は SQL を出さずに断る。PAT は本人として通す。
    ///
    /// WhyNot: API キーを Anonymous 扱いにして通さないのは、鍵はプロジェクトの読み取り用で、組織の操作に使う理由が無く、
    /// 黙って匿名になると「鍵が効いていない」と読み違えるため。
    ///
    def runOne(pool: Pool, deps: Deps, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ AccountEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        match context#credential {
            case Credential.Invalid(reason) => Err("認証に失敗しました: ${reason}")
            case Credential.ApiKey(_)       => Err("Account API は API キーでは使えません。ログインしてください")
            case Credential.Preview(_)      => Err("Account API はプレビュートークンでは使えません。ログインしてください")
            case credential =>
                let outcome =
                    IdGen.runWithRandom(() -> Time.Clock.runWithIO(() ->
                        DbRunner.transact(pool, None, () -> {
                            let resolved = resolve(deps, credential);
                            touch(resolved);
                            Session.runWith(resolved#actor, f)
                        })));
                DbRunner.toFieldResult(outcome)
        }

    ///
    /// 身元から主体。Bearer なら本人（初回なら users を作り、招待を受け入れる）、PAT なら本人（プロジェクトの役割は無し）、無ければ Anonymous。
    ///
    def resolve(deps: Deps, credential: Credential): Deps.Resolved \ Db + IdGen + Time.Clock.Clock = match credential {
        case Credential.Bearer(issuer, subject, email, name) =>
            { actor = Accounts.actorWithoutProject(Accounts.resolveUser(deps#auth#bootstrap, { issuer = issuer, subject = subject, email = email, name = name })), touch = Deps.Touch.None }
        case Credential.PersonalToken(raw) => Deps.resolvePersonalToken(deps, raw, Accounts.actorWithoutProject)
        case _ => { actor = Actor.Anonymous, touch = Deps.Touch.None }
    }

    /// PAT の使用時刻。Account API は Tenant を持たないので API キーの道は無い。
    def touch(resolved: Deps.Resolved): Unit \ DbWrite = match resolved#touch {
        case Deps.Touch.PersonalToken(id) => PersonalTokens.touch(id)
        case _                            => ()
    }

}
