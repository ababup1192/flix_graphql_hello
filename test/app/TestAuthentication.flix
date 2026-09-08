///
/// Authentication の純粋な部分: Rejection の 5 腕（Invalid / DeadToken / NotForAccount / PrivateProject / NotMember）の code と message、
/// 鍵やトークンの検証に落ちた物かの判定、認証の結果がリクエストの行に積む属性。DB は要らない。
/// どの Credential × エンジン × プロジェクトで各腕が出るかは test/Pg/TestAuthenticationPg。
///
mod TestAuthentication {

    /// 5 腕の見本。DeadToken は PatRejection の 3 腕を全部並べる。Rejection に case を足すと code / message の match が落ちる。
    def rejections(): List[Rejection] = List#{
        Rejection.Invalid("JWT は無し"),
        Rejection.DeadToken(PatRejection.Unknown),
        Rejection.DeadToken(PatRejection.Expired),
        Rejection.DeadToken(PatRejection.Revoked),
        Rejection.NotForAccount("API キー"),
        Rejection.NotForAccount("プレビュートークン"),
        Rejection.PrivateProject,
        Rejection.NotMember
    }

    /// 腕ごとの extensions.code。壊れた JWT・死んだ PAT・private の匿名は UNAUTHENTICATED、Account API に鍵は REQUIRES_LOGIN、メンバー外は FORBIDDEN。
    @Test
    def testRejectionCodeTable(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                "UNAUTHENTICATED",
                "UNAUTHENTICATED", "UNAUTHENTICATED", "UNAUTHENTICATED",
                "REQUIRES_LOGIN", "REQUIRES_LOGIN",
                "UNAUTHENTICATED",
                "FORBIDDEN"
            },
            rejections() |> List.map(rejection -> ErrorCode.text(Rejection.code(rejection))))

    /// 腕ごとの人が読む文言。Invalid は理由、DeadToken は PatRejection の理由、NotForAccount は何で来たかが入る。
    @Test
    def testRejectionMessageTable(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                "認証に失敗しました: JWT は無し",
                "認証に失敗しました: PAT が見つかりません",
                "認証に失敗しました: PAT が期限切れです",
                "認証に失敗しました: PAT は失効しています",
                "Account API は API キーでは使えません。ログインしてください",
                "Account API は プレビュートークンでは使えません。ログインしてください",
                "このプロジェクトは非公開です。API キーを X-Api-Key で渡してください",
                "このプロジェクトのメンバーではありません"
            },
            rejections() |> List.map(Rejection.message))

    /// 付いていた鍵やトークンが検証に落ちた物（ログの credential.kind を invalid にする物）は Invalid と DeadToken だけ。
    @Test
    def testRejectionIsCredentialFailureTable(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{ true, true, true, true, false, false, false, false },
            rejections() |> List.map(Rejection.isCredentialFailure))

    ///
    /// 認証の結果がリクエストの行に積む属性:
    ///   通れば認証が組んだ属性（api_key.name など）をそのまま
    ///   鍵やトークンの検証に落ちていれば credential.kind = invalid
    ///   それ以外の断り（Account API に鍵、private の匿名・メンバー外）は何も積まない
    ///
    @Test
    def testLogFieldsTable(): Unit \ Assert =
        let found = { actor = Actor.ApiKey("ci", ApiKeyScope.Read), log = Log.Fields.empty() |> LogFields.apiKey("ci") };
        let cases: List[(Result[Rejection, Authenticated], List[(String, Value)])] = List#{
            (Ok(found),                                             List#{ ("api_key.name", Value.Str("ci")) }),
            (Err(Rejection.Invalid("JWT は無し")),                    List#{ ("credential.kind", Value.Str("invalid")) }),
            (Err(Rejection.DeadToken(PatRejection.Revoked)),        List#{ ("credential.kind", Value.Str("invalid")) }),
            (Err(Rejection.NotForAccount("API キー")),              Nil),
            (Err(Rejection.PrivateProject),                         Nil),
            (Err(Rejection.NotMember),                              Nil)
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (auth, _) -> Authentication.logFields(auth) |> Map.toList))

    /// 何も付いていない認証済みユーザーは Anonymous で、行に積む属性は無い。
    @Test
    def testAnonymousHasNoFields(): Unit \ Assert =
        Assert.assertEq(
            expected = (Actor.Anonymous, Nil),
            (Authentication.anonymous()#actor, Authentication.anonymous()#log |> Map.toList))

}
