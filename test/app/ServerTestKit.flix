///
/// Server / ワーカーをテストから呼ぶ時の共通の包み。Route と tick は Log（と Time.Clock）を持つので、行を捨てて時計を 0 に固定する。
///
mod ServerTestKit {

    ///
    /// Log の行を捨て、Time.Clock を 0 に固定して f を走らせる。テストの署名に Log を足さないための包み。
    ///
    pub def quietly(f: Unit -> a \ ef): a \ ef - {Log, Time.Clock.Clock} =
        fst(Log.runWithList(() -> withFixedClock(f)))

    /// Time.Clock を 0 に固定する。
    def withFixedClock(f: Unit -> a \ ef): a \ ef - Time.Clock.Clock =
        run f() with handler Time.Clock.Clock {
            def currentTime(_unit, resume) = resume(0i64)
        }

}
