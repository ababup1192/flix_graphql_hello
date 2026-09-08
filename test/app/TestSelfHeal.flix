///
/// SelfHeal: 観測の列から「自分で終わってコンテナに起こし直させるか」を決める規則。
///
mod TestSelfHeal {

    use SelfHeal.Decision
    use SelfHeal.Observation

    /// 90 秒続いたら終わる。起動から 300 秒は見送る。jitter は 0。
    def settings(): SelfHeal.Settings =
        { minUnhealthyMs = 90000i64, warmupMs = 300000i64, jitterMs = 0i64 }

    /// 使っていない空のプール。
    def stats(): Pool.PoolStats =
        { active = 0, idle = 0, waiting = 0, total = 0, max = 10 }

    /// at 秒から 2 秒ごとに count 回の観測。
    def observations(fromSeconds: Int64, count: Int32, pingOk: Bool, freshOk: Bool): List[Observation] =
        List.range(0, count) |> List.map(index ->
            { at = (fromSeconds + Int32.toInt64(index) * 2i64) * 1000i64, pingOk = pingOk, freshOk = freshOk, stats = stats() })

    /// 起動から 400 秒まわった後に、DB に届かない観測が seconds 秒ぶん続く列。
    def unhealthyFor(seconds: Int64, freshOk: Bool): List[Observation] =
        observations(300i64, 50, true, false) ::: observations(400i64, Int64.clampToInt32(min = 0, max = 1000, seconds / 2i64) + 1, false, freshOk)

    ///
    /// Exit するのは 4 つが揃った時だけ。1 つでも欠けたら Keep。
    ///
    /// warmup 中 / 失敗が短い / 新しい接続でも届かない（DB 自体が落ちている）/ jitter の分をまだ待っている /
    /// ping が戻った、のどれでも Keep。
    ///
    @Test
    def testDecideTable(): Unit \ Assert =
        let cases = List#{
            // 観測が無い
            ((settings(), 0i64, Nil), Decision.Keep),
            // 起動から 100 秒（warmup 300 秒の中）で、失敗が 100 秒続いている
            ((settings(), 0i64, observations(0i64, 51, false, true)), Decision.Keep),
            // 失敗が 30 秒しか続いていない
            ((settings(), 0i64, unhealthyFor(30i64, true)), Decision.Keep),
            // 失敗は 100 秒続いているが、pool を通さない接続でも届かない（DB 自体が落ちている）
            ((settings(), 0i64, unhealthyFor(100i64, false)), Decision.Keep),
            // jitter の 30 秒をまだ待っている（失敗は 100 秒、要るのは 120 秒）
            (({ jitterMs = 30000i64 | settings() }, 0i64, unhealthyFor(100i64, true)), Decision.Keep),
            // 揃った後に ping が戻った
            ((settings(), 0i64, unhealthyFor(100i64, true) ::: observations(600i64, 1, true, false)), Decision.Keep),
            // 4 つとも揃った
            ((settings(), 0i64, unhealthyFor(100i64, true)), Decision.Exit("DB の接続プールから 100000 ms 続けて届かず、プールを通さない新しい接続では届いている"))
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match ((config, startedAt, seen), _) -> SelfHeal.decide(config, startedAt, seen)))

    /// CMS_SELF_HEAL=off なら見張らない。秒数は CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS（無い・数字でない・0 以下なら既定の 90 秒）。
    @Test
    def testSettingsFromTable(): Unit \ Assert =
        let cases = List#{
            ((None, None),               Some(90000i64)),
            ((Some("on"), None),         Some(90000i64)),
            ((Some("off"), Some("120")), None),
            ((None, Some("120")),        Some(120000i64)),
            ((None, Some("abc")),        Some(90000i64)),
            ((None, Some("0")),          Some(90000i64))
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match ((mode, seconds), _) -> SelfHeal.settingsFrom(mode, seconds, None, 0i64) |> Option.map(found -> found#minUnhealthyMs)))

    /// warmup は CMS_SELF_HEAL_WARMUP_SECONDS（無い・数字でない・0 以下なら既定の 300 秒）。
    @Test
    def testWarmupFromTable(): Unit \ Assert =
        let cases = List#{
            (None,          Some(300000i64)),
            (Some("30"),    Some(30000i64)),
            (Some("abc"),   Some(300000i64)),
            (Some("0"),     Some(300000i64)),
            (Some("-3"),    Some(300000i64))
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (warmup, _) -> SelfHeal.settingsFrom(None, None, warmup, 0i64) |> Option.map(found -> found#warmupMs)))

}
