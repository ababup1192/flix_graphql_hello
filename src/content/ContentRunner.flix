///
/// コンテンツ API のリゾルバが使う効果の和。読むだけ。書く関数を呼べばコンパイルで落ちる。
///
pub type alias ContentEff = DbRead + CmsErr + Tenant + Session + ObjectStore + Log

///
/// コンテンツ API の Runner。読むだけなので Tx は要らないが、フィールド単位で接続を借り直さないよう
/// withLazyTx で「最初の SQL で借りて最後に返す」にする。身元から主体を決め、private なプロジェクトは鍵の無い読み取りを止める。
///
/// WhyNot: API キーと PAT の使用時刻（last_used_at）をここで書かないのは、CDN 越しに大量に来る読み取りの道に UPDATE を足さないため。
/// 「鍵が生きているか」は管理 API の使用で分かる。
///
mod ContentRunner {

    ///
    /// プールから Runner を作る。
    ///
    pub def make(pool: Pool, deps: Deps, projectId: ProjectId): Runner[ContentEff] =
        (context, f) -> runOne(pool, deps, projectId, context, f)

    def runOne(pool: Pool, deps: Deps, projectId: ProjectId, context: Context, f: Unit -> Result[FieldError, JavaValue.Boxed] \ ContentEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        run {
            let outcome =
                Tenant.runWith(projectId, () ->
                    Net.Http.runWithIO(() -> Time.Clock.runWithIO(() -> ObjectStore.runWith(deps#storage, () -> IdGen.runWithRandom(() ->
                        DbRunner.transactObserved(pool, Some(projectId), context#observe, () -> match RequestIdentity.resolveForProject(deps, projectId, context#credential) {
                            case Err(rejection) => { (context#observe)(LogFields.rejectedCredential(Log.Fields.empty())); Err(GraphqlErrors.unauthenticated(RequestIdentity.rejectionMessage(rejection))) }
                            case Ok(resolved)   => { (context#observe)(resolved#log); guardVisibility(projectId, resolved#actor); Log.withFields(resolved#log, () -> Session.runWith(resolved#actor, () -> Db.guard(f))) }
                        }))))));
            DbRunner.toFieldResult(LogFields.requestIdOf(context#log), outcome)
        } with Log.withFields(context#log)
          with Log.runWith(deps#log)

    ///
    /// private なプロジェクトは、鍵か役割を持つ人しか読めない。
    ///
    def guardVisibility(projectId: ProjectId, actor: Actor): Unit \ DbRead + CmsErr =
        match (Projects.visibilityOf(projectId), actor) {
            case (Visibility.Public, _)                => ()
            case (Visibility.Private, Actor.Anonymous) => CmsErr.invalid(Violation.Violation("auth", "このプロジェクトは非公開です。API キーを X-Api-Key で渡してください") :: Nil)
            case (Visibility.Private, Actor.User(_, _, Nil, _)) => CmsErr.invalid(Violation.Violation("auth", "このプロジェクトのメンバーではありません") :: Nil)
            case (Visibility.Private, _)               => ()
        }

}
