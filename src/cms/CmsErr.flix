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
    /// 楽観ロックに負けた。currentVersion は今の版。
    ///
    def conflict(entity: Entity, id: String, currentVersion: Int32): Void

    ///
    /// 権限が無い。permission は要求した操作。
    ///
    def forbidden(permission: Permission): Void
}

mod CmsErr {

    ///
    /// CmsErr を 1 層の値にした形。境界で使う。
    ///
    pub enum CmsFailure with Eq, Order, ToString {
        case NotFound(Entity, String)
        case Invalid(List[Violation])
        case Conflict(Entity, String, Int32)
        case Forbidden(Permission)
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
            def conflict(entity, id, version, _resume) = Err(CmsFailure.Conflict(entity, id, version))
            def forbidden(permission, _resume) = Err(CmsFailure.Forbidden(permission))
        }

    ///
    /// 人が読むメッセージ。GraphQL の errors[].message に出す。
    ///
    pub def toMessage(failure: CmsFailure): String = match failure {
        case CmsFailure.NotFound(entity, id) => "${describe(entity)} '${id}' が見つかりません"
        case CmsFailure.Invalid(violations) =>
            violations |> List.map(violation -> { let Violation.Violation(path, message) = violation; "${path}: ${message}" }) |> List.join("; ")
        case CmsFailure.Conflict(entity, id, version) => "${describe(entity)} '${id}' は他で更新されています（今の version は ${version}）。読み直してから保存してください"
        case CmsFailure.Forbidden(permission) => "この操作（${Permission.text(permission)}）の権限がありません"
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
        case Entity.Organization => "organization"
        case Entity.Webhook      => "webhook"
        case Entity.WebhookDelivery => "delivery"
        case Entity.Schedule     => "schedule"
    }

}
