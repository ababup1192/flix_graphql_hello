///
/// CounterStore effect の偽ハンドラ。値をメモリ上の Ref に持ち、SQLite 無しでリゾルバを動かす。
///
mod CounterFake {

    ///
    /// initial から始まるカウンタをメモリに置いて f を実行する。
    ///
    pub def runWithMemory(initial: Int32, f: Unit -> a \ ef): a \ ef - CounterStore = region rc {
        let cell = Ref.fresh(rc, initial);
        run f() with handler CounterStore {
            def load(resume) = resume(Ok(Ref.get(cell)))
            def increment(by, resume) = {
                Ref.put(Ref.get(cell) + by, cell);
                resume(Ok(Ref.get(cell)))
            }
        }
    }

    ///
    /// 保存先が壊れている状況。どちらの操作も Err を返す。
    ///
    pub def runWithBroken(message: String, f: Unit -> a \ ef): a \ ef - CounterStore =
        run f() with handler CounterStore {
            def load(resume)         = resume(Err(message))
            def increment(_, resume) = resume(Err(message))
        }

}
