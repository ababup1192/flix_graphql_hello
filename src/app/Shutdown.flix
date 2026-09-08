///
/// SIGTERM / SIGINT を受けた時の停止の順番と終了コード。
///
/// listen を閉じて新しい接続を受けるのをやめ、処理中の接続が引けるのを待ち、仕事の 1 周を待つ。
/// 全部間に合えば 0、どれかが待ち切れなければ `shutdown timed out` を出して 2 で終わる。
///
/// WhyNot: listen を閉じる前に接続を待たないのは、待っている間も新しい接続を受け続けて終わらないため。
/// 先に閉じれば前段（Caddy / ロードバランサ）は接続を張れなくなり、既にある接続だけが残る。
///
/// WhyNot: 待つ対象を「処理中のリクエスト」でなく接続数にしているのは、HttpServer が数えているのが接続の数（`/health` の
/// `connections`）で、リクエスト単位の数を持っていないため。keep-alive の idle の接続も枠を占めるので、
/// 前段が接続を使い回している時は idleTimeoutMs（15 秒）ぶん残りうる。CMS_SHUTDOWN_TIMEOUT_SECONDS はそれより長くする。
///
mod Shutdown {

    import java.lang.System
    import java.lang.Thread
    import sun.misc.Signal
    import sun.misc.SignalHandler

    /// CMS_SHUTDOWN_TIMEOUT_SECONDS の既定（秒）。
    pub def defaultTimeoutSeconds(): Int64 = 20i64

    /// 待ち切れたかを見る間隔（ミリ秒）。
    def pollMs(): Int64 = 100i64

    ///
    /// 待ち切れなかった物。
    ///
    /// - connections: まだ閉じていない HTTP の接続の数
    /// - inTick: 仕事の 1 周がまだ途中か
    ///
    pub type alias Remaining = { connections = Int32, inTick = Bool }

    ///
    /// 停止の結末。
    ///
    pub enum Outcome with Eq, ToString {
        case Clean
        case TimedOut
    }

    ///
    /// 残った物から結末を決める。1 つでも残っていれば TimedOut。
    ///
    pub def decide(remaining: Remaining): Outcome =
        if (remaining#connections <= 0 and not remaining#inTick) Outcome.Clean else Outcome.TimedOut

    ///
    /// 結末の終了コード。0 は綺麗に停止、2 は待ち切れなかった。
    ///
    /// WhyNot: 待ち切れない時も 0 にしないのは、処理中のリクエストを切った事と Webhook の二重配信の可能性が
    /// 呼び出し側（compose / orchestrator の記録）に残らないため。3 は自己回復が使っているので 2 にする。
    ///
    pub def exitCode(outcome: Outcome): Int32 = match outcome {
        case Outcome.Clean    => 0
        case Outcome.TimedOut => 2
    }

    ///
    /// CMS_SHUTDOWN_TIMEOUT_SECONDS の値を秒にする。無い・数字でない・0 以下なら既定の 20。
    ///
    pub def timeoutSeconds(raw: Option[String]): Int64 =
        raw |> Option.flatMap(Int64.fromString) |> Option.filter(seconds -> seconds > 0i64) |> Option.getWithDefault(defaultTimeoutSeconds())

    ///
    /// SIGTERM / SIGINT を受けたら停止して終わる。
    ///
    /// WhyNot: Runtime.addShutdownHook（Runnable）を使わないのは、Runnable の `run` が Flix の予約語で書けないため。
    ///
    pub def installHook(listener: HttpServer.Listener, state: BackgroundJobs.State, timeoutMs: Int64, sink: Log.Sink): Unit \ IO =
        let onSignal = new SignalHandler {
            def handle(_this: SignalHandler, _signal: Signal): Unit \ IO =
                System.exit(Log.runWith(sink, () -> stop(listener, state, timeoutMs)))
        };
        discard Signal.handle(new Signal("TERM"), onSignal);
        discard Signal.handle(new Signal("INT"), onSignal)

    ///
    /// 停止の本体。`shutting down` を出し、listen を閉じ、接続と仕事を期限まで待って終了コードを返す。
    ///
    pub def stop(listener: HttpServer.Listener, state: BackgroundJobs.State, timeoutMs: Int64): Int32 \ {IO, Log} =
        Log.info("shutting down", Log.Fields.empty());
        HttpServer.close(listener);
        Ref.put(true, state#stopping);
        let deadline = System.currentTimeMillis() + timeoutMs;
        let connections = awaitConnections(listener, deadline);
        let drained = BackgroundJobs.drain(state, deadline);
        report({ connections = connections, inTick = not drained })

    ///
    /// 残った物を見て、待ち切れなければ warn の行を出す。終了コードを返す。
    ///
    def report(remaining: Remaining): Int32 \ Log =
        let outcome = decide(remaining);
        match outcome {
            case Outcome.Clean    => ()
            case Outcome.TimedOut =>
                Log.Fields.empty()
                    |> Log.Fields.int("shutdown.connections", Int32.toInt64(remaining#connections))
                    |> Log.Fields.bool("shutdown.in_tick", remaining#inTick)
                    |> Log.warn("shutdown timed out")
        };
        exitCode(outcome)

    ///
    /// 接続が全部閉じるか期限が来るまで待ち、その時点の接続数を返す。
    ///
    def awaitConnections(listener: HttpServer.Listener, deadline: Int64): Int32 \ IO =
        let active = HttpServer.connections(listener)#active;
        if (active <= 0) 0
        else if (System.currentTimeMillis() > deadline) active
        else { Thread.sleep(pollMs()); awaitConnections(listener, deadline) }

}
