///
/// Flix 0.75.3 の try / catch と `run … with handler` の入れ子で、中で飛んだ JVM の例外がどこで受かるか（実測の表）。
/// DbRunner.guarded / BackgroundJobs.guarded / HttpServer の網はこの表を前提に置いてある。
///
///   受かる:   try { run { op(内側の handler へ); throw } }                       … handler が try の内側なら何段でも
///   受かる:   run { try { op(外側の handler へ); throw } }                       … try の直下から外へ op を投げるだけ（guarded の形）
///   受かる:   run { try { run { op(外側へ) }; throw } }                          … 外へ op を通した run を抜けた後の throw
///   素通り:   run { try { run { op(外側へ); throw } } }                          … 外へ op を通した run の**中**で throw
///   素通り:   run { try { op } } with handler { def op = throw }                 … handler の本体が投げ、handler は try の外
///
mod TestJvmCatchNesting {

    import java.lang.Throwable
    import java.lang.VerifyError

    pub eff Boom {
        def boom(): Unit
    }

    /// try / catch。受かれば Err("caught")。
    def attempt(thunk: Unit -> Unit \ ef): Result[String, Unit] \ ef =
        try {
            Ok(thunk())
        } catch {
            case _: Throwable => Err("caught")
        }

    def blow(): Unit \ IO =
        throw new VerifyError("boom")

    /// handler が try の内側（Main.dispatch と HttpServer.respond の形）。Observe と Log の op を呼んでから throw しても受かる。
    @Test
    def testHandlerInsideTryCatches(): Unit \ {Assert, IO} =
        let extra = Ref.fresh(Static, Log.Fields.empty());
        Assert.assertEq(expected = Err("caught"), attempt(() ->
            run {
                Observe.runWithRef(extra, () -> { Observe.note(Log.Fields.empty()); Log.info("x", Log.Fields.empty()); blow() })
            } with Log.withFields(Log.Fields.empty())
              with Log.runWith(Log.Sink.silent())))

    /// try の直下から外側の handler へ op を投げてから throw（DbRunner.guarded の形）。受かる。
    @Test
    def testOpToOuterHandlerDirectlyUnderTryCatches(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err("caught"),
            Tenant.runWith(ProjectId.default(), () -> attempt(() -> { discard Tenant.current(); blow() })))

    /// 外側の handler へ op を通した run を抜けてから throw。受かる。
    @Test
    def testThrowAfterInnerRunFinishedCatches(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Err("caught"),
            Tenant.runWith(ProjectId.default(), () -> attempt(() -> { Session.runWith(Actor.System, () -> discard Tenant.current()); blow() })))

    /// 外側の handler へ op を通した run の中で throw。try を素通りして、handler の外の catch まで飛ぶ。
    @Test
    def testThrowInsideInnerRunAfterOuterOpEscapes(): Unit \ {Assert, IO} =
        let inner = Ref.fresh(Static, "not reached");
        let outer = attempt(() -> Tenant.runWith(ProjectId.default(), () -> {
            let caught = attempt(() -> Session.runWith(Actor.System, () -> { discard Tenant.current(); blow() }));
            Ref.put("inner ${caught}", inner)
        }));
        Assert.assertEq(expected = (Err("caught"), "not reached"), (outer, Ref.get(inner)))

    /// handler の本体が投げる。handler が try の外なら素通りし、内側なら受かる。
    @Test
    def testHandlerBodyThrowTable(): Unit \ {Assert, IO} =
        let inner = Ref.fresh(Static, "not reached");
        let handlerOutside = attempt(() -> run {
            let caught = attempt(() -> TestJvmCatchNesting.Boom.boom());
            Ref.put("inner ${caught}", inner)
        } with handler Boom { def boom(resume) = { blow(); resume(()) } });
        let handlerInside = attempt(() -> run { TestJvmCatchNesting.Boom.boom() } with handler Boom { def boom(resume) = { blow(); resume(()) } });
        Assert.assertEq(expected = (Err("caught"), "not reached", Err("caught")), (handlerOutside, Ref.get(inner), handlerInside))

}
