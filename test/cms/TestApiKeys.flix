///
/// API キーと PAT の純粋な部分。scope / role の DB の文字列との往復、秘密の寿命（SecretHash）、期限の検査、発行者の役割の上限。
///
mod TestApiKeys {

    def user(roles: List[Role], login: Login): Actor = Actor.User(UserId.UserId(7i64), "a@example.com", roles, login)

    /// scope 列と role 列の組で往復する。write に役割が無い・read に役割がある・知らない物は None。
    @Test
    def testApiKeyScopeRoundTrip(): Unit \ Assert =
        let scopes = List#{ ApiKeyScope.Read, ApiKeyScope.ReadDraft, ApiKeyScope.Write(Role.Writer), ApiKeyScope.Write(Role.Owner) };
        Assert.assertEq(
            expected = (scopes |> List.map(Some), None, None, None),
            (scopes |> List.map(scope -> ApiKeyScope.parse(ApiKeyScope.text(scope), ApiKeyScope.roleOf(scope) |> Option.map(Role.text))),
             ApiKeyScope.parse("write", None),
             ApiKeyScope.parse("read", Some("writer")),
             ApiKeyScope.parse("write", Some("viewer"))))

    /// 期限が無ければ切れず、期限より前なら生きていて、期限ちょうどと過ぎた物と失効した物は死んでいる。
    @Test
    def testIsAlive(): Unit \ Assert =
        let now = 1_700_000_000_000i64;
        let deadline = Timestamp.fromEpochMillis(now + 1i64);
        Assert.assertEq(
            expected = (true, true, false, false, false),
            (SecretHash.isAlive({ expiresAt = None, revokedAt = None }, now),
             SecretHash.isAlive({ expiresAt = Some(deadline), revokedAt = None }, now),
             SecretHash.isAlive({ expiresAt = Some(Timestamp.fromEpochMillis(now)), revokedAt = None }, now),
             SecretHash.isAlive({ expiresAt = Some(Timestamp.fromEpochMillis(now - 1i64)), revokedAt = None }, now),
             SecretHash.isAlive({ expiresAt = None, revokedAt = Some(deadline) }, now)))

    /// 同じ pepper と値なら同じ hash、pepper か値が違えば違う hash。
    @Test
    def testHash(): Unit \ Assert =
        let pepper = { pepperId = "v1", secret = "s" };
        Assert.assertEq(
            expected = (true, false, false),
            (SecretHash.hash(pepper, "cms_a") == SecretHash.hash(pepper, "cms_a"),
             SecretHash.hash(pepper, "cms_a") == SecretHash.hash(pepper, "cms_b"),
             SecretHash.hash(pepper, "cms_a") == SecretHash.hash({ pepperId = "v2", secret = "t" }, "cms_a")))

    /// 期限の検査。無しは通り、未来は通り、今ちょうどと過去は invalid。
    @Test
    def testValidateExpiry(): Unit \ Assert =
        let now = 1_700_000_000_000i64;
        let past = Violation.Violation("expiresAt", "期限は未来にしてください") :: Nil;
        Assert.assertEq(
            expected = (Nil, Nil, past, past),
            (ApiKeys.validateExpiry(None, now),
             ApiKeys.validateExpiry(Some(Timestamp.fromEpochMillis(now + 1i64)), now),
             ApiKeys.validateExpiry(Some(Timestamp.fromEpochMillis(now)), now),
             ApiKeys.validateExpiry(Some(Timestamp.fromEpochMillis(now - 1i64)), now)))

    /// 発行者の役割の上限。editor は WRITER / EDITOR の鍵を作れ、OWNER は invalid。owner は OWNER まで。VIEWER の write は誰でも invalid。read の鍵は役割を見ない。
    @Test
    def testRequireRoleWithinIssuer(): Unit \ Assert =
        let check = (actor, scope) -> Session.runWith(actor, () -> CmsTestKit.failureMessage(() -> ApiKeys.requireRoleWithinIssuer(scope)));
        let editor = user(Role.Editor :: Nil, Login.Interactive);
        let owner = user(Role.Owner :: Nil, Login.Interactive);
        Assert.assertEq(
            expected = (Ok(()), Ok(()), Err("role: 自分の役割より高い役割（owner）の鍵は作れません"), Ok(()),
                        Err("role: WRITE の鍵の役割は WRITER / EDITOR / OWNER です"), Ok(())),
            (check(editor, ApiKeyScope.Write(Role.Writer)),
             check(editor, ApiKeyScope.Write(Role.Editor)),
             check(editor, ApiKeyScope.Write(Role.Owner)),
             check(owner, ApiKeyScope.Write(Role.Owner)),
             check(owner, ApiKeyScope.Write(Role.Viewer)),
             check(user(Nil, Login.Interactive), ApiKeyScope.Read)))

    /// PAT の scope の往復。
    @Test
    def testPatScopeRoundTrip(): Unit \ Assert =
        Assert.assertEq(
            expected = (List#{ Some(PatScope.Read), Some(PatScope.Write) }, None),
            (List#{ PatScope.Read, PatScope.Write } |> List.map(scope -> PatScope.parse(PatScope.text(scope))), PatScope.parse("readDraft")))

    /// Session の入口。ログインの JWT は書けて鍵も作れ、write の PAT は書けるが鍵は作れず、read の PAT は読むだけ（自分は読める）。
    @Test
    def testSessionEntrances(): Unit \ Assert =
        let entrances = actor -> Session.runWith(actor, () ->
            (CmsTestKit.failureMessage(() -> discard Session.currentUser()),
             CmsTestKit.failureMessage(() -> discard Session.grantInteractive()),
             Session.currentUserForRead()));
        let me = Some(UserId.UserId(7i64));
        let notWriting = Err("この操作は read の PAT ではできません。write の PAT かログインした本人で行ってください");
        let notInteractive = Err("この操作はログインした本人だけができます（PAT や API キーではできません）");
        Assert.assertEq(
            expected = ((Ok(()), Ok(()), me), (Ok(()), notInteractive, me), (notWriting, notInteractive, me),
                        (Err("この操作（readDraft）の権限がありません"), notInteractive, None)),
            (entrances(user(Role.Owner :: Nil, Login.Interactive)),
             entrances(user(Role.Owner :: Nil, Login.PersonalToken(PatScope.Write))),
             entrances(user(Role.Owner :: Nil, Login.PersonalToken(PatScope.Read))),
             entrances(Actor.ApiKey("ci", ApiKeyScope.Write(Role.Owner)))))

    /// 版の author。人は email、鍵は "api-key:<名前>"。
    @Test
    def testDisplayName(): Unit \ Assert =
        Assert.assertEq(
            expected = ("a@example.com", "api-key:deploy", "anonymous"),
            (Session.runWith(user(Nil, Login.Interactive), Session.displayName),
             Session.runWith(Actor.ApiKey("deploy", ApiKeyScope.Write(Role.Editor)), Session.displayName),
             Session.runWith(Actor.Anonymous, Session.displayName)))

}
