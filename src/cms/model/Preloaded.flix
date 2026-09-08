///
/// リクエストの間だけ持つ先読みの写し。一覧のリゾルバがページの entry id を覚え（SQL 無し）、行のフィールドのリゾルバが
/// 最初の 1 行でページの分をまとめて引いて写しに入れ、残りの行は写しから返す。
/// 写しはヒント。無ければ（Runner が写し無しで入れた時、id がページに無い時）今まで通り 1 件ずつ引く。正しさは写し無しでも同じ。
///
/// WhyNot: 一覧のリゾルバで版や型まで引いてしまわないのは、versions / diff を選ばない一覧で SQL が増えるため。id を覚えるだけなら SQL は出ない。
/// WhyNot: Context の Ref をリゾルバから直に読み書きしないのは、リゾルバの effect（AdminEff）に IO が無く、写しの有無で handler を差し替える方が
/// Runner に閉じるため。
///
pub eff Preloaded {
    ///
    /// 一覧のページの entry id を覚える。
    ///
    def keepEntryIds(ids: List[EntryId]): Unit
    ///
    /// 覚えたページの entry id。
    ///
    def entryIds(): Set[EntryId]
    ///
    /// 写しにある版（新しい順）。
    ///
    def versions(id: EntryId): Option[List[EntryVersion]]
    ///
    /// 版を写しに入れる。
    ///
    def keepVersions(found: Map[EntryId, List[EntryVersion]]): Unit
    ///
    /// 写しにある content type。
    ///
    def contentType(id: TypeId): Option[ContentType]
    ///
    /// content type を写しに入れる。
    ///
    def keepContentType(owner: ContentType): Unit
}

mod Preloaded {

    ///
    /// 写しの中身。
    ///
    /// - entryIds: 一覧が返したページの entry id
    /// - versions: entry id → 版（新しい順）
    /// - types: content type の id → 定義（フィールド付き）
    ///
    pub type alias Store = { entryIds = Set[EntryId], versions = Map[EntryId, List[EntryVersion]], types = Map[TypeId, ContentType] }

    ///
    /// 空の写し。
    ///
    pub def empty(): Store = { entryIds = Set.empty(), versions = Map.empty(), types = Map.empty() }

    ///
    /// 写しを Context の Ref で持つハンドラ。None なら覚えず、写しは常に無い（1 件ずつ引く道だけになる）。
    ///
    pub def runWith(store: Option[Ref[Store, Static]], f: Unit -> a \ ef): a \ (ef - Preloaded) + IO =
        run f() with handler Preloaded {
            def keepEntryIds(ids, resume) = { update(store, found -> { entryIds = Set.union(List.toSet(ids), found#entryIds) | found }); resume(()) }
            def entryIds(resume) = resume(read(store) |> Option.map(found -> found#entryIds) |> Option.getWithDefault(Set.empty()))
            def versions(id, resume) = resume(read(store) |> Option.flatMap(found -> Map.get(id, found#versions)))
            def keepVersions(fetched, resume) = { update(store, found -> { versions = Map.union(fetched, found#versions) | found }); resume(()) }
            def contentType(id, resume) = resume(read(store) |> Option.flatMap(found -> Map.get(id, found#types)))
            def keepContentType(owner, resume) = { update(store, found -> { types = Map.insert(owner#id, owner, found#types) | found }); resume(()) }
        }

    def read(store: Option[Ref[Store, Static]]): Option[Store] \ IO =
        store |> Option.map(Ref.get)

    def update(store: Option[Ref[Store, Static]], f: Store -> Store): Unit \ IO =
        Option.forEach(cell -> Ref.put(f(Ref.get(cell)), cell), store)

}
