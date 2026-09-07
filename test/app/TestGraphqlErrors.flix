///
/// GraphqlErrors: 業務エラーを GraphQL の errors[] の形（message と extensions）へ写す。
/// message は人が読む文のまま、extensions はクライアントが分岐に使う物。
///
mod TestGraphqlErrors {

    use CmsErr.CmsFailure

    /// 分類ごとの見本。CmsFailure に case を足すと GraphqlErrors.codeOf が落ちる。
    def failures(): List[CmsFailure] = List#{
        CmsFailure.NotFound(Entity.Entry, "e1"),
        CmsFailure.Invalid(Violation.Violation("apiId", "小文字で始めてください") :: Nil),
        CmsFailure.Conflict(Entity.Entry, "e1", 1, 3),
        CmsFailure.Forbidden(Permission.ManageTypes),
        CmsFailure.RequiresLogin(LoginRequirement.Interactive)
    }

    /// 全部の分類が extensions.code の文字列に写る。
    @Test
    def testGraphqlErrorsCodeOfEveryFailure(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "NOT_FOUND", "INVALID", "CONFLICT", "FORBIDDEN", "REQUIRES_LOGIN" },
            failures() |> List.map(failure -> ErrorCode.text(GraphqlErrors.codeOf(failure))))

    /// 身元と設定の失敗にも code が付く。
    @Test
    def testGraphqlErrorsCodeOfBoundaryErrors(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ "UNAUTHENTICATED", "REQUIRES_LOGIN", "INVALID", "INTERNAL" },
            List#{
                GraphqlErrors.unauthenticated("認証に失敗しました: 期限切れ"),
                GraphqlErrors.requiresLogin("ログインしてください"),
                GraphqlErrors.invalid("id", "id か apiId を指定してください"),
                FieldError.internal("database error")
            } |> List.map(error -> ErrorCode.text(FieldError.code(error))))

    /// message は日本語の文のまま（人が読む物）。
    @Test
    def testGraphqlErrorsKeepsMessage(): Unit \ Assert =
        Assert.assertEq(
            expected = "entry 'e1' が見つかりません",
            FieldError.message(GraphqlErrors.toFieldError(CmsFailure.NotFound(Entity.Entry, "e1"))))

    /// invalid の extensions は code と violations（field と message の配列）。
    @Test
    def testGraphqlErrorsInvalidHasViolations(): Unit \ Assert =
        Assert.assertEq(
            expected = Map#{
                "code" => Value.Str("INVALID"),
                "violations" => Value.List(Value.Obj(Map#{ "field" => Value.Str("apiId"), "message" => Value.Str("小文字で始めてください") }) :: Nil)
            },
            FieldError.extensions(GraphqlErrors.toFieldError(CmsFailure.Invalid(Violation.Violation("apiId", "小文字で始めてください") :: Nil))))

    /// notFound の extensions は、何の（entity）どの id かを持つ。
    @Test
    def testGraphqlErrorsNotFoundHasTarget(): Unit \ Assert =
        Assert.assertEq(
            expected = Map#{ "code" => Value.Str("NOT_FOUND"), "entity" => Value.Str("Entry"), "id" => Value.Str("e1") },
            FieldError.extensions(GraphqlErrors.toFieldError(CmsFailure.NotFound(Entity.Entry, "e1"))))

    /// conflict の extensions は、対象に加えて読んでいた版と今の版を持つ。
    @Test
    def testGraphqlErrorsConflictHasVersions(): Unit \ Assert =
        Assert.assertEq(
            expected = Map#{
                "code" => Value.Str("CONFLICT"), "entity" => Value.Str("Entry"), "id" => Value.Str("e1"),
                "expectedVersion" => Value.Int(1), "actualVersion" => Value.Int(3)
            },
            FieldError.extensions(GraphqlErrors.toFieldError(CmsFailure.Conflict(Entity.Entry, "e1", 1, 3))))

    /// forbidden の extensions は code だけ（どの権限かは message にある）。
    @Test
    def testGraphqlErrorsForbiddenHasCodeOnly(): Unit \ Assert =
        Assert.assertEq(
            expected = Map#{ "code" => Value.Str("FORBIDDEN") },
            FieldError.extensions(GraphqlErrors.toFieldError(CmsFailure.Forbidden(Permission.ManageTypes))))

}
