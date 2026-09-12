///
/// Cursor: 一覧の位置の往復（文字列 ↔ Cursor）、entry からの値の取り出し、壊れた文字列と orderBy の不一致、after と skip の同時指定。純粋。
///
/// blogs 型のフィールド。title(text) / views(number) / flag(boolean) / publishOn(date)
///
mod TestCursor {

    use Util.Json.Json

    def fields(): List[FieldDef] =
        CmsTestKit.fieldDef("title", FieldKind.Text) ::
        CmsTestKit.fieldDef("views", FieldKind.Number) ::
        CmsTestKit.fieldDef("flag", FieldKind.Boolean) ::
        CmsTestKit.fieldDef("publishOn", FieldKind.Date) :: Nil

    def updatedAt(): Timestamp.Timestamp = Timestamp.at("2026-09-08T12:34:56.789Z")

    def createdAt(): Timestamp.Timestamp = Timestamp.at("2026-09-01T00:00:00Z")

    /// 未公開の entry。title "Flix" / views 10 / flag true / publishOn 2026-09-08。
    def entry(): Entry =
        { id = CmsTestKit.entryId("e7"), typeId = TypeId.TypeId(1i64), version = 1, stage = Stage.Draft,
          data = CmsTestKit.entryData(List#{("title", Json.JString("Flix")), ("views", CmsTestKit.intJson(10)), ("flag", Json.JBool(true)), ("publishOn", Json.JString("2026-09-08T00:00:00Z"))}),
          publishedAt = None, changedSincePublish = false, contentStage = Stage.Draft, linked = Linked.empty(), createdAt = createdAt(), updatedAt = updatedAt() }

    def key(name: String): SortKey = SortKey.ByField(CmsTestKit.apiId(name))

    def micros(at: Timestamp.Timestamp): CursorValue = CursorValue.Micros(Timestamp.toEpochMicros(at))

    // ---- entry からの値 ----

    /// 並び順のキーごとの値。組み込みは entry の列、フィールドは kind で（型に無い apiId は文字列、無いキーは Null）。未公開の publishedAt は Null。
    @Test
    def testCursorValues(): Unit \ Assert =
        let cases = List#{
            (SortKey.ById,          CursorValue.Text("e7")),
            (SortKey.ByUpdatedAt,   micros(updatedAt())),
            (SortKey.ByCreatedAt,   micros(createdAt())),
            (SortKey.ByPublishedAt, CursorValue.Null),
            (key("title"),          CursorValue.Text("Flix")),
            (key("views"),          CursorValue.Number(10.0)),
            (key("flag"),           CursorValue.Bool(true)),
            (key("publishOn"),      micros(Timestamp.at("2026-09-08T00:00:00Z"))),
            (key("unknown"),        CursorValue.Null)
        };
        Assert.assertEq(
            expected = cases |> List.map(match (sortKey, value) -> (sortKey, Cursor.Cursor((sortKey, Direction.Desc, value) :: Nil, "e7"))),
            cases |> List.map(match (sortKey, _) -> (sortKey, Cursor.ofEntry(fields(), (sortKey, Direction.Desc) :: Nil, entry()))))

    /// orderBy が空なら更新が新しい順の 1 キー。
    @Test
    def testCursorDefaultOrder(): Unit \ Assert =
        Assert.assertEq(
            expected = Cursor.Cursor((SortKey.ByUpdatedAt, Direction.Desc, micros(updatedAt())) :: Nil, "e7"),
            Cursor.ofEntry(fields(), Nil, entry()))

    // ---- 往復 ----

    /// DATE / NUMBER / TEXT / BOOLEAN / updatedAt / publishedAt(Null) の各キー × ASC / DESC と、2 キーの並びが、encode → decode で元に戻る。
    @Test
    def testCursorRoundTrip(): Unit \ Assert =
        let orders = List#{
            (key("publishOn"), Direction.Asc) :: Nil,
            (key("publishOn"), Direction.Desc) :: Nil,
            (key("views"), Direction.Asc) :: Nil,
            (key("views"), Direction.Desc) :: Nil,
            (key("title"), Direction.Asc) :: Nil,
            (key("title"), Direction.Desc) :: Nil,
            (key("flag"), Direction.Desc) :: Nil,
            (SortKey.ByUpdatedAt, Direction.Asc) :: Nil,
            (SortKey.ByUpdatedAt, Direction.Desc) :: Nil,
            (SortKey.ByPublishedAt, Direction.Desc) :: Nil,
            (key("views"), Direction.Desc) :: (key("title"), Direction.Asc) :: Nil,
            Nil
        };
        Assert.assertEq(
            expected = orders |> List.map(orderBy -> Ok(Cursor.ofEntry(fields(), orderBy, entry()))),
            orders |> List.map(orderBy -> Cursor.decode(orderBy, Cursor.encode(Cursor.ofEntry(fields(), orderBy, entry())))))

    /// asset の位置も往復する（作成が新しい順で固定）。
    @Test
    def testCursorAssetRoundTrip(): Unit \ Assert =
        let asset = { id = AssetId.AssetId("a1"), key = "1/a1/x.png", fileName = "x.png", mime = "image/png", size = 5i64, width = None, height = None, alt = "", status = AssetStatus.Ready, createdAt = createdAt() };
        Assert.assertEq(
            expected = Ok(Cursor.Cursor((SortKey.ByCreatedAt, Direction.Desc, micros(createdAt())) :: Nil, "a1")),
            Cursor.decode(Cursor.assetOrderBy(), Cursor.encode(Cursor.ofAsset(asset))))

    /// 文字列は base64url（パディング無し、URL に使える文字だけ）。
    @Test
    def testCursorEncodedIsBase64Url(): Unit \ Assert =
        Assert.assertTrue(String.isMatch(regex = "^[A-Za-z0-9_-]+$", Cursor.encode(Cursor.ofEntry(fields(), Nil, entry()))))

    // ---- 壊れた物と不一致 ----

    def broken(): Violation = Violation.Violation("after", "cursor が壊れています")

    def mismatch(): Violation = Violation.Violation("after", "cursor が orderBy と合いません（並び順を変えたら先頭から読み直してください）")

    def encoded(text: String): String = Base64Url.encode(String.toBytes(text))

    /// base64url でない・JSON でない・形が違う・キーや向きが読めない・値が 2 つある物は「壊れています」。
    @Test
    def testCursorDecodeBroken(): Unit \ Assert =
        let cases = List#{
            "not base64!",
            encoded("xyz"),
            encoded("{}"),
            encoded("[]"),
            encoded("{\"k\":[],\"id\":1}"),
            encoded("{\"k\":[{\"key\":\"updatedAt\",\"dir\":\"UP\"}],\"id\":\"a\"}"),
            encoded("{\"k\":[{\"key\":\"bad id!\",\"dir\":\"DESC\"}],\"id\":\"a\"}"),
            encoded("{\"k\":[{\"key\":\"updatedAt\",\"dir\":\"DESC\",\"t\":1,\"s\":\"x\"}],\"id\":\"a\"}"),
            encoded("{\"k\":[{\"key\":\"updatedAt\",\"dir\":\"DESC\",\"t\":\"x\"}],\"id\":\"a\"}")
        };
        Assert.assertEq(
            expected = cases |> List.map(text -> (text, Err(broken()))),
            cases |> List.map(text -> (text, Cursor.decode(Nil, text))))

    /// 並び順を変えて古い cursor を渡すと不一致（キーが違う、向きが違う、キーの数が違う）。空の orderBy と updatedAt_DESC は同じ物。
    @Test
    def testCursorDecodeMismatch(): Unit \ Assert =
        let viewsDesc = Cursor.encode(Cursor.ofEntry(fields(), (key("views"), Direction.Desc) :: Nil, entry()));
        let updatedDesc = Cursor.encode(Cursor.ofEntry(fields(), Nil, entry()));
        let cases = List#{
            ((key("title"), Direction.Asc) :: Nil, viewsDesc, Err(mismatch())),
            ((key("views"), Direction.Asc) :: Nil, viewsDesc, Err(mismatch())),
            ((key("views"), Direction.Desc) :: (key("title"), Direction.Asc) :: Nil, viewsDesc, Err(mismatch())),
            (Nil, viewsDesc, Err(mismatch())),
            ((SortKey.ByUpdatedAt, Direction.Desc) :: Nil, updatedDesc, Ok(Cursor.ofEntry(fields(), Nil, entry()))),
            (Nil, updatedDesc, Ok(Cursor.ofEntry(fields(), Nil, entry())))
        };
        Assert.assertEq(
            expected = cases |> List.map(match (orderBy, _, outcome) -> (orderBy, outcome)),
            cases |> List.map(match (orderBy, text, _) -> (orderBy, Cursor.decode(orderBy, text))))

    // ---- ページの始まり ----

    /// after が無ければ skip（0 は先頭）、after があれば cursor の次。after と skip（0 以外）を同時に渡すと invalid、壊れた after も invalid。
    @Test
    def testCursorPageStart(): Unit \ Assert =
        let cursor = Cursor.ofEntry(fields(), Nil, entry());
        let text = Cursor.encode(cursor);
        let cases = List#{
            ((0, None),               Ok(PageStart.Offset(0))),
            ((5, None),               Ok(PageStart.Offset(5))),
            ((Cursor.maxSkip(), None), Ok(PageStart.Offset(Cursor.maxSkip()))),
            ((0, Some(text)),         Ok(PageStart.After(cursor))),
            ((3, Some(text)),         Err(Violation.Violation("after", "after と skip は同時に指定できません（どちらか 1 つ）"))),
            ((0, Some("broken")),     Err(broken())),
            ((3, Some("broken")),     Err(Violation.Violation("after", "after と skip は同時に指定できません（どちらか 1 つ）")))
        };
        Assert.assertEq(
            expected = cases |> List.map(match (given, outcome) -> (given, outcome)),
            cases |> List.map(match (given, _) -> { let (skip, after) = given; (given, Cursor.pageStart(Nil, skip, after)) }))

    /// 上限を 1 でも超えた skip は invalid で、cursor（after）へ誘導する。after を渡していれば skip は 0 なので上限に当たらない。
    @Test
    def testCursorPageStartTooDeep(): Unit \ Assert =
        let tooDeep = Violation.Violation("skip", "skip は ${Cursor.maxSkip()} まで指定できます（これより後ろは after に前のページの endCursor を指定してください）");
        let cases = List#{
            (Cursor.maxSkip() + 1, Err(tooDeep)),
            (Cursor.maxSkip() * 10, Err(tooDeep))
        };
        Assert.assertEq(
            expected = cases,
            cases |> List.map(match (skip, _) -> (skip, Cursor.pageStart(Nil, skip, None))))

    // ---- 名前 ----

    /// 並び順のキーと向きの名前は往復する。組み込みの名前はフィールドより先に決まり、規則外は None。
    @Test
    def testSortKeyNames(): Unit \ Assert =
        let keys = SortKey.ById :: SortKey.ByPublishedAt :: SortKey.ByUpdatedAt :: SortKey.ByCreatedAt :: key("title") :: Nil;
        Assert.assertEq(
            expected = (keys |> List.map(Some), List#{"id", "publishedAt", "updatedAt", "createdAt", "title"}, None, Some(Direction.Asc), None),
            (keys |> List.map(sortKey -> SortKey.fromText(SortKey.toText(sortKey))), keys |> List.map(SortKey.toText), SortKey.fromText("Bad Name"), Direction.fromText(Direction.toText(Direction.Asc)), Direction.fromText("up")))

}
