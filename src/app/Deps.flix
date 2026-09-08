import java.net.http.HttpClient

///
/// Runner に渡す、リクエストをまたいで同じ物。asset の保存先と認証の設定、外へ出す HTTP の client、ログの出力先。リクエストごとの主体の解決は RequestIdentity。
///
/// - storage: asset の保存先。無ければ asset の操作だけ Err
/// - auth: 本人確認のやり方、bootstrap の owner、API キーの pepper
/// - http: 外へ出す HTTP の client（プロセスで 1 つ。OutboundHttp.runWith が使う）
/// - log: ログの出力先。Runner がリゾルバの中で Log を入れ直すのに使う
///
/// WhyNot: Runner が dispatch の Log の handler を使えないのは、リゾルバが graphql-java の Java コールバックの中で呼ばれ、
/// effect の操作が外の handler に届かないため（Runner の戻りは IO）。出力先は値なので Deps で渡して入れ直す。
///
/// WhyNot: HttpClient を handler を入れる所で作らないのは、HttpClient ごとにスレッドが残り、フィールドごとの handler で native thread の OOM になるため（OutboundHttp）。
///
pub type alias Deps = { storage = Option[StorageConfig.StorageConfig], auth = AuthConfig.AuthConfig, http = HttpClient, log = Log.Sink }

mod Deps {

    ///
    /// テスト用。認証は閉じ、bootstrap の owner と pepper は決め打ち。ログは捨てる。HttpClient は 1 つ作る。
    ///
    pub def forTest(storage: Option[StorageConfig.StorageConfig]): Deps \ IO =
        { storage = storage,
          auth = { mode = AuthConfig.Mode.Closed, tokenHeader = "Authorization",
                   bootstrap = { ownerEmail = Some("owner@test") },
                   signup = Signup.Open,
                   pepper = Some({ pepperId = "test", secret = "test-pepper" }) },
          http = OutboundHttp.newClient(),
          log = Log.Sink.silent() }

}
