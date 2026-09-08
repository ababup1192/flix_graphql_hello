///
/// スレッドの境界（接続ごとのスレッド、バックグラウンドワーカー）で受けた Throwable の扱い。
/// 受けてよい物（Exception、VerifyError のような Error）はログして続け、JVM 自体が壊れている物（OutOfMemoryError）は再送出する。
///
mod JvmErrors {

    import java.lang.StackOverflowError
    import java.lang.Throwable
    import java.lang.VirtualMachineError

    ///
    /// 飲み込んではいけない物か。VirtualMachineError（OutOfMemoryError / InternalError）は true。
    ///
    /// WhyNot: StackOverflowError を fatal にしないのは、VirtualMachineError の子ではあるが 1 リクエストの深い再帰で起きる物で、
    /// そのスレッドを畳めば JVM は続けられるため。
    ///
    /// WhyNot: `instanceof` でなく throw して catch で判定するのは、Flix に型の判定式が無く、catch の並びなら子クラスを先に書けるため。
    ///
    pub def isFatal(error: Throwable): Bool \ IO =
        try {
            throw error
        } catch {
            case _: StackOverflowError  => false
            case _: VirtualMachineError => true
            case _: Throwable           => false
        }

    ///
    /// ログに出す文言。message があればそれ、null ならクラス名（VerifyError は message が null の事がある）。
    ///
    pub def describe(error: Throwable): String \ IO =
        let message: String = error.getMessage();
        if (Object.isNull(message)) error.getClass().getName() else message

}
