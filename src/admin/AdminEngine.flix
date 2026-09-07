///
/// 管理 API のエンジンの置き場。スキーマは固定だが Runner がプロジェクトを持つので、プロジェクトごとに 1 つ組んで持つ。
///
mod AdminEngine {

    /// エンジンの置き場と、Runner に渡す asset の保存先。
    pub enum Cache {
        case Cache(Option[StorageConfig.StorageConfig], EngineCache.Cache)
    }

    pub def create(storage: Option[StorageConfig.StorageConfig]): Cache \ IO =
        Cache.Cache(storage, EngineCache.create())

    ///
    /// プロジェクトのエンジン。無ければ組んで置く。組めないのは SDL と生成物の不一致なので、起動時の既定プロジェクトで止まる。
    ///
    pub def current(cache: Cache, pool: Pool, projectId: ProjectId): Result[String, Graphql.Engine] \ IO =
        let Cache.Cache(storage, engines) = cache;
        match EngineCache.get(projectId, engines) {
            case Some((_, engine)) => Ok(engine)
            case None =>
                Graphql.buildEngine(AdminSchema.make(AdminRunner.make(pool, storage, projectId)))
                    |> Result.map(engine -> { EngineCache.put(projectId, "", engine, engines); engine })
        }

}
