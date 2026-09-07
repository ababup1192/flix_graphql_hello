///
/// プロジェクトごとに 1 つの値（組み立て済みの GraphQL エンジン）を、目印と一緒に置く場所。
/// 管理 API とコンテンツ API の両方が使う。中身は DB の定義から作り直せる物だけで、状態を持たない（2 台化しても手を入れない）。
///
/// WhyNot: AtomicReference[Object] と unchecked_cast で持つのは、Flix の Java interop が総称型の
/// AtomicReference[Map[...]] を書けないため。読み書きはこの mod に閉じる。
///
mod EngineCache {

    import java.util.concurrent.atomic.AtomicReference
    import java.lang.Object

    ///
    /// 置き場。
    ///
    pub enum Cache {
        case Cache(AtomicReference[Object])
    }

    ///
    /// 空の置き場。
    ///
    pub def create(): Cache \ IO =
        let empty: Map[ProjectId, (String, Graphql.Engine)] = Map.empty();
        Cache.Cache(new AtomicReference(unchecked_cast(empty as Object)))

    ///
    /// プロジェクトの (目印, 値)。無ければ None。
    ///
    pub def get(projectId: ProjectId, cache: Cache): Option[(String, Graphql.Engine)] \ IO =
        Map.get(projectId, entries(cache))

    ///
    /// プロジェクトの値を目印と一緒に置く（上書き）。2 つのリクエストが同時に置くと後の方が勝つが、どちらも同じ目印から組んだ物。
    ///
    pub def put(projectId: ProjectId, fingerprint: String, value: Graphql.Engine, cache: Cache): Unit \ IO =
        let Cache.Cache(slot) = cache;
        slot.set(unchecked_cast(Map.insert(projectId, (fingerprint, value), entries(cache)) as Object))

    def entries(cache: Cache): Map[ProjectId, (String, Graphql.Engine)] \ IO =
        let Cache.Cache(slot) = cache;
        unchecked_cast(slot.get() as Map[ProjectId, (String, Graphql.Engine)])

}
