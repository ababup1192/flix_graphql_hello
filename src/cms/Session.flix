///
/// 今のリクエストの主体（Actor）を持つ effect。Tenant と同じ形で、Runner がリクエストごとに handler を入れる。
/// ユースケースは `Session.require(permission)` を 1 行呼ぶ。effect を足したのに呼ばない関数は「未使用の effect」で
/// コンパイルが落ちるので、権限の検査の書き忘れが見つかる。
///
pub eff Session {
    /// 今の主体
    def current(): Actor
}

mod Session {

    ///
    /// 主体を決めて f を走らせる。
    ///
    pub def runWith(actor: Actor, f: Unit -> a \ ef): a \ ef - Session =
        run f() with handler Session { def current(resume) = resume(actor) }

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
    /// 書く操作をする人としての主体。鍵・匿名・read の PAT なら forbidden（メンバー操作や組織の作成など、人しかできない物の入口）。
    ///
    pub def currentUser(): UserId \ Session + CmsErr = match Session.current() {
        case Actor.User(id, _, _)         => id
        case Actor.ReadOnlyUser(_, _, _)  => CmsErr.forbidden(Permission.WriteEntries)
        case _                            => CmsErr.forbidden(Permission.ReadDraft)
    }

    ///
    /// 自分を読む人としての主体。read の PAT でも自分（me や自分の PAT の一覧）は読める。人でなければ None。
    ///
    pub def currentUserForRead(): Option[UserId] \ Session = match Session.current() {
        case Actor.User(id, _, _)         => Some(id)
        case Actor.ReadOnlyUser(id, _, _) => Some(id)
        case _                            => None
    }

    ///
    /// 表示用の名前（email）。人でなければ "api-key" / "anonymous"。版の author に使う。
    ///
    pub def displayName(): String \ Session = match Session.current() {
        case Actor.User(_, email, _)         => email
        case Actor.ReadOnlyUser(_, email, _) => email
        case Actor.ApiKey(_)                 => "api-key"
        case Actor.Anonymous         => "anonymous"
        case Actor.Preview(_)        => "preview"
        case Actor.System            => "system"
    }

}
