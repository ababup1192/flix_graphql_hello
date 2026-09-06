///
/// FieldTree.build: 平らな行を親子の木にする。
///
mod TestFieldTree {

    def flatField(id: Int64, api: String, parent: Option[Int64], kind: FieldKind, position: Int32): FieldDef =
        { id = FieldId.FieldId(id), parent = parent |> Option.map(FieldId.FieldId), position = position | CmsTestKit.fieldDef(api, kind) }

    /// 最上位は position 順、子は親の children に position 順で入り、孫も辿れる。findInTree は深さ問わず、flatten は深さ優先。
    ///
    ///   title(0)  sections(1: blocks) ─┬─ hero(0: object) ── headline(0)
    ///                                  └─ list(1: object) ── items(0)
    @Test
    def testFieldTree(): Unit \ Assert =
        let flat = List#{
            flatField(2i64, "sections", None, FieldKind.Blocks, 1),
            flatField(5i64, "items", Some(4i64), FieldKind.Text, 0),
            flatField(1i64, "title", None, FieldKind.Text, 0),
            flatField(4i64, "list", Some(2i64), FieldKind.Object, 1),
            flatField(3i64, "hero", Some(2i64), FieldKind.Object, 0),
            flatField(6i64, "headline", Some(3i64), FieldKind.Text, 0)
        };
        let tree = FieldTree.build(flat);
        let names = fields -> fields |> List.map(field -> ApiId.text(field#apiId));
        Assert.assertEq(expected = (List#{"title", "sections"}, List#{"hero", "list"}, Some(List#{"headline"}), List#{"title", "sections", "hero", "headline", "list", "items"}),
            (names(tree),
             tree |> List.find(field -> ApiId.text(field#apiId) == "sections") |> Option.map(field -> names(Children.toList(field#children))) |> Option.getWithDefault(Nil),
             FieldTree.find(FieldId.FieldId(3i64), tree) |> Option.map(field -> names(Children.toList(field#children))),
             names(FieldTree.flatten(tree))))

    /// ancestors は根から親まで（自分は含まない）。最上位は空、無い id は None。
    ///
    ///   sections(2: blocks) ── hero(3: object) ── headline(6)
    @Test
    def testFieldTreeAncestors(): Unit \ Assert =
        let tree = FieldTree.build(List#{
            flatField(2i64, "sections", None, FieldKind.Blocks, 0),
            flatField(3i64, "hero", Some(2i64), FieldKind.Object, 0),
            flatField(6i64, "headline", Some(3i64), FieldKind.Text, 0)
        });
        let names = fields -> fields |> List.map(field -> ApiId.text(field#apiId));
        Assert.assertEq(expected = (Some(List#{"sections", "hero"}), Some(Nil), None),
            (FieldTree.ancestors(FieldId.FieldId(6i64), tree) |> Option.map(names),
             FieldTree.ancestors(FieldId.FieldId(2i64), tree) |> Option.map(names),
             FieldTree.ancestors(FieldId.FieldId(99i64), tree) |> Option.map(names)))
}
