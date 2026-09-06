///
/// Health effect の偽ハンドラ。DB を使わずに Server を確かめる。
///
mod HealthFake {

    ///
    /// checkDb が常に Ok を返す。
    ///
    pub def runWithOk(f: Unit -> a \ ef): a \ ef - Health =
        run f() with handler Health {
            def checkDb(resume) = resume(Ok(()))
        }

    ///
    /// checkDb が常に message の Err を返す。
    ///
    pub def runWithFailure(message: String, f: Unit -> a \ ef): a \ ef - Health =
        run f() with handler Health {
            def checkDb(resume) = resume(Err(message))
        }

}
