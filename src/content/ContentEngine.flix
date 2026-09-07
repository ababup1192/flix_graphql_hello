///
/// コンテンツ API のエンジンの置き場。プロジェクトごとに 1 つ持ち、型の定義が変わったら組み直す。
/// 判断は content_types の件数と最新の updated_at（schemaFingerprint）で、リクエストごとに 1 本の SELECT を出す。
///
/// WhyNot: 管理 API の Mutation の後で明示的に組み直さないのは、複数台で動かした時に他の台の変更を拾えないため。
/// 目印を毎回見る方が単純で、SELECT 1 本は /health と同じ重さ。
///
mod ContentEngine {

    ///
    /// エンジンの置き場と、Runner に渡す依存。
    ///
    pub enum Cache {
        case Cache(Deps, EngineCache.Cache)
    }

    ///
    /// 空の置き場。最初のリクエストで組む。
    ///
    pub def create(deps: Deps): Cache \ IO =
        Cache.Cache(deps, EngineCache.create())

    ///
    /// 今の定義に合ったエンジン。目印が変わっていなければ前の物を返す。定義の読み込みや組み立てに失敗すれば、
    /// 前に組めた物があればそれを返し続け、無ければ Err。
    ///
    /// WhyNot: 組み直しに失敗した時に前のエンジンを捨てないのは、管理 API の 1 操作（名前の衝突など）で公開サイトが
    /// 全断するのを避けるため。目印は更新しないので、定義が直れば次のリクエストで組み直す。
    ///
    pub def current(cache: Cache, pool: Pool, projectId: ProjectId): Result[String, Graphql.Engine] \ IO =
        let Cache.Cache(deps, engines) = cache;
        let stored = EngineCache.get(projectId, engines);
        match readFingerprint(pool, projectId) {
            case Err(message)     => stored |> Option.map(snd) |> Option.toOk(message)
            case Ok(fingerprint) => match stored {
                case Some((known, engine)) if known == fingerprint => Ok(engine)
                case _ => match rebuild(pool, deps, projectId) {
                    case Ok(engine)   => { EngineCache.put(projectId, fingerprint, engine, engines); Ok(engine) }
                    case Err(message) => stored |> Option.map(snd) |> Option.toOk(message)
                }
            }
        }

    ///
    /// 定義を読んで組み直す。
    ///
    def rebuild(pool: Pool, deps: Deps, projectId: ProjectId): Result[String, Graphql.Engine] \ IO =
        read(pool, "content type の定義を読めません", () -> Tenant.runWith(projectId, () -> Session.runWith(Actor.System, () -> CmsErr.runWithResult(ContentTypes.list))))
            |> Result.flatMap(loaded -> loaded |> Result.mapErr(failure -> "content type の定義を読めません: ${CmsErr.toMessage(failure)}"))
            |> Result.flatMap(types -> Graphql.buildEngine(ContentSchemaBuilder.build(types, ContentRunner.make(pool, deps, projectId))))

    def readFingerprint(pool: Pool, projectId: ProjectId): Result[String, String] \ IO =
        read(pool, "content type の目印を読めません", () -> ContentTypesQueries.schemaFingerprint(ProjectId.toInt64(projectId)))
            |> Result.map(row -> match row {
                case Some(found) => "${found#types |> Option.getWithDefault(0i64)}/${found#latest |> Option.map(Timestamp.toIso8601) |> Option.getWithDefault("-")}"
                case None        => "0/-"
            })

    ///
    /// プールから接続を借りて thunk を 1 つの遅延 Tx で走らせ、DbFailure を label 付きの文字列にする。一時的な失敗は Runner と同じく再試行する。
    ///
    def read(pool: Pool, label: String, thunk: Unit -> a \ ef): Result[String, a] \ (ef - {SqlRead, SqlWrite, TransientDbErr, DbErr}) + IO =
        DbRunner.retrying(() -> Pool.withLazyTx(pool, thunk)) |> Result.mapErr(failure -> "${label}: ${failure}")

}
