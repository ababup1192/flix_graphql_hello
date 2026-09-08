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

    /// 秒で観測を並べる（全部 DB に届かず、プールを通さない接続では届く）。
    def unhealthyAt(seconds: List[Int64]): List[Observation] =
        seconds |> List.map(second -> { at = second * 1000i64, pingOk = false, freshOk = true, stats = stats() })

    ///
    /// 判断は観測の列（それぞれの at）だけで決まる。見張りのスレッドと /health の 2 経路から交互に呼ばれて
    /// 間隔が不規則になっても、同じ時間幅の失敗なら同じ結果になる。
    ///
    @Test
    def testDecideDependsOnlyOnObservationsTable(): Unit \ Assert =
        let healthy = observations(300i64, 50, true, false);
        let exit = Decision.Exit("DB の接続プールから 100000 ms 続けて届かず、プールを通さない新しい接続では届いている");
        let cases = List#{
            // 2 秒ごと（見張りのスレッドだけ）
            (unhealthyFor(100i64, true), exit),
            // 交互に呼ばれて 1 秒・2.5 秒・10 秒・70 秒と間隔がばらついた
            (healthy ::: unhealthyAt(List#{400i64, 401i64, 403i64, 413i64, 483i64, 500i64}), exit),
            // /health だけが 10 秒ごとに呼んだ（粒度が粗くても幅で決まる）
            (healthy ::: unhealthyAt(List#{400i64, 410i64, 420i64, 500i64}), exit),
            // 幅が足りない（80 秒）
            (healthy ::: unhealthyAt(List#{400i64, 410i64, 480i64}), Decision.Keep)
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (seen, _) -> SelfHeal.decide(settings(), 0i64, seen)))

    /// 終わりの道は 1 回だけ通る（2 経路から同じ Exit が出ても drain と exit が二重に走らない）。
    @Test
    def testClaimExitOnce(): Unit \ {Assert, IO} =
        let watch = SelfHeal.createWatch(settings(), 0i64, { url = "jdbc:none", user = "u", password = "p" });
        Assert.assertEq(
            expected = List#{true, false, false},
            List.range(0, 3) |> List.map(_ -> SelfHeal.claimExit(watch)))

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
            cases |> List.map(match ((mode, seconds), _) -> SelfHeal.settingsFrom(mode, seconds, None, None, 0.0) |> Option.map(found -> found#minUnhealthyMs)))

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
            cases |> List.map(match (warmup, _) -> SelfHeal.settingsFrom(None, None, warmup, None, 0.0) |> Option.map(found -> found#warmupMs)))

    ///
    /// jitter は CMS_SELF_HEAL_JITTER_SECONDS（無い・数字でない・0 以下なら既定の 10 秒）を上限に、
    /// 呼ぶ側の 0.0〜1.0 の乱数を掛けた値。範囲の外の乱数は 0 と上限に丸まる。
    ///
    @Test
    def testJitterFromTable(): Unit \ Assert =
        let cases = List#{
            ((None, 0.0),         Some(0i64)),
            ((None, 1.0),         Some(10000i64)),
            ((None, 0.5),         Some(5000i64)),
            ((Some("30"), 1.0),   Some(30000i64)),
            ((Some("abc"), 1.0),  Some(10000i64)),
            ((Some("0"), 1.0),    Some(10000i64)),
            ((None, -1.0),        Some(0i64)),
            ((None, 2.0),         Some(10000i64))
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match ((jitter, fraction), _) -> SelfHeal.settingsFrom(None, None, None, jitter, fraction) |> Option.map(found -> found#jitterMs)))

}
