///
/// スレッドの境界（接続ごとのスレッド、バックグラウンドワーカー）で受けた Throwable の扱い。
/// 受けてよい物（Exception、VerifyError のような Error）はログして続け、JVM 自体が壊れている物（OutOfMemoryError）は fatal として上に知らせる。
///
mod JvmErrors {

    import java.lang.StackOverflowError
    import java.lang.Throwable
    import java.lang.VirtualMachineError
    import java.util.concurrent.CompletionException
    import java.util.concurrent.ExecutionException

    ///
    /// 飲み込んではいけない物か。VirtualMachineError（OutOfMemoryError / InternalError）は true。cause の連鎖のどこかにあれば true。
    ///
    /// WhyNot: 一番外の例外だけを見ないのは、リゾルバの中で起きた OutOfMemoryError を graphql-java が `CompletionException` に包んで
    /// 投げ返し、外側だけ見ると Exception として 500 で飲み込まれるため（2026-09-08 の実機 E2E で `unable to create native thread` が
    /// そうなった。HttpServer の再送出も、JVM の `-XX:+ExitOnOutOfMemoryError` も効かず、プロセスが壊れたまま生き残った）。
    ///
    pub def isFatal(error: Throwable): Bool \ IO =
        isFatalWithin(error, 0)

    /// cause を辿る深さの上限。自分自身を cause に持つ物や長い連鎖で止まらない事の無いように。
    def maxCauseDepth(): Int32 = 8

    def isFatalWithin(error: Throwable, depth: Int32): Bool \ IO =
        if (isFatalItself(error)) true
        else {
            let cause = error.getCause();
            if (Object.isNull(cause) or depth >= maxCauseDepth()) false
            else isFatalWithin(cause, depth + 1)
        }

    ///
    /// その例外自体が fatal か（cause は見ない）。
    ///
    /// WhyNot: StackOverflowError を fatal にしないのは、VirtualMachineError の子ではあるが 1 リクエストの深い再帰で起きる物で、
    /// そのスレッドを畳めば JVM は続けられるため。
    ///
    /// WhyNot: `instanceof` でなく throw して catch で判定するのは、Flix に型の判定式が無く、catch の並びなら子クラスを先に書けるため。
    ///
    def isFatalItself(error: Throwable): Bool \ IO =
        try {
            throw error
        } catch {
            case _: StackOverflowError  => false
            case _: VirtualMachineError => true
            case _: Throwable           => false
        }

    ///
    /// 包みを剥がした本当の例外。CompletionException / ExecutionException（graphql-java と Future が投げ返す時の包み）は cause を辿る。
    /// cause が無ければそのまま。
    ///
    /// WhyNot: 包みのままログに出さないのは、exception.type が全部 `CompletionException` になり、message も
    /// `java.lang.OutOfMemoryError: …` のように cause の文言を前置きで抱えた形になって、種類で集計できないため。
    ///
    pub def unwrap(error: Throwable): Throwable \ IO =
        unwrapWithin(error, 0)

    def unwrapWithin(error: Throwable, depth: Int32): Throwable \ IO =
        let cause = error.getCause();
        if (not isWrapper(error) or Object.isNull(cause) or depth >= maxCauseDepth()) error
        else unwrapWithin(cause, depth + 1)

    /// 中の例外を包んで投げ返すだけの物か。
    def isWrapper(error: Throwable): Bool \ IO =
        try {
            throw error
        } catch {
            case _: CompletionException => true
            case _: ExecutionException  => true
            case _: Throwable           => false
        }

    ///
    /// ログに出す文言。包みを剥がした例外の message があればそれ、null ならクラス名（VerifyError は message が null の事がある）。
    ///
    pub def describe(error: Throwable): String \ IO =
        let actual = unwrap(error);
        let message: String = actual.getMessage();
        if (Object.isNull(message)) actual.getClass().getName() else message

}
