///
/// Server / ワーカーをテストから呼ぶ時の共通の包み。Route と tick は Log（Route は Observe も）を持つので、行と属性を捨てる。
///
mod ServerTestKit {

    ///
    /// Log の行と Observe の属性を捨てて f を走らせる。テストの署名に Log を足さないための包み。属性を見るテストは `Observe.collect` を直に使う。
    ///
    pub def quietly(f: Unit -> a \ ef): a \ ef - {Log, Observe} =
        fst(Log.runWithList(() -> Observe.ignore(f)))

}
