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
    /// 見張りの設定。
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
    /// 1 周ぶんの観測。
    ///
    /// - at: 観測した時刻（UNIX ミリ秒）
    /// - pingOk: プールから借りた接続で SELECT 1 が通ったか
    /// - freshOk: プールを通さない新しい接続で SELECT 1 が通ったか（pingOk が true の時は見ない）
    /// - stats: その時のプールの数字
    ///
    pub type alias Observation = { at = Int64, pingOk = Bool, freshOk = Bool, stats = Pool.PoolStats }

    ///
    /// 見張りの結果。Exit は理由（ログの reason に出す）を持つ。
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
    /// 観測の列（古い順）から決める。次の 4 つが全部そろった時だけ Exit。
    ///
    /// 1. 起動から warmupMs 経っている
    /// 2. プール経由の ping が minUnhealthyMs 以上続けて失敗している
    /// 3. その間に、プールを通さない新しい接続では DB に届いた
    /// 4. jitter を足した長さも過ぎている
    ///
    pub def decide(settings: Settings, startedAt: Int64, observations: List[Observation]): Decision =
        match (List.last(observations), List.head(unhealthySuffix(observations))) {
            case (Some(latest), Some(first)) => decideOn(settings, startedAt, latest#at - first#at, latest, unhealthySuffix(observations))
            case _                           => Decision.Keep
        }

    /// 4 つの条件を順に見る。
    def decideOn(settings: Settings, startedAt: Int64, unhealthyMs: Int64, latest: Observation, streak: List[Observation]): Decision =
        if (latest#at - startedAt < settings#warmupMs) Decision.Keep
        else if (unhealthyMs < settings#minUnhealthyMs + settings#jitterMs) Decision.Keep
        else if (not List.exists(seen -> seen#freshOk, streak)) Decision.Keep
        else Decision.Exit("DB の接続プールから ${unhealthyMs} ms 続けて届かず、プールを通さない新しい接続では届いている")

    /// 末尾に続いている失敗だけ（間に 1 回でも成功があれば、そこで切れる）。
    def unhealthySuffix(observations: List[Observation]): List[Observation] =
        observations |> List.reverse |> List.takeWhile(seen -> not seen#pingOk) |> List.reverse

    ///
    /// 見張りの持ち物。observe が 1 周ごとに観測を積む。
    ///
    /// - settings: 判断の設定
    /// - startedAt: プロセスが起動した時刻（UNIX ミリ秒）
    /// - connection: プールを通さない接続を 1 本開くための接続情報
    /// - seen: 直近の観測（古い順。窓の外は捨てる）
    /// - exiting: 終わりの道に入った印
    ///
    /// WhyNot: exiting を持つのは、step を呼ぶ経路が 2 つ（見張りのスレッドと /health のリクエストのスレッド）あり、
    /// 同じ Exit で drain と System.exit が二重に走らないようにするため。
    ///
    pub type alias Watch = { settings = Settings, startedAt = Int64, connection = Jdbc.ConnectionConfig, seen = Ref[List[Observation], Static], exiting = Ref[Bool, Static] }

    ///
    /// 覚えておく観測の数。2 秒ごとなので 300 個で 10 分。minUnhealthyMs（既定 90 秒）より十分に長い。
    ///
    def windowSize(): Int32 = 300

    pub def createWatch(settings: Settings, startedAt: Int64, connection: Jdbc.ConnectionConfig): Watch \ IO =
        { settings = settings, startedAt = startedAt, connection = connection, seen = Ref.fresh(Static, Nil), exiting = Ref.fresh(Static, false) }

    ///
    /// 終わりの道を 1 回だけ通す。まだ誰も通っていなければ印を置いて true。
    ///
    pub def claimExit(watch: Watch): Bool \ IO =
        if (Ref.get(watch#exiting)) false else { Ref.put(true, watch#exiting); true }

    ///
    /// プール経由の ping の結果から 1 周ぶんの観測を作る。ping が通っている間は新しい接続を開かない。
    ///
    /// WhyNot: ここで ping を打たないのは、/health が同じ ping を checkDb でも打っていて、DB が落ちている間は
    /// 借り待ちの分だけ応答が倍に伸びるため（実験 4 回目の対照 4 で 10.3 秒）。ping は呼ぶ側が 1 回打ってその結果を渡す。
    ///
    pub def observe(watch: Watch, pool: Pool, pingOk: Bool): Observation \ IO =
        { at = System.currentTimeMillis(), pingOk = pingOk, freshOk = not pingOk and freshOk(watch#connection), stats = Pool.stats(pool) }

    ///
    /// 観測を 1 つ積んで決める。
    /// 判断は観測の列（それぞれが `at` を持つ）だけで決まるので、呼ばれる間隔が一定でなくても minUnhealthyMs の判定は変わらない。
    ///
    /// WhyNot: 見張りのスレッドからしか呼ばないようにしないのは、そのスレッドが OOM で死ぬと自己回復が永久に無効になるため
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
