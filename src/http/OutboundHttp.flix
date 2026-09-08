///
/// 外へ出す HTTP（JWKS の取得、Webhook の POST、CDN の purge、asset の置き先の署名付き URL）の `Net.Http.Http` の handler。
/// `java.net.http.HttpClient` はプロセスで 1 つ作り（`newClient`。Main が Deps に持たせる）、handler を入れるたびにそれを使い回す。
///
/// WhyNot: 標準ライブラリの `Net.Http.runWithIO` を使わないのは、Flix 0.75.3 のそれが handler を入れるたびに
/// `HttpClient.newBuilder().build()` を呼び、HttpClient ごとに `HttpClient-N-SelectorManager` のスレッドが GC まで残るため。
/// Runner はフィールドごとに handler を入れるので 1 リクエストで数百〜千個（2026-09-08 の実機 E2E: 管理 API の entries 50 × 10 で 1,095 個）が立ち、
/// `unable to create native thread` の OutOfMemoryError で落ちた。
///
/// WhyNot: handler をフィールドごとでなくリクエスト 1 回（Main.runRoute）に上げないのは、リゾルバが graphql-java の Java コールバックの中で動き、
/// effect の handler がそこを越えないため（asset のリゾルバは ObjectStore 越しに Http を使う）。標準ライブラリに既存の client を渡す handler は無いが、
/// `Net.HttpLayer.execute` は pub なので、同じ op の形で client を外から受ける handler をここに置く。
///
mod OutboundHttp {

    import java.net.http.HttpClient

    use Net.Http.Http

    ///
    /// プロセスで 1 つ持つ HttpClient。標準ライブラリの既定と同じ設定（redirect は NORMAL、connect timeout 無し）。
    ///
    pub def newClient(): HttpClient \ IO =
        Net.HttpLayer.newDefaultClient()

    ///
    /// client で `Net.Http.Http` を捌く。標準ライブラリの `Net.Http.handle` と同じ op の形で、client だけ外から受ける。
    ///
    pub def runWith(client: HttpClient, f: Unit -> a \ ef): a \ (ef - Http) + IO =
        run f() with handler Http {
            def request(req, resume) = resume(Net.HttpLayer.execute(_ -> Ok(()), client, req))
        }

}
