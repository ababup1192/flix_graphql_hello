///
/// Runner に渡す、リクエストをまたいで同じ物。asset の保存先と認証の設定。リクエストごとの主体の解決は RequestIdentity。
///
/// - storage: asset の保存先。無ければ asset の操作だけ Err
/// - auth: 本人確認のやり方、bootstrap の owner、API キーの pepper
///
pub type alias Deps = { storage = Option[StorageConfig.StorageConfig], auth = AuthConfig.AuthConfig }

mod Deps {

    ///
    /// テスト用。認証は閉じ、bootstrap の owner と pepper は決め打ち。
    ///
    pub def forTest(storage: Option[StorageConfig.StorageConfig]): Deps =
        { storage = storage,
          auth = { mode = AuthConfig.Mode.Closed, tokenHeader = "Authorization",
                   bootstrap = { ownerEmail = Some("owner@test") },
                   signup = Signup.Open,
                   pepper = Some({ pepperId = "test", secret = "test-pepper" }) } }

}
