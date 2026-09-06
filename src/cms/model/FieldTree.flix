///
/// フィールドの木。平らな FieldDef の並び（parent で親を指す）と、children に子を抱えた木のあいだの操作。純粋。
///
mod FieldTree {

    ///
    /// 平らな並びを木にする。最上位（parent 無し）を position 順に並べ、子は再帰で付ける。
    ///
    pub def build(flat: List[FieldDef]): List[FieldDef] =
        let byParent = List.foldLeft((acc, field) -> Map.insertWith((newer, older) -> older ::: newer, field#parent, field :: Nil, acc), Map.empty(), flat);
        childrenOf(byParent, None)

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
    /// 木を平らにする（深さ優先）。
    ///
    pub def flatten(tree: List[FieldDef]): List[FieldDef] =
        tree |> List.flatMap(field -> field :: flatten(Children.toList(field#children)))

}
