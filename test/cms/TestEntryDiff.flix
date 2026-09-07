///
/// EntryDiff: entry の 2 つのバージョンの中身の差分と、行差分（LCS）。全部純粋。
///
/// 見本の記事（articleFields）: 全 kind を 1 つずつ持つ。
///   title(text) / summary(textArea) / slug / views(number) / published(boolean) / category(select A|B) / author(reference)
///   / cover(asset) / date / tags(text, many) / hero(object{headline, cta(object{label})}) / sections(blocks, many; heroBlock{headline} | quote{text})
///   / body(richText)
///
mod TestEntryDiff {

    use Util.Json.Json

    // ---- 部品 ----

    def positioned(position: Int32, field: FieldDef): FieldDef = { position = position | field }

    def withChildren(children: List[FieldDef], field: FieldDef): FieldDef = { children = Children.Children(children) | field }

    def obj(pairs: List[(String, Json)]): Json = Json.JObject(List.toMap(pairs))

    def block(variant: String, pairs: List[(String, Json)]): Json = obj(("blockType", Json.JString(variant)) :: pairs)

    def strings(texts: List[String]): Json = Json.JArray(texts |> List.map(Json.JString) |> List.toVector)

    def paragraph(text: String): Json = CmsTestKit.richNode("paragraph", Nil, CmsTestKit.richText(Nil, text) :: Nil)

    def heading(text: String): Json = CmsTestKit.richNode("heading", ("level", CmsTestKit.intJson(1)) :: Nil, CmsTestKit.richText(Nil, text) :: Nil)

    def doc(blocks: List[Json]): Json = CmsTestKit.richNode("doc", Nil, blocks)

    def at(path: String, change: Change): FieldChange = FieldChange.FieldChange(path, change)

    def hero(): FieldDef =
        CmsTestKit.fieldDef("hero", FieldKind.Object)
            |> withChildren(positioned(0, CmsTestKit.fieldDef("headline", FieldKind.Text)) ::
                            positioned(1, CmsTestKit.fieldDef("cta", FieldKind.Object) |> withChildren(CmsTestKit.fieldDef("label", FieldKind.Text) :: Nil)) :: Nil)

    def sections(): FieldDef =
        { many = true | CmsTestKit.fieldDef("sections", FieldKind.Blocks) }
            |> withChildren(CmsTestKit.fieldDef("heroBlock", FieldKind.Object) |> withChildren(CmsTestKit.fieldDef("headline", FieldKind.Text) :: Nil) ::
                            CmsTestKit.fieldDef("quote", FieldKind.Object) |> withChildren(CmsTestKit.fieldDef("text", FieldKind.Text) :: Nil) :: Nil)

    def articleFields(): List[FieldDef] =
        positioned(0, CmsTestKit.fieldDef("title", FieldKind.Text)) ::
        positioned(1, CmsTestKit.fieldDef("summary", FieldKind.TextArea)) ::
        positioned(2, CmsTestKit.fieldDef("slug", FieldKind.Slug)) ::
        positioned(3, CmsTestKit.fieldDef("views", FieldKind.Number)) ::
        positioned(4, CmsTestKit.fieldDef("published", FieldKind.Boolean)) ::
        positioned(5, { config = { options = List#{"A", "B"} | FieldConfig.empty() } | CmsTestKit.fieldDef("category", FieldKind.Select) }) ::
        positioned(6, { target = Some(TypeId.TypeId(2i64)) | CmsTestKit.fieldDef("author", FieldKind.Reference) }) ::
        positioned(7, CmsTestKit.fieldDef("cover", FieldKind.Asset)) ::
        positioned(8, CmsTestKit.fieldDef("date", FieldKind.Date)) ::
        positioned(9, { many = true | CmsTestKit.fieldDef("tags", FieldKind.Text) }) ::
        positioned(10, hero()) ::
        positioned(11, sections()) ::
        positioned(12, CmsTestKit.fieldDef("body", FieldKind.RichText)) :: Nil

    def article(): EntryData =
        CmsTestKit.entryData(List#{
            ("title", Json.JString("Hello")),
            ("summary", Json.JString("first\nsecond")),
            ("slug", Json.JString("hello")),
            ("views", CmsTestKit.intJson(3)),
            ("published", Json.JBool(true)),
            ("category", Json.JString("A")),
            ("author", Json.JString("author1")),
            ("cover", Json.JString("asset1")),
            ("date", Json.JString("2026-09-08T00:00:00Z")),
            ("tags", strings(List#{"a", "b"})),
            ("hero", obj(List#{("headline", Json.JString("H")), ("cta", obj(List#{("label", Json.JString("Go"))}))})),
            ("sections", Json.JArray(Vector#{block("heroBlock", List#{("headline", Json.JString("H"))}), block("quote", List#{("text", Json.JString("Q"))})})),
            ("body", doc(List#{heading("Title"), paragraph("first"), paragraph("second")}))})

    // ---- diff ----

    /// 同じ中身なら差分は無い（見本の記事。全 kind を含む）。
    @Test
    def testEntryDiffSameIsEmpty(): Unit \ Assert =
        Assert.assertEq(expected = Nil, EntryDiff.diff(articleFields(), article(), article()))

    /// kind ごとに、after にだけあれば Added、before にだけあれば Removed、値が違えば Changed（RICH_TEXT は行差分の Text）。
    /// OBJECT はオブジェクトでない値に変わった時、BLOCKS は variant が変わった時が Changed（中だけ違う時は Nested。別のテスト）。
    ///
    ///   表: (フィールド, before の値, after の値, 値が違う時の期待)
    @Test
    def testEntryDiffKindTable(): Unit \ Assert =
        let simple = kind -> CmsTestKit.fieldDef("x", kind);
        let heroObject = obj(List#{("headline", Json.JString("H"))});
        let rows = List#{
            (simple(FieldKind.Text), Json.JString("a"), Json.JString("b"), Change.Changed(Json.JString("a"), Json.JString("b"))),
            (simple(FieldKind.TextArea), Json.JString("a\nb"), Json.JString("a\nc"), Change.Changed(Json.JString("a\nb"), Json.JString("a\nc"))),
            (simple(FieldKind.Slug), Json.JString("a"), Json.JString("b"), Change.Changed(Json.JString("a"), Json.JString("b"))),
            (simple(FieldKind.Number), CmsTestKit.intJson(1), CmsTestKit.intJson(2), Change.Changed(CmsTestKit.intJson(1), CmsTestKit.intJson(2))),
            (simple(FieldKind.Boolean), Json.JBool(true), Json.JBool(false), Change.Changed(Json.JBool(true), Json.JBool(false))),
            ({ config = { options = List#{"A", "B"} | FieldConfig.empty() } | simple(FieldKind.Select) }, Json.JString("A"), Json.JString("B"), Change.Changed(Json.JString("A"), Json.JString("B"))),
            (simple(FieldKind.Reference), Json.JString("e1"), Json.JString("e2"), Change.Changed(Json.JString("e1"), Json.JString("e2"))),
            (simple(FieldKind.Asset), Json.JString("a1"), Json.JString("a2"), Change.Changed(Json.JString("a1"), Json.JString("a2"))),
            (simple(FieldKind.Date), Json.JString("2026-09-08T00:00:00Z"), Json.JString("2026-09-09T00:00:00Z"), Change.Changed(Json.JString("2026-09-08T00:00:00Z"), Json.JString("2026-09-09T00:00:00Z"))),
            ({ apiId = CmsTestKit.apiId("x") | hero() }, heroObject, Json.JString("broken"), Change.Changed(heroObject, Json.JString("broken"))),
            ({ apiId = CmsTestKit.apiId("x"), many = false | sections() }, block("heroBlock", List#{("headline", Json.JString("H"))}), block("quote", List#{("text", Json.JString("H"))}),
                Change.Changed(block("heroBlock", List#{("headline", Json.JString("H"))}), block("quote", List#{("text", Json.JString("H"))}))),
            (simple(FieldKind.RichText), doc(List#{paragraph("a")}), doc(List#{paragraph("b")}), Change.Text(List#{DiffLine.Del("a"), DiffLine.Add("b")}))
        };
        let only = value -> CmsTestKit.entryData(List#{("x", value)});
        Assert.assertEq(
            expected = rows |> List.map(match (_, before, after, changed) -> (at("x", Change.Added(after)) :: Nil, at("x", Change.Removed(before)) :: Nil, at("x", changed) :: Nil)),
            rows |> List.map(match (field, before, after, _) ->
                (EntryDiff.diff(field :: Nil, Map.empty(), only(after)), EntryDiff.diff(field :: Nil, only(before), Map.empty()), EntryDiff.diff(field :: Nil, only(before), only(after)))))

    /// 3 つのフィールドのうち 1 つだけ変えると、その 1 件だけ出る。
    @Test
    def testEntryDiffOnlyChangedField(): Unit \ Assert =
        let after = Map.insert(CmsTestKit.apiId("views"), CmsTestKit.intJson(4), article());
        Assert.assertEq(expected = at("views", Change.Changed(CmsTestKit.intJson(3), CmsTestKit.intJson(4))) :: Nil,
            EntryDiff.diff(articleFields(), article(), after))

    /// OBJECT の 2 段の入れ子の中の 1 つだけ変えると、Nested の中の Nested に 1 件。
    ///
    ///   hero { headline: H, cta { label: Go → Buy } }
    @Test
    def testEntryDiffNestedObject(): Unit \ Assert =
        let after = Map.insert(CmsTestKit.apiId("hero"), obj(List#{("headline", Json.JString("H")), ("cta", obj(List#{("label", Json.JString("Buy"))}))}), article());
        Assert.assertEq(
            expected = at("hero", Change.Nested(at("hero.cta", Change.Nested(at("hero.cta.label", Change.Changed(Json.JString("Go"), Json.JString("Buy"))) :: Nil)) :: Nil)) :: Nil,
            EntryDiff.diff(articleFields(), article(), after))

    /// many は位置で比べる。末尾に足せば Added が 1 件、先頭に足せばずれた分が全部 Changed、入れ替えれば 2 件の Changed。
    ///
    ///   表: (before の tags, after の tags, 期待)
    @Test
    def testEntryDiffManyByPosition(): Unit \ Assert =
        let tags = { many = true | CmsTestKit.fieldDef("tags", FieldKind.Text) } :: Nil;
        let rows = List#{
            (List#{"a", "b"}, List#{"a", "b", "c"}, at("tags", Change.Nested(at("tags[2]", Change.Added(Json.JString("c"))) :: Nil)) :: Nil),
            (List#{"a", "b"}, List#{"z", "a", "b"}, at("tags", Change.Nested(
                at("tags[0]", Change.Changed(Json.JString("a"), Json.JString("z"))) :: at("tags[1]", Change.Changed(Json.JString("b"), Json.JString("a"))) :: at("tags[2]", Change.Added(Json.JString("b"))) :: Nil)) :: Nil),
            (List#{"a", "b"}, List#{"b", "a"}, at("tags", Change.Nested(
                at("tags[0]", Change.Changed(Json.JString("a"), Json.JString("b"))) :: at("tags[1]", Change.Changed(Json.JString("b"), Json.JString("a"))) :: Nil)) :: Nil)
        };
        Assert.assertEq(
            expected = rows |> List.map(match (_, _, expected) -> expected),
            rows |> List.map(match (before, after, _) -> EntryDiff.diff(tags, CmsTestKit.entryData(List#{("tags", strings(before))}), CmsTestKit.entryData(List#{("tags", strings(after))}))))

    /// BLOCKS は同じ位置で variant が違えば Changed、同じなら中を再帰して Nested。
    ///
    ///   [heroBlock{H}, quote{Q}] → [quote{Q}, quote{Q}]   … 0 番目が Changed
    ///   [heroBlock{H}, quote{Q}] → [heroBlock{H2}, quote{Q}] … 0 番目の headline が Changed
    @Test
    def testEntryDiffBlocks(): Unit \ Assert =
        let heroBlock = block("heroBlock", List#{("headline", Json.JString("H"))});
        let quote = block("quote", List#{("text", Json.JString("Q"))});
        let sectionsOf = blocks -> Map.insert(CmsTestKit.apiId("sections"), Json.JArray(List.toVector(blocks)), article());
        Assert.assertEq(
            expected = (at("sections", Change.Nested(at("sections[0]", Change.Changed(heroBlock, quote)) :: Nil)) :: Nil,
                        at("sections", Change.Nested(at("sections[0]", Change.Nested(at("sections[0].headline", Change.Changed(Json.JString("H"), Json.JString("H2"))) :: Nil)) :: Nil)) :: Nil),
            (EntryDiff.diff(articleFields(), article(), sectionsOf(List#{quote, quote})),
             EntryDiff.diff(articleFields(), article(), sectionsOf(List#{block("heroBlock", List#{("headline", Json.JString("H2"))}), quote}))))

    /// RICH_TEXT は Markdown の行差分。1 行の変更は Del と Add の組、段落の追加は空行と本文の Add、見出しの削除は見出しと空行の Del。
    ///
    ///   body = "# Title" / "" / "first" / "" / "second"
    @Test
    def testEntryDiffRichTextLines(): Unit \ Assert =
        let bodyOf = blocks -> Map.insert(CmsTestKit.apiId("body"), doc(blocks), article());
        Assert.assertEq(
            expected = (at("body", Change.Text(List#{DiffLine.Same("# Title"), DiffLine.Same(""), DiffLine.Same("first"), DiffLine.Same(""), DiffLine.Del("second"), DiffLine.Add("2nd")})) :: Nil,
                        at("body", Change.Text(List#{DiffLine.Same("# Title"), DiffLine.Same(""), DiffLine.Same("first"), DiffLine.Same(""), DiffLine.Same("second"), DiffLine.Add(""), DiffLine.Add("third")})) :: Nil,
                        at("body", Change.Text(List#{DiffLine.Del("# Title"), DiffLine.Del(""), DiffLine.Same("first"), DiffLine.Same(""), DiffLine.Same("second")})) :: Nil),
            (EntryDiff.diff(articleFields(), article(), bodyOf(List#{heading("Title"), paragraph("first"), paragraph("2nd")})),
             EntryDiff.diff(articleFields(), article(), bodyOf(List#{heading("Title"), paragraph("first"), paragraph("second"), paragraph("third")})),
             EntryDiff.diff(articleFields(), article(), bodyOf(List#{paragraph("first"), paragraph("second")}))))

    /// 定義に無いキーも捨てない。before にだけあれば Removed、after にだけあれば Added。null はキーが無いのと同じ（両方無いなら差分無し）。
    /// 定義に無い物は定義の後に apiId 順。
    @Test
    def testEntryDiffUndefinedAndNull(): Unit \ Assert =
        let fields = CmsTestKit.fieldDef("title", FieldKind.Text) :: CmsTestKit.fieldDef("views", FieldKind.Number) :: Nil;
        let before = CmsTestKit.entryData(List#{("title", Json.JString("a")), ("views", Json.JNull), ("legacy", Json.JString("x"))});
        let after = CmsTestKit.entryData(List#{("title", Json.JNull), ("extra", CmsTestKit.intJson(1))});
        Assert.assertEq(
            expected = at("title", Change.Removed(Json.JString("a"))) :: at("extra", Change.Added(CmsTestKit.intJson(1))) :: at("legacy", Change.Removed(Json.JString("x"))) :: Nil,
            EntryDiff.diff(fields, before, after))

    /// 出力は定義の position 順。定義の並びや Map の順には依らない。
    @Test
    def testEntryDiffPositionOrder(): Unit \ Assert =
        let after = article() |> Map.insert(CmsTestKit.apiId("title"), Json.JString("Bye")) |> Map.insert(CmsTestKit.apiId("views"), CmsTestKit.intJson(9)) |> Map.insert(CmsTestKit.apiId("published"), Json.JBool(false));
        Assert.assertEq(
            expected = at("title", Change.Changed(Json.JString("Hello"), Json.JString("Bye"))) :: at("views", Change.Changed(CmsTestKit.intJson(3), CmsTestKit.intJson(9))) :: at("published", Change.Changed(Json.JBool(true), Json.JBool(false))) :: Nil,
            EntryDiff.diff(List.reverse(articleFields()), article(), after))

    // ---- diffLines ----

    /// 見本の記事の Markdown。
    def articleMarkdown(): String = "# Title\n\nfirst\n\nsecond"

    def editedMarkdown(): String = "# Title\n\nfirst changed\n\nsecond\n\nthird"

    def beforeSide(line: DiffLine): Option[String] = match line {
        case DiffLine.Same(text) => Some(text)
        case DiffLine.Del(text)  => Some(text)
        case DiffLine.Add(_)     => None
    }

    def afterSide(line: DiffLine): Option[String] = match line {
        case DiffLine.Same(text) => Some(text)
        case DiffLine.Add(text)  => Some(text)
        case DiffLine.Del(_)     => None
    }

    /// 法則: Del と Same を並べると before の行、Add と Same を並べると after の行。
    @Test
    def testDiffLinesLaws(): Unit \ Assert =
        let lines = EntryDiff.diffLines(articleMarkdown(), editedMarkdown());
        Assert.assertEq(
            expected = (String.splitOn(substr = "\n", articleMarkdown()), String.splitOn(substr = "\n", editedMarkdown())),
            (List.filterMap(beforeSide, lines), List.filterMap(afterSide, lines)))

    /// 境界: 両方空なら Nil、片方空なら全部 Add か Del、全行違えば Del の後に Add、共通の行が複数箇所あればそれぞれ Same で挟む。
    ///
    ///   表: (before, after, 期待)
    @Test
    def testDiffLinesEdges(): Unit \ Assert =
        let rows = List#{
            ("", "", Nil),
            ("", "a", List#{DiffLine.Add("a")}),
            ("a", "", List#{DiffLine.Del("a")}),
            ("a\nb", "c\nd", List#{DiffLine.Del("a"), DiffLine.Del("b"), DiffLine.Add("c"), DiffLine.Add("d")}),
            ("x\n1\ny\n2", "x\n3\ny\n4", List#{DiffLine.Same("x"), DiffLine.Del("1"), DiffLine.Add("3"), DiffLine.Same("y"), DiffLine.Del("2"), DiffLine.Add("4")})
        };
        Assert.assertEq(
            expected = rows |> List.map(match (_, _, expected) -> expected),
            rows |> List.map(match (before, after, _) -> EntryDiff.diffLines(before, after)))

}
