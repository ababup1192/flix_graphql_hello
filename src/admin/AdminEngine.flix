///
/// 管理 API のエンジンの置き場。スキーマは固定だが Runner がプロジェクトを持つので、プロジェクトごとに 1 つ組んで持つ。
///
mod AdminEngine {

    import java.util.concurrent.atomic.AtomicReference
    import java.lang.Object

    /// エンジンの置き場と、Runner に渡す asset の保存先。
    pub enum Cache {
        case Cache(Option[StorageConfig.StorageConfig], AtomicReference[Object])
    }

    pub def create(storage: Option[StorageConfig.StorageConfig]): Cache \ IO =
        let empty: Map[ProjectId, Graphql.Engine] = Map.empty();
        Cache.Cache(storage, new AtomicReference(unchecked_cast(empty as Object)))

    ///
    /// プロジェクトのエンジン。無ければ組んで置く。組めないのは SDL と生成物の不一致なので、起動時の既定プロジェクトで止まる。
    ///
    pub def current(cache: Cache, pool: Pool, projectId: ProjectId): Result[String, Graphql.Engine] \ IO =
        let Cache.Cache(storage, slot) = cache;
        let engines: Map[ProjectId, Graphql.Engine] = unchecked_cast(slot.get() as Map[ProjectId, Graphql.Engine]);
        match Map.get(projectId, engines) {
            case Some(engine) => Ok(engine)
            case None =>
                Graphql.buildEngine(AdminSchema.make(AdminRunner.make(pool, storage, projectId)))
                    |> Result.map(engine -> { slot.set(unchecked_cast(Map.insert(projectId, engine, engines) as Object)); engine })
        }

}
