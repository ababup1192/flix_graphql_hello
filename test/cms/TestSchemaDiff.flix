///
/// SchemaDiff: スキーマ全体の前後から変更の列を出す。純粋。
///
/// 出すのは「既存のデータに影響しうる変更」だけ。緩める側（required を外す、選択肢を足す、
/// 上限を伸ばす）と、見た目だけの変更（name、アイコン）は出さない。
///
mod TestSchemaDiff {

    // ---- 部品 ----

    /// id と position を付けたフィールド。diff は id で突き合わせる。
    def at(id: Int64, position: Int32, field: FieldDef): FieldDef =
        { id = FieldId.FieldId(id), position = position | field }

    def withChildren(children: List[FieldDef], field: FieldDef): FieldDef =
        { children = Children.Children(children) | field }

    def text(id: Int64, api: String): FieldDef = at(id, 0, CmsTestKit.fieldDef(api, FieldKind.Text))

    def blogs(fields: List[FieldDef]): ContentType =
        CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", fields)

    def tags(fields: List[FieldDef]): ContentType =
        CmsTestKit.contentType(2i64, "tags", TypeKind.Collection, "タグ", fields)

    /// 変更を短い文字にする。表の期待を読めるようにするため。
    def label(change: SchemaChange): String = match change {
        case SchemaChange.TypeAdded(owner)              => "type+${ApiId.text(owner#apiId)}"
        case SchemaChange.TypeRemoved(owner)            => "type-${ApiId.text(owner#apiId)}"
        case SchemaChange.FieldAdded(field)             => "+${ApiId.text(field#apiId)}"
        case SchemaChange.FieldRemoved(field)           => "-${ApiId.text(field#apiId)}"
        case SchemaChange.FieldRequired(field)          => "required:${ApiId.text(field#apiId)}"
        case SchemaChange.FieldUnique(field)            => "unique:${ApiId.text(field#apiId)}"
        case SchemaChange.FieldConfigNarrowed(field, _) => "config:${ApiId.text(field#apiId)}"
        case SchemaChange.FieldsReordered(_)            => "reordered"
    }

    def labels(before: List[ContentType], after: List[ContentType]): List[String] =
        SchemaDiff.diff(before, after) |> List.map(label)

    /// 選択肢を持つ SELECT（select は Flix の予約語なので withOptions）。
    def withOptions(id: Int64, api: String, options: List[String]): FieldDef =
        { config = { options = options | FieldConfig.empty() } | at(id, 0, CmsTestKit.fieldDef(api, FieldKind.Select)) }

    /// 上限を持つ TEXT。
    def capped(id: Int64, api: String, maxLength: Option[Int32]): FieldDef =
        { config = { maxLength = maxLength | FieldConfig.empty() } | text(id, api) }

    // ---- 表 ----

    /// 同じスキーマなら変更は無い。触っていない型も出ない。
    @Test
    def testSchemaDiffUnchanged(): Unit \ Assert =
        let types = List#{blogs(List#{text(10i64, "title"), text(11i64, "body")}), tags(List#{text(20i64, "label")})};
        Assert.assertEq(expected = Nil, labels(types, types))

    ///
    /// フィールドの増減と、性質を締めた／緩めた時。
    ///
    /// 締める側（required / unique を立てる）だけ出す。外すのは既存のデータを壊さない。
    /// name を変えても中身は変わらない。並びは配信に出る順が変わるので出す。
    /// 見るのは並びそのもので、position の数値ではない（FieldTree.build が position で並べ直すので、
    /// 読み込んだ後の並びには既に position が効いている）。
    ///
    @Test
    def testSchemaDiffFields(): Unit \ Assert =
        let title = text(10i64, "title");
        let body  = text(11i64, "body");
        let table = List#{
            (List#{title, body},  List#{title},                                            List#{"-body"}),
            (List#{title},        List#{title, body},                                      List#{"+body"}),
            (List#{title},        List#{{ required = true | title }},                      List#{"required:title"}),
            (List#{{ required = true | title }}, List#{title},                             Nil),
            (List#{title},        List#{{ unique = true | title }},                        List#{"unique:title"}),
            (List#{title},        List#{{ name = "見出し" | title }},                       Nil),
            (List#{title, body},  List#{body, title},                                  List#{"reordered"}),
            (List#{title, body},  List#{at(10i64, 5, title), at(11i64, 9, body)},        Nil)
        };
        Assert.assertEq(expected = table |> List.map(match (_, _, want) -> want),
            table |> List.map(match (before, after, _) -> labels(List#{blogs(before)}, List#{blogs(after)})))

    ///
    /// 入れ子（OBJECT / BLOCKS）。親を消すと子も消える（DB が FK の CASCADE で落とす）ので、
    /// 親と子の両方を出す。子だけを消した時は子だけ出す。
    ///
    @Test
    def testSchemaDiffNested(): Unit \ Assert =
        let headline = text(31i64, "headline");
        let caption  = text(32i64, "caption");
        let hero     = at(30i64, 0, CmsTestKit.fieldDef("hero", FieldKind.Object)) |> withChildren(List#{headline, caption});
        let heroThin = at(30i64, 0, CmsTestKit.fieldDef("hero", FieldKind.Object)) |> withChildren(List#{headline});
        let table = List#{
            (List#{hero},     Nil,               List#{"-hero", "-headline", "-caption"}),
            (List#{hero},     List#{heroThin},   List#{"-caption"}),
            (List#{heroThin}, List#{hero},       List#{"+caption"})
        };
        Assert.assertEq(expected = table |> List.map(match (_, _, want) -> want),
            table |> List.map(match (before, after, _) -> labels(List#{blogs(before)}, List#{blogs(after)})))

    ///
    /// 型ごと消した時はフィールドを 1 本ずつ出さない（型が消えれば全部消えるのは自明で、
    /// 数えたいのは「その型の entry が何件あるか」の方）。型を足した時も同じ。
    ///
    @Test
    def testSchemaDiffTypes(): Unit \ Assert =
        let blog = blogs(List#{text(10i64, "title")});
        let tag  = tags(List#{text(20i64, "label")});
        let table = List#{
            (List#{blog, tag}, List#{blog},      List#{"type-tags"}),
            (List#{blog},      List#{blog, tag}, List#{"type+tags"}),
            (Nil,              List#{blog},      List#{"type+blogs"})
        };
        Assert.assertEq(expected = table |> List.map(match (_, _, want) -> want),
            table |> List.map(match (before, after, _) -> labels(before, after)))

    ///
    /// config を締めた時だけ出す。選択肢を減らす・上限を縮める・下限を上げる・整数に限る、が締める側。
    /// 緩める側は既存の値がそのまま通るので出さない。
    ///
    @Test
    def testSchemaDiffConfigNarrowed(): Unit \ Assert =
        let ab  = withOptions(12i64, "category", List#{"A", "B"});
        let a   = withOptions(12i64, "category", List#{"A"});
        let abc = withOptions(12i64, "category", List#{"A", "B", "C"});
        let n120 = capped(10i64, "title", Some(120));
        let n80  = capped(10i64, "title", Some(80));
        let none = capped(10i64, "title", None);
        let table = List#{
            (ab,   a,     List#{"config:category"}),
            (ab,   abc,   Nil),
            (ab,   ab,    Nil),
            (n120, n80,   List#{"config:title"}),
            (n80,  n120,  Nil),
            (none, n120,  List#{"config:title"}),
            (n120, none,  Nil)
        };
        Assert.assertEq(expected = table |> List.map(match (_, _, want) -> want),
            table |> List.map(match (before, after, _) -> labels(List#{blogs(List#{before})}, List#{blogs(List#{after})})))

    ///
    /// 締めた変更は変更前の config を持って返す。何を外したかを数えるのに要る。
    ///
    @Test
    def testSchemaDiffNarrowedCarriesBefore(): Unit \ Assert =
        let before = blogs(List#{withOptions(12i64, "category", List#{"A", "B"})});
        let after  = blogs(List#{withOptions(12i64, "category", List#{"A"})});
        Assert.assertEq(expected = List#{List#{"A", "B"}},
            SchemaDiff.diff(List#{before}, List#{after})
                |> List.filterMap(change -> match change {
                    case SchemaChange.FieldConfigNarrowed(_, was) => Some(was#options)
                    case _                                        => None
                }))

}
