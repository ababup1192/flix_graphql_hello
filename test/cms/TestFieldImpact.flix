///
/// FieldImpact: スキーマの変更と数え上げの結果から、既存のデータに何が起きるかを出す。純粋。
///
/// 数えるのは SQL の仕事で、ここは「何件なら何が起きるか」だけを決める。
/// 0 件なら何も起きない（押しても安全）ので、影響が空かどうかがそのまま確認の要否になる。
///
mod TestFieldImpact {

    // ---- 部品 ----

    def field(id: Int64, api: String, kind: FieldKind): FieldDef =
        { id = FieldId.FieldId(id) | CmsTestKit.fieldDef(api, kind) }

    /// n 件当たった。見本は e1, e2, ... を n 件まで（sampleSize を超えない）。
    def hit(n: Int64): Hit =
        let shown = Int64.clampToInt32(min = 0, max = FieldImpact.sampleSize(), n);
        { total = n, entries = List.range(1, shown + 1) |> List.map(i -> CmsTestKit.entryId("e${i}")) }

    /// 数え上げの結果。触れていない数は 0。
    def counted(api: String, pairs: List[(String, Int64)]): FieldCount =
        let pick = key -> List.findMap(match (name, value) -> if (name == key) Some(value) else None, pairs) |> Option.getWithDefault(0i64) |> hit;
        { typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId(api),
          draft = pick("draft"), published = pick("published"),
          missingPublished = pick("missing"), outsideConfig = pick("outside"), duplicatePublished = pick("duplicate") }

    def label(effect: SchemaEffect): String =
        "${effect#kind}:${effect#apiId |> Option.map(ApiId.text) |> Option.getWithDefault("-")}(${effect#draft}/${effect#published})"

    def labels(changes: List[SchemaChange], fields: List[FieldCount], types: List[TypeCount]): List[String] =
        FieldImpact.of(changes, fields, types) |> List.map(label)

    // ---- 表 ----

    ///
    /// フィールドを消す。値を持つ entry があれば配信から消える。
    /// 参照を作る種類（REFERENCE / RICH_TEXT）なら参照も消え、ASSET なら asset の参照も消える。
    ///
    @Test
    def testFieldImpactRemoved(): Unit \ Assert =
        let counts = List#{counted("body", List#{("draft", 3i64), ("published", 2i64)})};
        let table = List#{
            (FieldKind.Text,      List#{"ValuesHidden:body(3/2)"}),
            (FieldKind.Reference, List#{"ValuesHidden:body(3/2)", "ReferencesHidden:body(3/2)"}),
            (FieldKind.RichText,  List#{"ValuesHidden:body(3/2)", "ReferencesHidden:body(3/2)"}),
            (FieldKind.Asset,     List#{"ValuesHidden:body(3/2)", "AssetsHidden:body(3/2)"})
        };
        Assert.assertEq(expected = table |> List.map(match (_, want) -> want),
            table |> List.map(match (kind, _) ->
                labels(List#{SchemaChange.FieldRemoved(field(11i64, "body", kind))}, counts, Nil)))

    /// 値を持つ entry が 1 件も無ければ、消しても何も起きない。
    @Test
    def testFieldImpactRemovedWithoutValues(): Unit \ Assert =
        Assert.assertEq(expected = Nil,
            labels(List#{SchemaChange.FieldRemoved(field(11i64, "body", FieldKind.Reference))},
                   List#{counted("body", Nil)}, Nil))

    ///
    /// フィールドを足す。その apiId に値が残っていれば、消したはずの値が配信に戻る。
    /// 数え上げが無い apiId（初めて使う名前）は何も起きない。
    ///
    @Test
    def testFieldImpactAdded(): Unit \ Assert =
        let table = List#{
            (List#{counted("memo", List#{("draft", 4i64), ("published", 1i64)})}, List#{"ValuesResurrected:memo(4/1)"}),
            (List#{counted("memo", Nil)},                                         Nil),
            (Nil,                                                                 Nil)
        };
        Assert.assertEq(expected = table |> List.map(match (_, want) -> want),
            table |> List.map(match (counts, _) ->
                labels(List#{SchemaChange.FieldAdded(field(12i64, "memo", FieldKind.Text))}, counts, Nil)))

    ///
    /// 性質を締める。required は「公開中だが値が無い」数、unique は「公開中で値が重なっている」数で決まる。
    /// どちらも公開中の entry が再公開できなくなる。
    ///
    @Test
    def testFieldImpactTightenedFlags(): Unit \ Assert =
        let title = field(10i64, "title", FieldKind.Text);
        let table = List#{
            (SchemaChange.FieldRequired(title), List#{counted("title", List#{("missing", 4i64)})},   List#{"PublishBlocked:title(0/4)"}),
            (SchemaChange.FieldRequired(title), List#{counted("title", Nil)},                        Nil),
            (SchemaChange.FieldUnique(title),   List#{counted("title", List#{("duplicate", 2i64)})}, List#{"PublishBlocked:title(0/2)"}),
            (SchemaChange.FieldUnique(title),   List#{counted("title", Nil)},                        Nil)
        };
        Assert.assertEq(expected = table |> List.map(match (_, _, want) -> want),
            table |> List.map(match (change, counts, _) -> labels(List#{change}, counts, Nil)))

    ///
    /// config を締める。新しい config に収まらない値があると、公開どころか下書きの保存が通らなくなる。
    ///
    @Test
    def testFieldImpactNarrowedConfig(): Unit \ Assert =
        let category = field(12i64, "category", FieldKind.Select);
        let change = SchemaChange.FieldConfigNarrowed(category, FieldConfig.empty());
        let table = List#{
            (List#{counted("category", List#{("outside", 7i64)})}, List#{"DraftBlocked:category(7/0)"}),
            (List#{counted("category", Nil)},                      Nil)
        };
        Assert.assertEq(expected = table |> List.map(match (_, want) -> want),
            table |> List.map(match (counts, _) -> labels(List#{change}, counts, Nil)))

    ///
    /// 型を消す。entry が残っていれば消せない（ContentTypes.delete が止める）ので、
    /// 件数をそのまま出す。0 件なら何も起きない。
    ///
    @Test
    def testFieldImpactTypeRemoved(): Unit \ Assert =
        let blogs = CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", Nil);
        let table = List#{
            (List#{{ typeId = TypeId.TypeId(1i64), entries = hit(5i64) }}, List#{"EntriesRemoved:-(0/5)"}),
            (List#{{ typeId = TypeId.TypeId(1i64), entries = hit(0i64) }}, Nil),
            (Nil,                                                     Nil)
        };
        Assert.assertEq(expected = table |> List.map(match (_, want) -> want),
            table |> List.map(match (types, _) -> labels(List#{SchemaChange.TypeRemoved(blogs)}, Nil, types)))

    ///
    /// 何も起こさない変更。並べ替えと型の追加は既存のデータに触らない。
    ///
    /// この 2 つが空で返る事に意味がある。影響が空かどうかで確認の要否を決めるので、
    /// ここで空にならないと並べ替えのたびに確認が出る。
    ///
    @Test
    def testFieldImpactHarmlessChanges(): Unit \ Assert =
        let blogs = CmsTestKit.contentType(1i64, "blogs", TypeKind.Collection, "記事", Nil);
        Assert.assertEq(expected = Nil,
            labels(List#{SchemaChange.FieldsReordered(TypeId.TypeId(1i64)), SchemaChange.TypeAdded(blogs)},
                   List#{counted("title", List#{("draft", 9i64), ("published", 9i64)})},
                   List#{{ typeId = TypeId.TypeId(1i64), entries = hit(9i64) }}))

    ///
    /// 複数の変更をまとめて渡した時は、変更の順に出る。
    ///
    @Test
    def testFieldImpactManyChanges(): Unit \ Assert =
        let title = field(10i64, "title", FieldKind.Text);
        let body  = field(11i64, "body", FieldKind.Reference);
        Assert.assertEq(expected = List#{"ValuesHidden:body(1/1)", "ReferencesHidden:body(1/1)", "PublishBlocked:title(0/3)"},
            labels(List#{SchemaChange.FieldRemoved(body), SchemaChange.FieldRequired(title)},
                   List#{counted("body", List#{("draft", 1i64), ("published", 1i64)}),
                         counted("title", List#{("missing", 3i64)})},
                   Nil))


    // ---- 見本 ----

    ///
    /// 影響には当たった entry の見本が付く。件数は正確なまま、見本だけ sampleSize に絞る。
    /// 消す時は下書きと公開中の見本を合わせ、同じ entry は 1 つ、公開中を先に並べる。
    ///
    @Test
    def testFieldImpactCarriesSample(): Unit \ Assert =
        let ids = names -> names |> List.map(CmsTestKit.entryId);
        let count = { typeId = TypeId.TypeId(1i64), apiId = CmsTestKit.apiId("body"),
                      draft = { total = 40i64, entries = ids(List#{"d1", "d2", "p1"}) },
                      published = { total = 30i64, entries = ids(List#{"p1", "p2", "p3"}) },
                      missingPublished = FieldImpact.none(), outsideConfig = FieldImpact.none(), duplicatePublished = FieldImpact.none() };
        let effects = FieldImpact.of(List#{SchemaChange.FieldRemoved(field(10i64, "body", FieldKind.Text))}, List#{count}, Nil);
        Assert.assertEq(
            expected = List#{(40i64, 30i64, List#{"p1", "p2", "p3", "d1", "d2"})},
            effects |> List.map(effect -> (effect#draft, effect#published, effect#entries |> List.map(EntryId.text))))

}
