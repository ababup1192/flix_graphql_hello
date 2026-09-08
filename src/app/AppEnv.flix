///
/// リクエストとバックグラウンドの仕事に共通の環境の handler。id の採番、今のプロジェクト、asset の置き先、HTTP、時計、ログを
/// 1 か所で入れ、Runner / CLI はここを呼ぶだけにする。HTTP は deps の HttpClient（プロセスで 1 つ）で捌く（OutboundHttp）。Tx（DbRunner）と主体（Session）はこの中で張る。
///
/// WhyNot: Session をここで入れないのは、主体が Tx の中（身元の解決）で決まるため。プロジェクトと依存は Tx の前に決まっている。
///
mod AppEnv {

    ///
    /// プロジェクトのある環境（管理 API・コンテンツ API・仕事）。上の handler が内側。
    ///
    /// WhyNot: ObjectStore.runWith を Http / Clock より上（内側）に書くのは、ObjectStore の handler が Http と Clock を出すため。
    /// 逆にすると E6469（handler の外に Http が残る）。
    ///
    pub def runWith(deps: Deps, span: Log.Fields, projectId: ProjectId, f: Unit -> a \ ef): a \ (ef - {IdGen, Tenant, Net.Http.Http, Time.Clock.Clock, ObjectStore, Log}) + IO =
        run f()
          with IdGen.runWithRandom
          with Tenant.runWith(projectId)
          with ObjectStore.runWith(deps#storage)
          with OutboundHttp.runWith(deps#http)
          with Time.Clock.runWithIO
          with Log.withFields(span)
          with Log.runWith(deps#log)

    ///
    /// Account API 用。Tenant を張らない（プロジェクトのユースケースを呼べば型で落ちる）。
    ///
    pub def runWithoutProject(deps: Deps, span: Log.Fields, f: Unit -> a \ ef): a \ (ef - {IdGen, Net.Http.Http, Time.Clock.Clock, ObjectStore, Log}) + IO =
        run f()
          with IdGen.runWithRandom
          with ObjectStore.runWith(deps#storage)
          with OutboundHttp.runWith(deps#http)
          with Time.Clock.runWithIO
          with Log.withFields(span)
          with Log.runWith(deps#log)

}
