///
/// 今のリクエストが属するプロジェクト。ユースケースはこれを読んで SQL に project_id を渡す。
///
/// WhyNot: ProjectId を引数で引き回さないのは、ContentTypes / ContentEntries のほぼ全部の関数と
/// リゾルバの写しに 1 つずつ足す事になり、足し忘れがコンパイルで見つからないため。effect なら
/// 読む関数の型に Tenant が出て、handler の無い所（テストや起動時）はコンパイルで止まる。
///
pub eff Tenant {
    def current(): ProjectId
}

mod Tenant {

    ///
    /// projectId を固定して f を走らせる。Runner がリクエストごとに、テストは既定のプロジェクトで入れる。
    ///
    pub def runWith(projectId: ProjectId, f: Unit -> a \ ef): a \ ef - Tenant =
        run f() with handler Tenant {
            def current(resume) = resume(projectId)
        }

    ///
    /// SQL に渡す形。
    ///
    pub def currentId(): Int64 \ Tenant = ProjectId.toInt64(Tenant.current())

}
