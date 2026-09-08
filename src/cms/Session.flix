///
/// 今のリクエストの主体（Actor）を持つ effect。Tenant と同じ形で、Runner がリクエストごとに handler を入れる。
/// ユースケースの入口は権限の証明 `Granted[p]`（`Session.grant()` が作る）を引数で受け、呼ぶ側が証明を作って渡す。
/// 証明を作らずに呼ぶと引数が足りずにコンパイルが落ちるので、権限の検査の書き忘れが見つかる。
/// `Session.require(permission)` は証明に移していないユースケースの形（第 2 段で全部を移す）。
///
pub eff Session {
    /// 今の主体
    def current(): Actor
}

mod Session {

    ///
    /// 権限の証明の本体（署名では alias の `Granted[p]` で書く）。中身の Seal はこの mod の外からは作れないので、作れるのは grant / grantOn だけ。
    ///
    pub enum Granted[_p](Seal)

    enum Seal {
        case Seal
    }

    ///
    /// 主体を決めて f を走らせる。
    ///
    pub def runWith(actor: Actor, f: Unit -> a \ ef): a \ ef - Session =
        run f() with handler Session { def current(resume) = resume(actor) }

    ///
    /// この操作の証明。できなければ forbidden。対象は指定しない。
    /// p は渡す先の引数の型（`Granted[ManageTypes]` など）から決まる。
    ///
    pub def grant(): Granted[p] \ Session + CmsErr with Perm[p] =
        grantOn(Authz.anyResource())

    ///
    /// この対象に対するこの操作の証明。できなければ forbidden。
    ///
    pub def grantOn(resource: Authz.Resource): Granted[p] \ Session + CmsErr with Perm[p] =
        let proof = Granted.Granted(Seal.Seal);
        requireOn(Perm.permission(proof), resource);
        proof

    ///
    /// この操作ができなければ forbidden。対象は指定しない。
    ///
    pub def require(permission: Permission): Unit \ Session + CmsErr =
        requireOn(permission, Authz.anyResource())

    ///
    /// この対象に対してこの操作ができなければ forbidden。
    ///
    pub def requireOn(permission: Permission, resource: Authz.Resource): Unit \ Session + CmsErr =
        if (Authz.can(Session.current(), permission, resource)) () else CmsErr.forbidden(permission)

    ///
    /// 書く操作をする人としての主体。read の PAT なら requiresLogin、鍵・匿名・プレビューなら forbidden
    /// （メンバー操作や組織の作成など、人しかできない物の入口）。
    ///
    pub def currentUser(): UserId \ Session + CmsErr = match Session.current() {
        case Actor.User(id, _, _, Login.Interactive)                       => id
        case Actor.User(id, _, _, Login.PersonalToken(PatScope.Write))     => id
        case Actor.User(_, _, _, Login.PersonalToken(PatScope.Read))       => CmsErr.requiresLogin(LoginRequirement.WritingPerson)
        case _                                                             => CmsErr.forbidden(Permission.ReadDraft)
    }

    ///
    /// ログインの JWT で来た本人（かサーバ自身）でなければ requiresLogin。鍵や PAT の発行の入口（鍵で鍵を作る道を塞ぐ）。
    ///
    pub def requireInteractive(): Unit \ Session + CmsErr = match Session.current() {
        case Actor.User(_, _, _, Login.Interactive) => ()
        case Actor.System                           => ()
        case _                                      => CmsErr.requiresLogin(LoginRequirement.Interactive)
    }

    ///
    /// 自分を読む人としての主体。read の PAT でも自分（me や自分の PAT の一覧、自分の組織）は読める。人でなければ None。
    ///
    pub def currentUserForRead(): Option[UserId] \ Session = match Session.current() {
        case Actor.User(id, _, _, _) => Some(id)
        case _                       => None
    }

    ///
    /// 表示用の名前。人なら email、鍵なら "api-key:<鍵の名前>"。版の author に使う。
    ///
    pub def displayName(): String \ Session = match Session.current() {
        case Actor.User(_, email, _, _) => email
        case Actor.ApiKey(name, _)      => "api-key:${name}"
        case Actor.Anonymous            => "anonymous"
        case Actor.Preview(_)           => "preview"
        case Actor.System               => "system"
    }

}
