///
/// フィールドの木。平らな FieldDef の並び（parent で親を指す）と、children に子を抱えた木のあいだの操作。純粋。
///
mod FieldTree {

    ///
    /// 平らな並びを木にする。最上位（parent 無し）を position 順に並べ、子は再帰で付ける。
    ///
    pub def build(flat: List[FieldDef]): List[FieldDef] =
        childrenOf(groupBy(field -> field#parent, flat), None)

    ///
    /// 型ごとに分ける。全型のフィールドを 1 本で読んだ後に配る用。並びは build が position で直すので保たない。
    ///
    pub def byType(flat: List[FieldDef]): Map[TypeId, List[FieldDef]] =
        groupBy(field -> field#typeId, flat)

    ///
    /// key ごとにまとめる。1 挿入 O(1)（先頭に足す）なので、まとめた中の並びは入力の逆になる。
    ///
    def groupBy(key: FieldDef -> k, fields: List[FieldDef]): Map[k, List[FieldDef]] with Order[k] =
        List.foldLeft((acc, field) -> Map.insertWith((_, older) -> field :: older, key(field), field :: Nil, acc), Map.empty(), fields)

    def childrenOf(byParent: Map[Option[FieldId], List[FieldDef]], parent: Option[FieldId]): List[FieldDef] =
        Map.getWithDefault(parent, Nil, byParent)
            |> List.sortBy(field -> field#position)
            |> List.map(field -> { children = Children.Children(childrenOf(byParent, Some(field#id))) | field })

    ///
    /// 木の中から id で探す（深さ問わず）。
    ///
    pub def find(id: FieldId, tree: List[FieldDef]): Option[FieldDef] =
        tree |> List.findMap(field -> if (field#id == id) Some(field) else find(id, Children.toList(field#children)))

    ///
    /// 木の根から id までの祖先（根が先、自分は含まない）。無ければ None。
    ///
    pub def ancestors(id: FieldId, tree: List[FieldDef]): Option[List[FieldDef]] =
        tree |> List.findMap(field ->
            if (field#id == id) Some(Nil)
            else ancestors(id, Children.toList(field#children)) |> Option.map(rest -> field :: rest))

    ///
    /// 木を平らにする（深さ優先）。
    ///
    pub def flatten(tree: List[FieldDef]): List[FieldDef] =
        tree |> List.flatMap(field -> field :: flatten(Children.toList(field#children)))

}
