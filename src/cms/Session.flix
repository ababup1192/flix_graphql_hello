///
/// 今のリクエストの主体（Actor）を持つ effect。Tenant と同じ形で、Runner がリクエストごとに handler を入れる。
/// ユースケースの入口は権限の証明 `Granted[p]`（`Session.grant()` が作る）を引数で受け、呼ぶ側が証明を作って渡す。
/// 証明を作らずに呼ぶと引数が足りずにコンパイルが落ちるので、権限の検査の書き忘れが見つかる。
/// ユースケースが Session を持つのは、主体そのものを読む時（`currentUser()` / `displayName()` など）だけ。
///
pub eff Session {
    /// 今の主体
    def current(): Actor
}

mod Session {

    ///
    /// 権限の証明の本体（署名では alias の `Granted[p]` で書く）。中身の Seal はこの mod の外からは作れないので、作れるのはこの mod の grant 系だけ。
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
        let proof = seal();
        requireOn(Perm.permission(proof), resource);
        proof

    ///
    /// できればこの操作の証明、できなければ None（forbidden にしない）。
    /// 「公開中なら取り下げも要る」のように、操作の途中で条件付きで要る証明を呼ぶ側が持てるだけ渡す時に使う。
    ///
    pub def tryGrant(): Option[Granted[p]] \ Session with Perm[p] =
        let proof = seal();
        if (Authz.can(Session.current(), Perm.permission(proof), Authz.anyResource())) Some(proof) else None

    ///
    /// ログインの JWT で来た本人（かサーバ自身）の証明。でなければ requiresLogin。鍵や PAT の発行の入口が受ける。
    ///
    pub def grantInteractive(): Granted[Interactive] \ Session + CmsErr =
        requireInteractive();
        seal()

    ///
    /// WriteEntries の証明から ReadDraft の証明。判定はし直さない。
    ///
    /// WhyNot: 呼ぶ側に `Session.grant()` で ReadDraft を作り直させないのは、writeEntries を持つ主体（writer 以上、write の鍵）は
    /// Authz の Implies で全部 readDraft も持ち、判定が常に通るため。この含意は TestGranted が表で見張る。
    ///
    pub def readDraftOfWriter(_proof: Granted[WriteEntries]): Granted[ReadDraft] =
        seal()

    ///
    /// PublishEntries の証明から ReadDraft の証明。判定はし直さない（理由は readDraftOfWriter と同じ。editor 以上は readDraft を持つ）。
    ///
    pub def readDraftOfPublisher(_proof: Granted[PublishEntries]): Granted[ReadDraft] =
        seal()

    ///
    /// ManageTypes の証明から ReadDraft の証明。判定はし直さない（理由は readDraftOfWriter と同じ。editor 以上は readDraft を持つ）。
    ///
    pub def readDraftOfTypeManager(_proof: Granted[ManageTypes]): Granted[ReadDraft] =
        seal()

    /// 証明の値。この mod の中だけ。
    def seal(): Granted[p] = Granted.Granted(Seal.Seal)

    /// この対象に対してこの操作ができなければ forbidden。grant 系の中身。
    def requireOn(permission: Permission, resource: Authz.Resource): Unit \ Session + CmsErr =
        if (Authz.can(Session.current(), permission, resource)) () else CmsErr.forbidden(permission)

    /// ログインの JWT で来た本人（かサーバ自身）でなければ requiresLogin。grantInteractive の中身。
    def requireInteractive(): Unit \ Session + CmsErr = match Session.current() {
        case Actor.User(_, _, _, Login.Interactive) => ()
        case Actor.System                           => ()
        case _                                      => CmsErr.requiresLogin(LoginRequirement.Interactive)
    }

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

    ///
    /// 監査に載せる主体（種類・id・表示名）。name は `displayName()` と同じ。人の id は users.public_id（管理 API に出るので内部の連番を出さない）。
    ///
    /// WhyNot: 鍵の id を public id にしない。`Actor.ApiKey` は名前と scope しか持たず、public id を足すと Actor を組む
    /// 全ての場所（テストを含めて 27 か所）が変わるため。同名で再発行した鍵は `api_key.created` の行の時刻で見分ける
    /// （public id に替える時は Actor に足して、ここを 1 行変える）。
    ///
    /// WhyNot: `Actor.User` に public id を足さない（Actor.User を組む・分ける場所が 31 か所）。監査の書き込みは稀なので、
    /// その時に users を 1 回引く方が小さい。
    ///
    pub def actorRef(): ActorRef \ Session + DbRead =
        actorRefOf(Session.current(), publicIdOf)

    ///
    /// 主体 → 監査に載せる主体。人の id は publicId で引く（純粋な部分。テストは引く関数を差し替える）。
    ///
    pub def actorRefOf(actor: Actor, publicId: UserId -> String \ ef): ActorRef \ ef = match actor {
        case Actor.User(id, email, _, Login.Interactive)      => { kind = ActorKind.User, id = publicId(id), name = email }
        case Actor.User(id, email, _, Login.PersonalToken(_)) => { kind = ActorKind.Pat, id = publicId(id), name = email }
        case Actor.ApiKey(name, _)                            => { kind = ActorKind.ApiKey, id = name, name = "api-key:${name}" }
        case Actor.Anonymous                                  => { kind = ActorKind.Anonymous, id = "", name = "anonymous" }
        case Actor.Preview(entryId)                           => { kind = ActorKind.Preview, id = EntryId.text(entryId), name = "preview" }
        case Actor.System                                     => { kind = ActorKind.System, id = "", name = "system" }
    }

    /// 人の users.public_id。認証済みの人の行が無い事は無いが、無ければ空（監査の書き込みを止めない）。
    def publicIdOf(id: UserId): String \ DbRead =
        AuthQueries.findUserById(UserId.toInt64(id)) |> Option.map(row -> row#publicId) |> Option.getWithDefault("")

}
