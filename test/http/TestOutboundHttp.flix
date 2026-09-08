///
/// OutboundHttp: 同じ HttpClient で handler を何度入れても、HttpClient のスレッド（`HttpClient-N-SelectorManager`）が増えない。
/// Runner がフィールドごとに AppEnv.runWith（中で OutboundHttp.runWith）を入れる形を GraphQL 越しに 100 回回して、スレッドの数の差で見る。
///
mod TestOutboundHttp {

    import java.lang.Thread

    use Schema.{objectType, field0}

    /// 今のプロジェクトの id を文字列で（effect を使う式はラムダに直に書かず、関数に切り出す）。
    def projectText(): String \ Tenant =
        "${Tenant.current()}"

    /// Runner が AppEnv.runWith（IdGen / Tenant / Http / Clock / ObjectStore / Log の handler）を通す、本番と同じ形のスキーマ。
    def schemaThrough(deps: Deps): Schema =
        Schema.make(
            objectType("Query", () -> field0("project", Out.string(), (_context, _root) -> Ok(projectText())) :: Nil),
            None,
            (context, f) -> AppEnv.runWith(deps, context#log, ProjectId.default(), f))

    /// 生きているスレッドのうち、名前に SelectorManager を含む物の数（Set の toString に並ぶ `Thread[#n,名前,…]` を数える）。
    def selectorManagerThreads(): Int32 \ IO =
        String.countSubstring(substr = "SelectorManager", Thread.getAllStackTraces().keySet().toString())

    ///
    /// 1 回流した後（client のスレッドは 1 本以上ある）から 100 回流しても、SelectorManager のスレッドは増えない（差 0）。
    /// 標準ライブラリの Net.Http.runWithIO は handler ごとに HttpClient を作るので、ここで 100 増える。
    ///
    @Test
    def testSameClientDoesNotAddThreads(): Unit \ {Assert, IO} =
        let deps = Deps.forTest(None);
        let engine = match Graphql.buildEngine(schemaThrough(deps)) {
            case Ok(built)    => built
            case Err(message) => bug!("engine: ${message}")
        };
        let ask = () -> GraphqlTestKit.askEngine(engine, "{ project }");
        let warmup = ask();
        let before = selectorManagerThreads();
        List.forEach(_ -> discard ask(), List.range(0, 100));
        let after = selectorManagerThreads();
        Assert.assertEq(
            expected = ((Value.Obj(Map#{ "project" => Value.Str("${ProjectId.default()}") }), None), true, 0),
            (warmup, before >= 1, after - before))

}
