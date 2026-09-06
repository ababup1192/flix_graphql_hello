///
/// コンテンツ API の Runner。読むだけなので Tx は要らないが、フィールド単位で接続を借り直さないよう
/// withLazyTx で「最初の SQL で借りて最後に返す」にする。DbFailure を GraphQL のエラーに写す。
///
mod ContentRunner {

    ///
    /// プールから Runner を作る。
    ///
    pub def make(pool: Pool): Runner[ContentEff] =
        f -> runOne(pool, f)

    def runOne(pool: Pool, f: Unit -> Result[FieldError, JavaValue.Boxed] \ ContentEff + IO): Result[FieldError, JavaValue.Boxed] \ IO =
        match DbError.runWithFailure(() -> Retry.withRetry(3, () -> Pool.withLazyTx(pool, f))) {
            case Err(failure) => Err("database error: ${failure}")
            case Ok(result)   => result
        }

}

///
/// コンテンツ API のエンジンの置き場。型の定義が変わったら組み直す。
/// 判断は content_types の件数と最新の updated_at（schemaFingerprint）で、リクエストごとに 1 本の SELECT を出す。
///
/// WhyNot: 管理 API の Mutation の後で明示的に組み直さないのは、複数台で動かした時に他の台の変更を拾えないため。
/// 目印を毎回見る方が単純で、SELECT 1 本は /health と同じ重さ。
///
mod ContentEngine {

    import java.util.concurrent.atomic.AtomicReference
    import java.lang.Object

    ///
    /// 組み立て済みのエンジンと、その時の目印。
    ///
    pub enum Cache {
        case Cache(AtomicReference[Object])
    }

    ///
    /// 空の置き場。最初のリクエストで組む。
    ///
    pub def create(): Cache \ IO =
        let empty: Option[(String, Graphql.Engine)] = None;
        Cache.Cache(new AtomicReference(unchecked_cast(empty as Object)))

    ///
    /// 今の定義に合ったエンジン。目印が変わっていなければ前の物を返す。定義の読み込みや組み立てに失敗すれば Err。
    ///
    pub def current(cache: Cache, pool: Pool): Result[String, Graphql.Engine] \ IO =
        let Cache.Cache(slot) = cache;
        let stored: Option[(String, Graphql.Engine)] = unchecked_cast(slot.get() as Option[(String, Graphql.Engine)]);
        forM (
            fingerprint <- readFingerprint(pool);
            engine <- match stored {
                case Some((known, engine)) if known == fingerprint => Ok(engine)
                case _ => rebuild(pool) |> Result.map(engine -> { slot.set(unchecked_cast(Some((fingerprint, engine)) as Object)); engine })
            }
        ) yield engine

    ///
    /// 定義を読んで組み直す。
    ///
    def rebuild(pool: Pool): Result[String, Graphql.Engine] \ IO =
        DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> ContentTypes.list()))
            |> Result.mapErr(failure -> "content type の定義を読めません: ${failure}")
            |> Result.flatMap(types -> Graphql.buildEngine(ContentSchemaBuilder.build(types, ContentRunner.make(pool))))

    def readFingerprint(pool: Pool): Result[String, String] \ IO =
        DbError.runWithFailure(() -> Pool.withLazyTx(pool, () -> ContentTypesQueries.schemaFingerprint()))
            |> Result.mapErr(failure -> "content type の目印を読めません: ${failure}")
            |> Result.map(row -> match row {
                case Some(found) => "${found#types |> Option.getWithDefault(0i64)}/${found#latest |> Option.map(Timestamp.toIso8601) |> Option.getWithDefault("-")}"
                case None        => "0/-"
            })


}
