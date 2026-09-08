///
/// DB の接続プールが壊れたまま戻らなくなった時に、自分で終わってコンテナに起こし直させる判断。
/// 実験 1 回目（docs/design/trials/failure-experiment-round1-2026-09-08.md）の S5 で、OOM の後にプロセスは生き残るのに
/// プールが壊れたままで、PostgreSQL が健在でも /health が 503 を返し続けた（自力では戻らなかった）。
///
/// 判断は純粋な `decide`、外の世界に触るのは `observe` の 1 関数だけ。
///
/// WhyNot: プールを作り直さないのは、プールは Main が起動時に組んで全部に配っている値で、
/// 差し替えると Runner・エンジンのキャッシュ・ワーカーの持ち回りが全部変わるため。プロセスを終えれば
/// コンテナ（restart: unless-stopped）が同じ物を組み直す。
///
/// WhyNot: ping が失敗しただけで終わらないのは、DB 自体が落ちている時に終わっても直らず、
/// 再起動を繰り返して復旧の邪魔をするため。プールを通さない新しい接続で届く時（= 壊れているのはこちら）だけ終わる。
///
mod SelfHeal {

    import java.lang.System

    ///
    /// watchの設定。
    ///
    /// - minUnhealthyMs: プール経由で届かない状態がこれだけ続いたら終わりを考える
    /// - warmupMs: 起動からこれだけは見送る（起動直後の DB 待ちで終わらないため）
    /// - jitterMs: プロセスごとの上乗せ。複数台が同じ時刻に終わらないようにする
    ///
    /// WhyNot: jitter の上限を minUnhealthyMs と同じ大きさにしないのは、上限のぶんだけ終わりが遅れるため。
    /// 複数台が同じ時刻に終わらなければよく、minUnhealthyMs の半分もあれば散る。
    ///
    pub type alias Settings = { minUnhealthyMs = Int64, warmupMs = Int64, jitterMs = Int64 }

    ///
    /// 1 tickぶんの観測。
    ///
    /// - at: 観測した時刻（UNIX ミリ秒）
    /// - pingOk: プールから借りた接続で SELECT 1 が通ったか
    /// - freshOk: プールを通さない新しい接続で SELECT 1 が通ったか（pingOk が true の時は見ない）
    /// - stats: その時のプールの数字
    /// - returnedAt: 接続がプールに最後に返った時刻（PoolActivity。Tx の COMMIT / ROLLBACK、ping の返却を含む）。無ければ None
    ///
    pub type alias Observation = { at = Int64, pingOk = Bool, freshOk = Bool, stats = Pool.PoolStats, returnedAt = Option[Int64] }

    ///
    /// watchの結果。Exit は理由（ログの reason に出す）を持つ。
    ///
    pub enum Decision with Eq, ToString {
        case Keep
        case Exit(String)
    }

    /// minUnhealthyMs の既定（秒）。
    pub def defaultMinUnhealthySeconds(): Int64 = 90i64

    /// warmupMs の既定（秒）。
    pub def defaultWarmupSeconds(): Int64 = 300i64

    /// jitter の上限の既定（秒）。
    pub def defaultJitterSeconds(): Int64 = 10i64

    ///
    /// CMS_SELF_HEAL（on / off。既定 on）・CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS（既定 90）・
    /// CMS_SELF_HEAL_WARMUP_SECONDS（既定 300）・CMS_SELF_HEAL_JITTER_SECONDS（既定 10）から設定を組む。
    /// off なら None（見張らない）。数字でない・0 以下は既定の秒数。
    /// fraction は呼ぶ側が引いた 0.0〜1.0 の乱数で、jitter の上限に掛けてプロセスごとの上乗せにする。
    ///
    pub def settingsFrom(mode: Option[String], seconds: Option[String], warmupSeconds: Option[String],
                         jitterSeconds: Option[String], fraction: Float64): Option[Settings] =
        if (mode == Some("off")) None
        else
            Some({ minUnhealthyMs = positiveSeconds(defaultMinUnhealthySeconds(), seconds) * 1000i64,
                   warmupMs = positiveSeconds(defaultWarmupSeconds(), warmupSeconds) * 1000i64,
                   jitterMs = jitterOf(positiveSeconds(defaultJitterSeconds(), jitterSeconds), fraction) })

    /// 上限（秒）と 0.0〜1.0 の乱数から上乗せ（ミリ秒）。範囲の外の乱数は 0 と上限に丸める。
    def jitterOf(capSeconds: Int64, fraction: Float64): Int64 =
        Float64.clampToInt64(min = 0i64, max = capSeconds * 1000i64, nanValue = 0i64, fraction * Int64.toFloat64(capSeconds) * 1000.0)

    /// 秒を読む。無い・数字でない・0 以下なら fallback。
    def positiveSeconds(fallback: Int64, raw: Option[String]): Int64 =
        raw |> Option.flatMap(Int64.fromString) |> Option.filter(value -> value > 0i64) |> Option.getWithDefault(fallback)

    ///
    /// 環境変数から設定を組む。fraction は呼ぶ側が引いた 0.0〜1.0 の乱数（プロセスごとに 1 回）。
    ///
    pub def fromEnv(fraction: Float64): Option[Settings] \ Sys.Env =
        settingsFrom(Sys.Env.getVar("CMS_SELF_HEAL"), Sys.Env.getVar("CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS"),
            Sys.Env.getVar("CMS_SELF_HEAL_WARMUP_SECONDS"), Sys.Env.getVar("CMS_SELF_HEAL_JITTER_SECONDS"), fraction)

    ///
    /// 観測の列（古い順）から決める。次の 5 つが全部そろった時だけ Exit。
    ///
    /// 1. 起動から warmupMs 経っている
    /// 2. プール経由の ping が続けて失敗している
    /// 3. その間に、プールを通さない新しい接続では DB に届いた
    /// 4. 届き始めてから minUnhealthyMs + jitter 以上、ping の失敗が続いている
    /// 5. 失敗が続き始めてから、接続が 1 本もプールに返っていない（返っていれば接続は流れていて、ping が落ちるのはプールが満杯か作り直しの最中なだけ）
    ///
    /// WhyNot: 4 を ping が失敗し始めてからでなく「新しい接続で届き始めてから」数えるのは、DB が落ちている間の失敗を数えると、
    /// DB が起き上がった瞬間（新しい接続は通るが、プールはまだ接続を 1 本も作り直していない）に 2〜5 が同時にそろって終わるため
    /// （2026-09-09 の実機 E2E: 接続が返った時刻を見るようにした後も、`docker compose start postgres` と同じ秒に exit 3。pool total 0 / waiting 53）。
    /// 届き始めてから minUnhealthyMs の間にプールが 1 本も戻せないなら、壊れているのはこちら。
    ///
    /// WhyNot: 5 を見ないと、読むだけの文書が応答まで接続を握る形では、混んでいるだけで ping が借り待ちの上限で落ち続け、
    /// 壊れていないプロセスを終わらせるため。
    ///
    /// WhyNot: 5 を「リクエストの Tx が閉じた」でなく「接続が返った」で見るのは、304 の道（withTx で版を読むだけ）や認証の Tx が流れていても
    /// リクエストの Tx（読むだけの文書）は 1 つも閉じない事があるため（2026-09-08 の実機 E2E で復旧の 3.4 秒後に exit 3）。
    ///
    /// WhyNot: 「借り待ちの timeout で waiting > 0 なら混んでいるだけ」と見て除かないのは、プールが壊れて接続が戻らない時（実験 1 回目の S5）も
    /// 借り待ちが列を作って同じ形になり、区別が付かないため。返った接続があるかどうかだけが 2 つを分ける。
    ///
    pub def decide(settings: Settings, startedAt: Int64, observations: List[Observation]): Decision =
        match (List.last(observations), List.head(unhealthySuffix(observations))) {
            case (Some(latest), Some(first)) => decideOn(settings, startedAt, first, latest, unhealthySuffix(observations))
            case _                           => Decision.Keep
        }

    /// 5 つの条件を順に見る。
    def decideOn(settings: Settings, startedAt: Int64, first: Observation, latest: Observation, streak: List[Observation]): Decision =
        let unhealthyMs = latest#at - first#at;
        if (latest#at - startedAt < settings#warmupMs) Decision.Keep
        else match reachableSince(streak) {
            case None            => Decision.Keep
            case Some(reachedAt) =>
                if (latest#at - reachedAt < settings#minUnhealthyMs + settings#jitterMs) Decision.Keep
                else if (returnedSince(first#at, latest)) Decision.Keep
                else Decision.Exit("DB の接続プールから ${unhealthyMs} ms 続けて届かず、プールを通さない新しい接続では ${latest#at - reachedAt} ms 前から届いている")
        }

    /// 失敗の列の中で、プールを通さない新しい接続が最初に届いた時刻。
    def reachableSince(streak: List[Observation]): Option[Int64] =
        streak |> List.find(seen -> seen#freshOk) |> Option.map(seen -> seen#at)

    /// 失敗が続き始めてから、接続がプールに返ったか。返った時刻は単調に進むので最新の観測だけ見れば足りる。
    def returnedSince(sinceAt: Int64, latest: Observation): Bool =
        latest#returnedAt |> Option.exists(returnedAt -> returnedAt >= sinceAt)

    /// 末尾に続いている失敗だけ（間に 1 回でも成功があれば、そこで切れる）。
    def unhealthySuffix(observations: List[Observation]): List[Observation] =
        observations |> List.reverse |> List.takeWhile(seen -> not seen#pingOk) |> List.reverse

    ///
    /// watchの持ち物。observe が 1 tickごとに観測を積む。
    ///
    /// - settings: 判断の設定
    /// - startedAt: プロセスが起動した時刻（UNIX ミリ秒）
    /// - connection: プールを通さない接続を 1 本開くための接続情報
    /// - seen: 直近の観測（古い順。窓の外は捨てる）
    /// - exiting: 終わりの道に入った印
    /// - lastReturnedAt: 接続がプールに最後に返った時刻（PoolActivity が置く）
    ///
    /// WhyNot: exiting を持つのは、step を呼ぶ経路が 2 つ（watchのスレッドと /health のリクエストのスレッド）あり、
    /// 同じ Exit で drain と System.exit が二重に走らないようにするため。
    ///
    pub type alias Watch = { settings = Settings, startedAt = Int64, connection = Jdbc.ConnectionConfig, seen = Ref[List[Observation], Static], exiting = Ref[Bool, Static], lastReturnedAt = PoolActivity.LastReturnedAt }

    ///
    /// 覚えておく観測の数。2 秒ごとなので 300 個で 10 分。minUnhealthyMs（既定 90 秒）より十分に長い。
    ///
    def windowSize(): Int32 = 300

    pub def createWatch(settings: Settings, startedAt: Int64, connection: Jdbc.ConnectionConfig, lastReturnedAt: PoolActivity.LastReturnedAt): Watch \ IO =
        { settings = settings, startedAt = startedAt, connection = connection, seen = Ref.fresh(Static, Nil), exiting = Ref.fresh(Static, false), lastReturnedAt = lastReturnedAt }

    ///
    /// 終わりの道を 1 回だけ通す。まだ誰も通っていなければ印を置いて true。
    ///
    pub def claimExit(watch: Watch): Bool \ IO =
        if (Ref.get(watch#exiting)) false else { Ref.put(true, watch#exiting); true }

    ///
    /// プール経由の ping の結果から 1 tickぶんの観測を作る。ping が通っている間は新しい接続を開かない。
    ///
    /// WhyNot: ここで ping を打たないのは、/health が同じ ping を checkDb でも打っていて、DB が落ちている間は
    /// 借り待ちの分だけ応答が倍に伸びるため（実験 4 回目の対照 4 で 10.3 秒）。ping は呼ぶ側が 1 回打ってその結果を渡す。
    ///
    pub def observe(watch: Watch, pool: Pool, pingOk: Bool): Observation \ IO =
        { at = System.currentTimeMillis(), pingOk = pingOk, freshOk = not pingOk and freshOk(watch#connection), stats = Pool.stats(pool), returnedAt = Ref.get(watch#lastReturnedAt) }

    ///
    /// 観測を 1 つ積んで決める。
    /// 判断は観測の列（それぞれが `at` を持つ）だけで決まるので、呼ばれる間隔が一定でなくても minUnhealthyMs の判定は変わらない。
    ///
    /// WhyNot: watchのスレッドからしか呼ばないようにしないのは、そのスレッドが OOM で死ぬと自己回復が永久に無効になるため
    /// （実験 3 回目の S5 で 2 回とも再現）。リクエストのスレッドは OOM の後も生きているので、/health からも同じ step を進める。
    ///
    pub def step(watch: Watch, seen: Observation): Decision \ IO =
        // 観測を末尾に積み、窓の外の古い物を捨てて覚え直す
        let window = (Ref.get(watch#seen) ::: seen :: Nil) |> keepLast(windowSize());
        Ref.put(window, watch#seen);
        // 窓の中の観測の列だけで決める
        decide(watch#settings, watch#startedAt, window)

    /// 末尾の count 個だけ残す。
    def keepLast(count: Int32, observations: List[Observation]): List[Observation] =
        observations |> List.reverse |> List.take(count) |> List.reverse

    ///
    /// プールを通さない接続を 1 本開いて SELECT 1 を投げ、閉じる。届けば true。
    ///
    pub def freshOk(connection: Jdbc.ConnectionConfig): Bool \ IO =
        DbError.runWithFailure(() -> RawSql.runWithAllow(() -> Jdbc.withConnection(connection, _ -> discard Sql.fetch("SELECT 1", Nil))))
            |> Result.isOk

}
