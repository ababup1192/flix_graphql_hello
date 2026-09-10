///
/// Health.stalled: 仕事の tick と見張りの tick が止まっていないか（/health が 503 と reason を返すかの判断）。
///
mod TestHealth {

    /// 起動は 0 ミリ秒、今は 100 秒。tick の間隔はどちらも 2 秒（上限は 30 秒）。
    def live(lastTickAt: Option[Int64], lastWatchAt: Option[Int64]): Health.Liveness =
        { now = 100000i64, startedAt = 0i64, jobsOn = true,
          jobsIntervalMs = 2000i64, lastTickAt = lastTickAt,
          watchIntervalMs = 2000i64, lastWatchAt = lastWatchAt,
          purgeOn = true, lastScheduleAt = lastTickAt, lastWebhookAt = lastTickAt, lastPurgeAt = lastTickAt }

    /// 秒を UNIX ミリ秒に。
    def at(seconds: Int64): Option[Int64] = Some(seconds * 1000i64)

    ///
    /// 上限（30 秒）より古い tick があれば、その tick を返す。仕事の tick を先に見る。
    /// CMS_JOBS=off なら仕事の tick は見ない。まだ 1 度も回っていない tick は起動からの経過で見る。
    ///
    @Test
    def testStalledTable(): Unit \ Assert =
        let cases = List#{
            // どちらも直前に回っている
            (live(at(99i64), at(99i64)),                                    None),
            // 上限ちょうど（30 秒）はまだ止まっていない
            (live(at(70i64), at(99i64)),                                    None),
            // 仕事の tick が 40 秒古い
            (live(at(60i64), at(99i64)),                                    Some(Health.Stall.Jobs(40000i64))),
            // 見張りの tick が 40 秒古い
            (live(at(99i64), at(60i64)),                                    Some(Health.Stall.Watch(40000i64))),
            // 両方古ければ仕事の tick
            (live(at(60i64), at(50i64)),                                    Some(Health.Stall.Jobs(40000i64))),
            // CMS_JOBS=off なら仕事の tick は見ない
            ({ jobsOn = false | live(at(60i64), at(99i64)) },               None),
            // まだ 1 度も回っていない（起動から 100 秒）
            (live(None, at(99i64)),                                         Some(Health.Stall.Jobs(100000i64))),
            (live(at(99i64), None),                                         Some(Health.Stall.Watch(100000i64))),
            // 起動した直後はまだ止まっていない
            ({ now = 5000i64 | live(None, None) },                          None)
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (input, _) -> Health.stalled(input)))

    /// 上限は間隔の 3 倍。ただし 30 秒までは待つ。
    @Test
    def testStallLimitMsTable(): Unit \ Assert =
        let cases = List#{
            (2000i64,  30000i64),
            (10000i64, 30000i64),
            (20000i64, 60000i64)
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (interval, _) -> Health.stallLimitMs(interval)))

    /// 上限 max 本のうち active 本を使っているプール。待ちは無い。
    def pool(active: Int32, max: Int32): Pool.PoolStats =
        { active = active, idle = max - active, waiting = 0, total = max, max = max }

    ///
    /// Health.saturation: DB の接続プールが張り付いていれば、使用中の割合（パーセント）。
    /// 接続が漏れると active が max の近くに居座るが、idle が 1 本でも残っていれば ping は通るので checkDb では気づけない。
    ///
    @Test
    def testSaturationTable(): Unit \ Assert =
        let cases = List#{
            // 10 本のうち 1 本だけ使っている
            (pool(1, 10),   None),
            // 8 割はまだ張り付きとしない
            (pool(8, 10),   None),
            // 9 割ちょうどから張り付き（接続が漏れた実例。idle が 1 本残るので ping は通る）
            (pool(9, 10),   Some(90)),
            // 満杯
            (pool(10, 10),  Some(100)),
            // 小さいプールでも割合で見る
            (pool(4, 4),    Some(100)),
            // まだプールができていない（max が 0）
            (pool(0, 0),    None)
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (stats, _) -> Health.saturation(stats)))

    /// 張り付きは /health の reason とリクエストの行のキーになる。
    @Test
    def testSaturationNamesTable(): Unit \ Assert =
        let cases = List#{
            (90,  "pool saturated (90%)"),
            (100, "pool saturated (100%)")
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (percent, _) -> Health.saturationReason(percent)))

    /// /health の status を ok から外す理由（リクエストの行の reason）。DB に届かなければその文言が先、次に止まった tick、次にプールの張り付き。
    @Test
    def testHealthReasonTable(): Unit \ Assert =
        let cases = List#{
            ((Err("timeout"), None, None),                              Some("timeout")),
            ((Err("timeout"), Some(Health.Stall.Jobs(1i64)), Some(95)), Some("timeout")),
            ((Ok(()), Some(Health.Stall.Watch(1i64)), Some(95)),        Some("watch stalled")),
            ((Ok(()), None, Some(95)),                                  Some("pool saturated (95%)")),
            ((Ok(()), None, None),                                      None)
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match ((db, stall, saturation), _) -> Server.healthReason(db, stall, saturation)))

    /// tick も部分も直前に通っていて、CDN の purge の送り先もある。
    def alive(): Health.Liveness = live(at(99i64), at(99i64))

    /// 期限を過ぎた件数だけを変えた jobs のまとめ。
    def behind(schedules: Int64, deliveries: Int64): BackgroundJobs.Summary =
        { lastTickAt = None, pendingSchedules = 0i64, failedSchedules = 0i64, pendingDeliveries = 0i64, failedDeliveries = 0i64,
          overdueSchedules = schedules, overdueDeliveries = deliveries }

    /// 行の名前と段と理由。
    def levels(live: Health.Liveness, summary: BackgroundJobs.Summary, dbOk: Bool, saturation: Option[Int32]): List[(String, Health.Level, Option[String])] =
        Health.componentLevels(live, summary, dbOk, saturation)

    ///
    /// Health.componentLevels: ステータスページの行ごとの段。DB に届かなければ全行が落ち、
    /// 部分が止まっていればその行だけ partial_outage、捌けていなければ degraded。
    ///
    @Test
    def testComponentLevelsTable(): Unit \ Assert =
        let cases = List#{
            // 全部順調
            ((alive(), behind(0i64, 0i64), true, None),
             List#{("api", Health.Level.Operational, None), ("schedule", Health.Level.Operational, None),
                   ("webhook", Health.Level.Operational, None), ("cdnPurge", Health.Level.Operational, None)}),
            // DB に届かない: 全行が major_outage
            ((alive(), behind(0i64, 0i64), false, None),
             List#{("api", Health.Level.MajorOutage, Some("db unreachable")), ("schedule", Health.Level.MajorOutage, Some("db unreachable")),
                   ("webhook", Health.Level.MajorOutage, Some("db unreachable")), ("cdnPurge", Health.Level.MajorOutage, Some("db unreachable"))}),
            // プールが張り付いているのは api だけの話
            ((alive(), behind(0i64, 0i64), true, Some(95)),
             List#{("api", Health.Level.Degraded, Some("pool saturated (95%)")), ("schedule", Health.Level.Operational, None),
                   ("webhook", Health.Level.Operational, None), ("cdnPurge", Health.Level.Operational, None)}),
            // Webhook の部分だけ 40 秒古い（例外で死んでいる）
            (({ lastWebhookAt = at(60i64) | alive() }, behind(0i64, 0i64), true, None),
             List#{("api", Health.Level.Operational, None), ("schedule", Health.Level.Operational, None),
                   ("webhook", Health.Level.PartialOutage, Some("webhook stalled")), ("cdnPurge", Health.Level.Operational, None)}),
            // 回ってはいるが予約が 3 件、配信が 1 件、期限を過ぎたまま残っている
            ((alive(), behind(3i64, 1i64), true, None),
             List#{("api", Health.Level.Operational, None), ("schedule", Health.Level.Degraded, Some("schedule behind (3)")),
                   ("webhook", Health.Level.Degraded, Some("webhook behind (1)")), ("cdnPurge", Health.Level.Operational, None)}),
            // 止まっている方が、捌けていないより強い
            (({ lastWebhookAt = at(60i64) | alive() }, behind(0i64, 5i64), true, None),
             List#{("api", Health.Level.Operational, None), ("schedule", Health.Level.Operational, None),
                   ("webhook", Health.Level.PartialOutage, Some("webhook stalled")), ("cdnPurge", Health.Level.Operational, None)}),
            // CDN の purge の送り先が無ければ、その行は出さない
            (({ purgeOn = false | alive() }, behind(0i64, 0i64), true, None),
             List#{("api", Health.Level.Operational, None), ("schedule", Health.Level.Operational, None),
                   ("webhook", Health.Level.Operational, None)}),
            // 仕事を回さないプロセス（CMS_JOBS=off）は api だけ
            (({ jobsOn = false | alive() }, behind(0i64, 0i64), true, None),
             List#{("api", Health.Level.Operational, None)}),
            // まだ 1 度も回っていない（起動から 100 秒）
            (({ lastScheduleAt = None, lastWebhookAt = None, lastPurgeAt = None | alive() }, behind(0i64, 0i64), true, None),
             List#{("api", Health.Level.Operational, None), ("schedule", Health.Level.PartialOutage, Some("schedule stalled")),
                   ("webhook", Health.Level.PartialOutage, Some("webhook stalled")), ("cdnPurge", Health.Level.PartialOutage, Some("cdnPurge stalled"))})
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match ((live, summary, dbOk, saturation), _) -> levels(live, summary, dbOk, saturation)))

    /// 段は JSON の語になる（Statuspage の 4 段と同じ並び）。
    @Test
    def testLevelJsonTable(): Unit \ Assert =
        let cases = List#{
            (Health.Level.Operational,   "operational"),
            (Health.Level.Degraded,      "degraded"),
            (Health.Level.PartialOutage, "partial_outage"),
            (Health.Level.MajorOutage,   "major_outage")
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (level, _) -> Health.levelJson(level)))

    /// 止まった tick は /health の reason とリクエストの行のキーになる。
    @Test
    def testStallNamesTable(): Unit \ Assert =
        let cases = List#{
            (Health.Stall.Jobs(1i64),  ("jobs stalled", "jobs.stalled_ms")),
            (Health.Stall.Watch(1i64), ("watch stalled", "watch.stalled_ms"))
        };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (stall, _) -> (Health.stallReason(stall), Health.stallKey(stall))))

}
