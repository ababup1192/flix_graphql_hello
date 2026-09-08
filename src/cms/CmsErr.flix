///
/// notFound / conflict の対象。
///
pub enum Entity with Eq, Order, ToString {
    case ContentType
    case Field
    case Entry
    case Version
    case Asset
    case Member
    case Invitation
    case ApiKey
    case PersonalAccessToken
    case Organization
    case Webhook
    case WebhookDelivery
    case Schedule
}

///
/// 入力の 1 つの誤り。(パス, 理由)。パスは "apiId" や "fields.title" のように GraphQL の入力に対応させる。
///
pub enum Violation with Eq, Order, ToString {
    case Violation(String, String)
}

///
/// 「ログインが要る」操作に、どんな主体が要るか。
///
pub enum LoginRequirement with Eq, Order, ToString {
    /// 書く操作をする人。ログインの JWT か write の PAT（read の PAT は不可）
    case WritingPerson
    /// ログインの JWT で来た本人。PAT や API キーは不可（鍵で鍵を作る道を塞ぐ）
    case Interactive
}

///
/// CMS の業務エラー。DbErr と同じくエフェクトで上げ、途中の関数は戻り値を包まず、境界（Runner / テスト）で 1 回受ける。
///
pub eff CmsErr {
    ///
    /// 指した物が無い。id は指した値の表示。
    ///
    def notFound(entity: Entity, id: String): Void

    ///
    /// 入力が規則に合わない。1 つ以上の Violation。
    ///
    def invalid(violations: List[Violation]): Void

    ///
    /// 楽観ロックに負けた。expectedVersion は呼び出しが読んでいたバージョン、currentVersion は今のバージョン。
    ///
    def conflict(entity: Entity, id: String, expectedVersion: Int32, currentVersion: Int32): Void

    ///
    /// 権限が無い。permission は要求した操作。
    ///
    def forbidden(permission: Permission): Void

    ///
    /// 主体の種類が合わない（役割の問題ではない）。requirement は要る主体。
    ///
    def requiresLogin(requirement: LoginRequirement): Void
}

mod CmsErr {

    ///
    /// CmsErr を 1 層の値にした形。境界で使う。
    ///
    pub enum CmsFailure with Eq, Order, ToString {
        case NotFound(Entity, String)
        case Invalid(List[Violation])
        case Conflict(Entity, String, Int32, Int32)
        case Forbidden(Permission)
        case RequiresLogin(LoginRequirement)
    }

    ///
    /// CmsErr を Result に落とす。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[CmsFailure, a] \ ef - CmsErr =
        run {
            Ok(thunk())
        } with handler CmsErr {
            def notFound(entity, id, _resume) = Err(CmsFailure.NotFound(entity, id))
            def invalid(violations, _resume) = Err(CmsFailure.Invalid(violations))
            def conflict(entity, id, expectedVersion, currentVersion, _resume) = Err(CmsFailure.Conflict(entity, id, expectedVersion, currentVersion))
            def forbidden(permission, _resume) = Err(CmsFailure.Forbidden(permission))
            def requiresLogin(requirement, _resume) = Err(CmsFailure.RequiresLogin(requirement))
        }

    ///
    /// 人が読むメッセージ。GraphQL の errors[].message に出す。
    ///
    pub def toMessage(failure: CmsFailure): String = match failure {
        case CmsFailure.NotFound(entity, id) => "${describe(entity)} '${id}' が見つかりません"
        case CmsFailure.Invalid(violations) =>
            violations |> List.map(violation -> { let Violation.Violation(path, message) = violation; "${path}: ${message}" }) |> List.join("; ")
        case CmsFailure.Conflict(entity, id, expectedVersion, currentVersion) => "${describe(entity)} '${id}' の version が一致しません（渡した ${expectedVersion}、今の ${currentVersion}）。読み直してから保存してください"
        case CmsFailure.Forbidden(permission) => "この操作（${Permission.text(permission)}）の権限がありません"
        case CmsFailure.RequiresLogin(LoginRequirement.WritingPerson) => "この操作は read の PAT ではできません。write の PAT かログインした本人で行ってください"
        case CmsFailure.RequiresLogin(LoginRequirement.Interactive)   => "この操作はログインした本人だけができます（PAT や API キーではできません）"
    }

    ///
    /// 誤りがあれば invalid を上げ、無ければ何もしない。検証関数の結果をそのまま渡す。
    ///
    pub def raiseIfAny(violations: List[Violation]): Unit \ CmsErr = match violations {
        case Nil => ()
        case _   => CmsErr.invalid(violations)
    }

    ///
    /// Option が None なら notFound。
    ///
    ///
    /// None なら invalid（入力の 1 つの誤り）。境界の parse に使う。
    ///
    pub def orInvalid(path: String, message: String, value: Option[a]): a \ CmsErr = match value {
        case Some(found) => found
        case None        => CmsErr.invalid(Violation.Violation(path, message) :: Nil)
    }

    pub def orNotFound(entity: Entity, id: String, value: Option[a]): a \ CmsErr = match value {
        case Some(found) => found
        case None        => CmsErr.notFound(entity, id)
    }

    def describe(entity: Entity): String = match entity {
        case Entity.ContentType => "content type"
        case Entity.Field       => "field"
        case Entity.Entry       => "entry"
        case Entity.Version     => "version"
        case Entity.Asset       => "asset"
        case Entity.Member      => "member"
        case Entity.Invitation  => "invitation"
        case Entity.ApiKey      => "api key"
        case Entity.PersonalAccessToken => "personal access token"
        case Entity.Organization => "organization"
        case Entity.Webhook      => "webhook"
        case Entity.WebhookDelivery => "delivery"
        case Entity.Schedule     => "schedule"
    }

}
