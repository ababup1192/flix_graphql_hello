///
/// Tx の失敗（ApplicationFailure。業務エラーと DB の失敗）と認証の失敗を、GraphQL の errors[] に出す形（message と extensions）へ写す。
/// 分類 → extensions.code の対応を持つのはここだけで、管理 API・Account API・コンテンツ API は
/// 全部 DbRunner.toFieldResult 経由でここを通る。
///
/// WhyNot: ドメイン（src/cms）に置かないのは、ドメインが GraphQL を知らない決まりのため。
/// src/graphql に置かないのは、graphql 層は見本のスキーマだけでも動く境界で、CMS の業務エラーを知らないため。
///
mod GraphqlErrors {

    use CmsErr.CmsFailure
    use DbError.Failure

    ///
    /// 業務エラーの分類。CmsFailure に case を足すとここが落ちる。
    ///
    pub def codeOf(failure: CmsFailure): ErrorCode = match failure {
        case CmsFailure.NotFound(_, _)        => ErrorCode.NotFound
        case CmsFailure.Invalid(_)            => ErrorCode.Invalid
        case CmsFailure.Conflict(_, _, _, _)  => ErrorCode.Conflict
        case CmsFailure.Forbidden(_)          => ErrorCode.Forbidden
        case CmsFailure.RequiresLogin(_)      => ErrorCode.RequiresLogin
    }

    ///
    /// 業務エラーを GraphQL のエラーに。message は人が読む文のまま、extensions に分類と手掛かりを載せる。
    ///
    pub def toFieldError(failure: CmsFailure): FieldError =
        FieldError.make(codeOf(failure), CmsErr.toMessage(failure), extrasOf(failure))

    ///
    /// 入力の誤り 1 つ。ユースケースへ入る前（引数の組み合わせ）に境界で気づいた物に使う。
    ///
    pub def invalid(field: String, message: String): FieldError =
        FieldError.make(ErrorCode.Invalid, message, violations(Violation.Violation(field, message) :: Nil))

    ///
    /// 身元の検証に落ちた時のエラー（壊れた JWT、死んだ PAT）。
    ///
    pub def unauthenticated(message: String): FieldError =
        FieldError.of(ErrorCode.Unauthenticated, message)

    ///
    /// 主体の種類が合わない時のエラー（API キーで Account API を使う等）。
    ///
    pub def requiresLogin(message: String): FieldError =
        FieldError.of(ErrorCode.RequiresLogin, message)

    ///
    /// INTERNAL の外向きの文。
    ///
    /// WhyNot: Failure の説明を入れないのは、`retryExhausted timeout 0 after 3 attempts` のような内部の再試行の言葉と
    /// DB の事情が外に出るため。詳細は同じ requestId のログの行（error.kind / error.message）にある。
    ///
    pub def internalMessage(): String = "データベースの処理に失敗しました"

    ///
    /// Tx の失敗。業務エラーは分類ごとの extensions、DB の失敗はクライアントからは直せないので一時的な物も直らない物も INTERNAL。
    /// INTERNAL にだけ extensions.requestId を付け、問い合わせとログの行を繋げる。
    ///
    /// WhyNot: 他の分類に requestId を付けないのは、NOT_FOUND / INVALID はクライアントが自分で直せる物で、
    /// 応答ヘッダの X-Request-Id で十分なため。INTERNAL は「この id を添えて問い合わせてください」と言う場面。
    ///
    /// WhyNot: Transient を別の分類（UNAVAILABLE など）にしないのは、Runner が再試行を使い切った後は Permanent の
    /// RetryExhausted で来るので、ここに Transient が来るのは再試行を通らない道だけのため。
    ///
    pub def fromApplicationFailure(requestId: Option[String], failure: ApplicationFailure): FieldError = match failure {
        case ApplicationFailure.Domain(found)                       => toFieldError(found)
        case ApplicationFailure.Infrastructure(Failure.Transient(_)) => internal(requestId)
        case ApplicationFailure.Infrastructure(Failure.Permanent(_)) => internal(requestId)
    }

    def internal(requestId: Option[String]): FieldError =
        FieldError.make(ErrorCode.Internal, internalMessage(),
            requestId |> Option.map(id -> Map#{ "requestId" => Value.Str(id) }) |> Option.getWithDefault(Map.empty()))

    ///
    /// code 以外の extensions。invalid は violations、notFound と conflict は何のどの id か（conflict は版も）。
    ///
    def extrasOf(failure: CmsFailure): Map[String, Value] = match failure {
        case CmsFailure.Invalid(found)        => violations(found)
        case CmsFailure.NotFound(entity, id)  => target(entity, id)
        case CmsFailure.Conflict(entity, id, expectedVersion, currentVersion) =>
            target(entity, id)
                |> Map.insert("expectedVersion", Value.Int(expectedVersion))
                |> Map.insert("actualVersion", Value.Int(currentVersion))
        case CmsFailure.Forbidden(_)          => Map.empty()
        case CmsFailure.RequiresLogin(_)      => Map.empty()
    }

    ///
    /// どの物のどの id か。
    ///
    def target(entity: Entity, id: String): Map[String, Value] =
        Map#{ "entity" => Value.Str(entityName(entity)), "id" => Value.Str(id) }

    ///
    /// extensions.violations。入力のどこが規則に合わないか。
    ///
    def violations(found: List[Violation]): Map[String, Value] =
        Map#{ "violations" => Value.List(List.map(toViolation, found)) }

    ///
    /// 入力の 1 つの誤り。field はどの入力か（"apiId" や "fields.title"）。
    ///
    def toViolation(violation: Violation): Value =
        let Violation.Violation(path, message) = violation;
        Value.Obj(Map#{ "field" => Value.Str(path), "message" => Value.Str(message) })

    ///
    /// extensions.entity に出す名前。クライアントが分岐に使うので、綴りは変えない。
    ///
    pub def entityName(entity: Entity): String = match entity {
        case Entity.ContentType         => "ContentType"
        case Entity.Field               => "Field"
        case Entity.Entry               => "Entry"
        case Entity.Version             => "Version"
        case Entity.Asset               => "Asset"
        case Entity.Member              => "Member"
        case Entity.Invitation          => "Invitation"
        case Entity.ApiKey              => "ApiKey"
        case Entity.PersonalAccessToken => "PersonalAccessToken"
        case Entity.Organization        => "Organization"
        case Entity.Webhook             => "Webhook"
        case Entity.WebhookDelivery     => "WebhookDelivery"
        case Entity.Schedule            => "Schedule"
    }

}
