///
/// 入力の 1 つの誤り。(パス, 理由)。パスは "apiId" や "fields[2].apiId" のように GraphQL の入力に対応させる。
///
pub enum Violation with Eq, Order, ToString {
    case Violation(String, String)
}

///
/// CMS の業務エラー。DbErr と同じくエフェクトで上げ、途中の関数は戻り値を包まず、境界（Runner / テスト）で 1 回受ける。
///
pub eff CmsErr {
    ///
    /// 指した物が無い。what は "content type" のような種類、id は指した値。
    ///
    def notFound(what: String, id: String): Void

    ///
    /// 入力が規則に合わない。1 つ以上の Violation。
    ///
    def invalid(violations: List[Violation]): Void
}

mod CmsErr {

    ///
    /// CmsErr を 1 層の値にした形。境界で使う。
    ///
    pub enum CmsFailure with Eq, Order, ToString {
        case NotFound(String, String)
        case Invalid(List[Violation])
    }

    ///
    /// CmsErr を Result に落とす。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[CmsFailure, a] \ ef - CmsErr =
        run {
            Ok(thunk())
        } with handler CmsErr {
            def notFound(what, id, _resume) = Err(CmsFailure.NotFound(what, id))
            def invalid(violations, _resume) = Err(CmsFailure.Invalid(violations))
        }

    ///
    /// 人が読むメッセージ。GraphQL の errors[].message に出す。
    ///
    pub def toMessage(failure: CmsFailure): String = match failure {
        case CmsFailure.NotFound(what, id) => "${what} '${id}' が見つかりません"
        case CmsFailure.Invalid(violations) =>
            violations |> List.map(violation -> { let Violation.Violation(path, message) = violation; "${path}: ${message}" }) |> List.join("; ")
    }

    ///
    /// 誤りがあれば invalid を上げ、無ければ何もしない。検証関数の結果をそのまま渡す。
    ///
    pub def raiseIfAny(violations: List[Violation]): Unit \ CmsErr = match violations {
        case Nil => ()
        case _   => CmsErr.invalid(violations)
    }

}
