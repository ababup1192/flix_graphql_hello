///
/// CounterStore effect の偽ハンドラ。値をメモリ上の Ref に持ち、SQLite 無しでリゾルバを動かす。
///
mod CounterFake {
    import java.util.concurrent.atomic.AtomicInteger

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
    /// cell を保存先にして f を実行する。Runner はフィールドの fetch ごとに走るので、1 つのクエリの中で
    /// 値を共有したいときは cell を外で 1 つ作って渡す。
    ///
    /// WhyNot: Ref を使わないのは、Ref は region に閉じていて、Runner のクロージャに持ち出せないため。
    ///
    pub def runWithCell(cell: AtomicInteger, f: Unit -> a \ ef): a \ (ef - CounterStore) + IO =
        run f() with handler CounterStore {
            def load(resume)          = resume(Ok(cell.get()))
            def increment(by, resume) = resume(Ok(cell.addAndGet(by)))
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
