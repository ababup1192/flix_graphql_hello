///
/// API キーと PAT の純粋な部分。scope / role の DB の文字列との往復、期限の判定、PAT の範囲で主体を落とす。
///
mod TestApiKeys {

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
            (ApiKeys.isAlive({ expiresAt = None, revokedAt = None }, now),
             ApiKeys.isAlive({ expiresAt = Some(deadline), revokedAt = None }, now),
             ApiKeys.isAlive({ expiresAt = Some(Timestamp.fromEpochMillis(now)), revokedAt = None }, now),
             ApiKeys.isAlive({ expiresAt = Some(Timestamp.fromEpochMillis(now - 1i64)), revokedAt = None }, now),
             ApiKeys.isAlive({ expiresAt = None, revokedAt = Some(deadline) }, now)))

    /// PAT の範囲。read は人を読むだけの人に落とし、write はそのまま。
    @Test
    def testWithPatScope(): Unit \ Assert =
        let user = Actor.User(UserId.UserId(7i64), "a@example.com", Role.Editor :: Nil);
        Assert.assertEq(
            expected = (Actor.ReadOnlyUser(UserId.UserId(7i64), "a@example.com", Role.Editor :: Nil), user),
            (Accounts.withPatScope(PatScope.Read, user), Accounts.withPatScope(PatScope.Write, user)))

    /// PAT の scope の往復。
    @Test
    def testPatScopeRoundTrip(): Unit \ Assert =
        Assert.assertEq(
            expected = (List#{ Some(PatScope.Read), Some(PatScope.Write) }, None),
            (List#{ PatScope.Read, PatScope.Write } |> List.map(scope -> PatScope.parse(PatScope.text(scope))), PatScope.parse("readDraft")))

}
