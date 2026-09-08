///
/// McpTools: ツール定義の表（tools/list の形と、引数の復号が同じ定義から出る事）、引数 → GraphQL リクエストの写し、
/// richText の format の写し、応答 → content の写しと 256 KB の切り詰め。全部 DB 無し。
///
mod TestMcpTools {

    /// GraphQL を呼ばずに固定の data を返す execute。
    def fixed(data: Value): GraphqlRequest -> GraphqlResponse =
        _ -> { data = data, errors = Nil }

    /// GraphQL を呼ばずに、extensions 付きのエラー 1 つを返す execute。
    def failing(extensions: Map[String, Value]): GraphqlRequest -> GraphqlResponse =
        _ -> { data = Value.Null, errors = Value.Obj(Map#{ "message" => Value.Str("だめ"), "extensions" => Value.Obj(extensions) }) :: Nil }

    /// 平文の段落 1 つの doc。
    def paragraphDoc(text: String): Value =
        Value.Obj(Map#{ "type" => Value.Str("doc"), "content" => Value.List(
            Value.Obj(Map#{ "type" => Value.Str("paragraph"), "content" => Value.List(
                Value.Obj(Map#{ "type" => Value.Str("text"), "text" => Value.Str(text) }) :: Nil) }) :: Nil) })

    /// FieldDef の応答（kind と children だけ）。
    def fieldDef(apiId: String, kind: String, many: Bool, children: List[Value]): Value =
        Value.Obj(Map#{ "apiId" => Value.Str(apiId), "kind" => Value.Str(kind), "many" => Value.Bool(many), "children" => Value.List(children) })

    /// posts 型（title: TEXT, body: RICH_TEXT, hero: OBJECT { caption: RICH_TEXT }, sections: BLOCKS { text { body: RICH_TEXT } }）のフィールド定義。
    def postsFields(): List[Value] =
        fieldDef("title", "TEXT", false, Nil) ::
        fieldDef("body", "RICH_TEXT", false, Nil) ::
        fieldDef("hero", "OBJECT", false, fieldDef("caption", "RICH_TEXT", false, Nil) :: Nil) ::
        fieldDef("sections", "BLOCKS", true, fieldDef("text", "OBJECT", false, fieldDef("body", "RICH_TEXT", false, Nil) :: Nil) :: Nil) :: Nil

    def obj(pairs: List[(String, Value)]): Value = Value.Obj(List.toMap(pairs))

    /// content[0].text。content が 1 件の配列でなければテストの前提が壊れている。
    def contentText(result: Value): Value = match Value.field("content", result) {
        case Value.List(first :: Nil) => Value.field("text", first)
        case other                    => bug!("content が 1 件ではありません: ${other}")
    }

    /// 型の問い合わせ（contentType(）には typeData を、それ以外には entries の応答を返す execute。
    /// 受けたリクエストは totalCount に写す（search_entries が totalCount をそのまま通すので、variables をそこから読める）。
    def typeThenEntries(typeData: Value, request: GraphqlRequest): GraphqlResponse =
        if (String.contains(substr = "contentType(", request#queryText)) { data = typeData, errors = Nil }
        else { data = obj(List#{ ("entries", obj(List#{ ("totalCount", GraphqlFake.echo(request)), ("nodes", Value.List(Nil)) })) }), errors = Nil }

    // ---- ツール定義の表（tripwire）----

    /// tools/list に出る名前と必須の引数の集合。ツールを足す・引数を変えるとここが落ちる（TestApiSurface と同じ狙い）。
    @Test
    def testToolSurface(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                "list_types:", "get_type: apiId", "search_entries: type", "get_entry: id", "diff_entry: from id to",
                "create_entry: fields type", "update_entry: expectedVersion fields id", "publish_check: id", "impact: action id",
                "publish: id", "unpublish: id", "delete_entry: id", "restore_version: expectedVersion id versionId", "preview_url: id", "whoami:" },
            McpTools.tools() |> List.map(definition ->
                "${Tool.name(definition#tool)}: ${definition#args |> List.filter(ArgDef.isRequired) |> List.map(ArgDef.name) |> List.sort |> List.join(" ")}" |> String.trim))

    /// tools/list の 1 件は name / description / inputSchema / annotations を持ち、inputSchema は定義から出る（properties の型と required）。
    @Test
    def testToolListEntryShape(): Unit \ Assert =
        let listed = McpTools.toolListValue() |> List.find(item -> Value.field("name", item) == Value.Str("publish")) |> Option.getWithDefault(Value.Null);
        Assert.assertEq(
            expected = List#{
                Value.Str("publish"),
                obj(List#{ ("type", Value.Str("object")), ("additionalProperties", Value.Bool(false)),
                    ("properties", obj(List#{
                        ("id", obj(List#{ ("type", Value.Str("string")), ("description", Value.Str("entry の id")) })),
                        ("withDependencies", obj(List#{ ("type", Value.Str("boolean")), ("description", Value.Str("未公開の参照先も一緒に公開する（既定 false）")) })) })),
                    ("required", Value.List(Value.Str("id") :: Nil)) }),
                obj(List#{ ("readOnlyHint", Value.Bool(false)), ("destructiveHint", Value.Bool(false)), ("idempotentHint", Value.Bool(true)) }),
                Value.Bool(true) },
            GraphqlTestKit.pick(List#{List#{"name"}, List#{"inputSchema"}, List#{"annotations"}}, listed)
                ::: (Value.field("description", listed) |> Value.asStr |> Option.map(String.contains(substr = "publish_check")) |> Option.getWithDefault(false) |> Value.Bool) :: Nil)

    /// enum とオブジェクトの引数の inputSchema: enum は string + enum、オブジェクトは入れ子の object。
    @Test
    def testInputSchemaEnumAndObject(): Unit \ Assert =
        let schema = McpTools.inputSchema(McpTools.definitionOf(Tool.DiffEntry)#args);
        Assert.assertEq(
            expected = List#{
                Value.List(Value.Str("DRAFT") :: Value.Str("PUBLISHED") :: Nil),
                Value.Str("string"),
                Value.Str("object") },
            GraphqlTestKit.pick(List#{
                List#{"properties", "from", "properties", "stage", "enum"},
                List#{"properties", "from", "properties", "versionId", "type"},
                List#{"properties", "to", "type"}}, schema))

    // ---- 引数の復号（表駆動）----

    /// 必須欠け・型違い・enum 外・入れ子のオブジェクトの中の誤りは Err、合っていれば Ok（省略した任意の引数は入らない）。
    @Test
    def testDecodeArgs(): Unit \ Assert =
        let cases = List#{
            (Tool.GetEntry, obj(List#{ ("id", Value.Str("e1")) }), Ok(Map#{ "id" => Value.Str("e1") })),
            (Tool.GetEntry, obj(List#{ ("id", Value.Str("e1")), ("format", Value.Str("html")) }), Ok(Map#{ "id" => Value.Str("e1"), "format" => Value.Str("html") })),
            (Tool.GetEntry, obj(Nil), Err("引数 'id' が要ります")),
            (Tool.GetEntry, Value.Null, Err("引数 'id' が要ります")),
            (Tool.GetEntry, obj(List#{ ("id", Value.Int(1)) }), Err("引数 'id' は 文字列で渡してください")),
            (Tool.GetEntry, obj(List#{ ("id", Value.Str("e1")), ("format", Value.Str("pdf")) }), Err("引数 'format' は markdown / text / html / doc のどれかで渡してください")),
            (Tool.UpdateEntry, obj(List#{ ("id", Value.Str("e1")), ("fields", Value.Str("x")), ("expectedVersion", Value.Int(1)) }), Err("引数 'fields' は オブジェクトで渡してください")),
            (Tool.UpdateEntry, obj(List#{ ("id", Value.Str("e1")), ("fields", obj(Nil)), ("expectedVersion", Value.Str("1")) }), Err("引数 'expectedVersion' は 整数で渡してください")),
            (Tool.Publish, obj(List#{ ("id", Value.Str("e1")), ("withDependencies", Value.Str("yes")) }), Err("引数 'withDependencies' は 真偽値で渡してください")),
            (Tool.DiffEntry, obj(List#{ ("id", Value.Str("e1")), ("from", obj(List#{ ("stage", Value.Str("LIVE")) })), ("to", obj(Nil)) }), Err("引数 'stage' は DRAFT / PUBLISHED のどれかで渡してください")),
            (Tool.DiffEntry, obj(List#{ ("id", Value.Str("e1")), ("from", Value.Str("DRAFT")), ("to", obj(Nil)) }), Err("引数 'from' は オブジェクトで渡してください")),
            (Tool.ListTypes, Value.List(Nil), Err("arguments はオブジェクトで渡してください")),
            (Tool.ListTypes, Value.Null, Ok(Map.empty())) };
        Assert.assertEq(
            expected = cases |> List.map(match (_, _, expectedResult) -> expectedResult),
            cases |> List.map(match (tool, given, _) -> McpTools.decodeArgs(McpTools.definitionOf(tool)#args, given)))

    /// ツール名 → Tool と、Tool → 名前の往復。知らない名前は None。
    @Test
    def testToolNameRoundTrip(): Unit \ Assert =
        Assert.assertEq(
            expected = (Tool.all() |> List.map(Some), None),
            (Tool.all() |> List.map(tool -> Tool.parse(Tool.name(tool))), Tool.parse("delete_everything")))

    // ---- 引数 → GraphQL リクエスト ----

    /// search_entries は先に型を apiId で引き、次に entries を typeId と first / skip / search で引く。first は 100 に丸め、既定 20、skip は既定 0。
    @Test
    def testSearchEntriesRequests(): Unit \ Assert =
        let typeData = obj(List#{ ("contentType", obj(List#{ ("id", Value.Str("t1")), ("fields", Value.List(Nil)) })) });
        let seen = McpTools.call(Tool.SearchEntries, Map#{ "type" => Value.Str("posts"), "first" => Value.Int(500) }, typeThenEntries(typeData));
        Assert.assertEq(
            expected = Ok(List#{ Value.Str("t1"), Value.Int(100), Value.Int(0), Value.Null }),
            seen |> Result.map(GraphqlTestKit.pick(List#{ List#{"totalCount", "variables", "typeId"}, List#{"totalCount", "variables", "first"}, List#{"totalCount", "variables", "skip"}, List#{"totalCount", "variables", "search"} })))

    /// 書く 3 つの mutation の variables: create_entry は typeId と fields、update_entry は id と fields と expectedVersion、publish は id と withDependencies。
    @Test
    def testMutationVariables(): Unit \ Assert =
        let variablesOf = (request: GraphqlRequest) -> request#variables;
        Assert.assertEq(
            expected = List#{
                Map#{ "typeId" => Value.Str("t1"), "fields" => obj(List#{ ("title", Value.Str("a")) }) },
                Map#{ "id" => Value.Str("e1"), "fields" => obj(Nil), "expectedVersion" => Value.Int(3) },
                Map#{ "id" => Value.Str("e1"), "withDependencies" => Value.Bool(true) },
                Map#{ "id" => Value.Str("e1"), "action" => Value.Str("UNPUBLISH") } },
            List#{
                McpTools.createEntryRequest("t1", obj(List#{ ("title", Value.Str("a")) })),
                McpTools.updateEntryRequest("e1", obj(Nil), 3),
                McpTools.publishRequest("e1", true),
                McpTools.impactRequest("e1", "UNPUBLISH") } |> List.map(variablesOf))

    /// get_entry は versions をバージョンの一覧（中身の fields を落とした物）として返す。中身は entry の fields だけ。
    @Test
    def testGetEntryVersionsWithoutFields(): Unit \ Assert =
        let version = obj(List#{ ("id", Value.Str("v1")), ("version", Value.Int(2)), ("reason", Value.Str("PUBLISH")), ("author", Value.Str("a")), ("createdAt", Value.Str("t")), ("fields", obj(List#{ ("title", Value.Str("old")) })) });
        let entry = obj(List#{ ("id", Value.Str("e1")), ("typeId", Value.Str("t1")), ("stage", Value.Str("CHANGED")), ("fields", obj(List#{ ("title", Value.Str("new")) })), ("versions", Value.List(version :: Nil)) });
        let data = obj(List#{ ("entry", entry), ("contentTypes", Value.List(Nil)) });
        Assert.assertEq(
            expected = Ok(List#{
                Value.List(obj(List#{ ("id", Value.Str("v1")), ("version", Value.Int(2)), ("reason", Value.Str("PUBLISH")), ("author", Value.Str("a")), ("createdAt", Value.Str("t")) }) :: Nil),
                obj(List#{ ("title", Value.Str("new")) }),
                obj(List#{ ("title", Value.Str("old")) }) }),
            Result.flatMap(draft -> McpTools.call(Tool.GetEntry, Map#{ "id" => Value.Str("e1"), "stage" => Value.Str("PUBLISHED") }, fixed(data)) |> Result.map(published ->
                List#{ Value.field("versions", draft), Value.field("fields", draft), Value.field("fields", published) }),
                McpTools.call(Tool.GetEntry, Map#{ "id" => Value.Str("e1") }, fixed(data))))

    /// preview_url は url が null なら howToUse（X-Preview-Token の使い方）を足し、url があれば足さない。
    @Test
    def testPreviewUrlHowToUse(): Unit \ Assert =
        let issued = url -> obj(List#{ ("createPreviewToken", obj(List#{ ("token", Value.Str("pv_x")), ("url", url) })) });
        Assert.assertEq(
            expected = (Ok(Value.Str(McpTools.previewHowToUse())), Ok(Value.Null)),
            (McpTools.call(Tool.PreviewUrl, Map#{ "id" => Value.Str("e1") }, fixed(issued(Value.Null))) |> Result.map(Value.field("howToUse")),
             McpTools.call(Tool.PreviewUrl, Map#{ "id" => Value.Str("e1") }, fixed(issued(Value.Str("https://site/p?preview=pv_x")))) |> Result.map(Value.field("howToUse"))))

    /// delete_entry / restore_version / whoami の variables と応答の形。delete_entry は { id, deleted: true }、whoami は data.viewer。
    @Test
    def testDeleteRestoreWhoami(): Unit \ Assert =
        let viewer = obj(List#{ ("kind", Value.Str("API_KEY")), ("permissions", Value.List(Value.Str("readDraft") :: Nil)) });
        Assert.assertEq(
            expected = (
                Ok(obj(List#{ ("id", Value.Str("e1")), ("deleted", Value.Bool(true)) })),
                Map#{ "id" => Value.Str("e1"), "versionId" => Value.Str("7"), "expectedVersion" => Value.Int(3) },
                Ok(viewer)),
            (McpTools.call(Tool.DeleteEntry, Map#{ "id" => Value.Str("e1") }, fixed(obj(List#{ ("deleteEntry", Value.Str("e1")) }))),
             McpTools.restoreVersionRequest("e1", "7", 3)#variables,
             McpTools.call(Tool.Whoami, Map.empty(), fixed(obj(List#{ ("viewer", viewer) })))))

    /// diff_entry は from / to の VersionRef をそのまま variables に渡し、応答の entry.diff を返す。entry が無ければ NOT_FOUND。
    @Test
    def testDiffEntry(): Unit \ Assert =
        let fromRef = obj(List#{ ("stage", Value.Str("PUBLISHED")) });
        let toRef = obj(List#{ ("versionId", Value.Str("v1")) });
        let args = Map#{ "id" => Value.Str("e1"), "from" => fromRef, "to" => toRef };
        let changes = Value.List(obj(List#{ ("path", Value.Str("title")), ("kind", Value.Str("CHANGED")) }) :: Nil);
        Assert.assertEq(
            expected = (
                Ok(changes),
                Err(McpTools.Failure.Business(obj(List#{ ("code", Value.Str("NOT_FOUND")), ("message", Value.Str("entry 'e1' が見つかりません")), ("entity", Value.Str("Entry")), ("id", Value.Str("e1")) }))),
                Map#{ "id" => Value.Str("e1"), "from" => fromRef, "to" => toRef }),
            (McpTools.call(Tool.DiffEntry, args, fixed(obj(List#{ ("entry", obj(List#{ ("diff", changes) })) }))),
             McpTools.call(Tool.DiffEntry, args, fixed(obj(List#{ ("entry", Value.Null) }))),
             McpTools.diffRequest("e1", fromRef, toRef)#variables))

    // ---- richText の format の写し ----

    /// 読む向き: RICH_TEXT の doc だけを format で写す（TEXT はそのまま）。OBJECT の中と BLOCKS の variant の中も辿る。
    @Test
    def testReadFormats(): Unit \ Assert =
        let fields = obj(List#{
            ("title", Value.Str("題")),
            ("body", paragraphDoc("本文")),
            ("hero", obj(List#{ ("caption", paragraphDoc("説明")) })),
            ("sections", Value.List(obj(List#{ ("blockType", Value.Str("text")), ("body", paragraphDoc("節")) }) :: Nil)) });
        let cases = List#{
            (McpTools.Format.Markdown, obj(List#{ ("title", Value.Str("題")), ("body", Value.Str("本文")), ("hero", obj(List#{ ("caption", Value.Str("説明")) })),
                ("sections", Value.List(obj(List#{ ("blockType", Value.Str("text")), ("body", Value.Str("節")) }) :: Nil)) })),
            (McpTools.Format.Text, obj(List#{ ("title", Value.Str("題")), ("body", Value.Str("本文")), ("hero", obj(List#{ ("caption", Value.Str("説明")) })),
                ("sections", Value.List(obj(List#{ ("blockType", Value.Str("text")), ("body", Value.Str("節")) }) :: Nil)) })),
            (McpTools.Format.Html, obj(List#{ ("title", Value.Str("題")), ("body", Value.Str("<p>本文</p>")), ("hero", obj(List#{ ("caption", Value.Str("<p>説明</p>")) })),
                ("sections", Value.List(obj(List#{ ("blockType", Value.Str("text")), ("body", Value.Str("<p>節</p>")) }) :: Nil)) })),
            (McpTools.Format.Doc, fields) };
        Assert.assertEq(
            expected = cases |> List.map(snd),
            cases |> List.map(match (format, _) -> McpTools.mapRichText(postsFields(), McpTools.readConverter(format), fields)))

    /// 書く向き: RICH_TEXT の値が文字列なら Markdown として doc にし、doc のままなら触らない。TEXT の文字列は触らない。
    @Test
    def testWriteConverter(): Unit \ Assert =
        let given = obj(List#{ ("title", Value.Str("題")), ("body", Value.Str("本文")), ("hero", obj(List#{ ("caption", paragraphDoc("説明")) })) });
        CmsTestKit.assertSameValue(
            obj(List#{ ("title", Value.Str("題")), ("body", paragraphDoc("本文")), ("hero", obj(List#{ ("caption", paragraphDoc("説明")) })) }),
            McpTools.mapRichText(postsFields(), McpTools.toDocValue, given))

    // ---- 応答 → content ----

    /// 成功は content[0].text に data の JSON、isError は false。業務エラーは extensions（code など）と message を text にし、isError は true。
    @Test
    def testCallResult(): Unit \ Assert =
        let ok = McpTools.callResult(Ok(obj(List#{ ("id", Value.Str("e1")) })));
        let failed = McpTools.callResult(Err(McpTools.Failure.Business(obj(List#{ ("code", Value.Str("CONFLICT")), ("actualVersion", Value.Int(5)) }))));
        Assert.assertEq(
            expected = List#{
                Value.Str("{\"id\":\"e1\"}"), Value.Bool(false), Value.Null,
                Value.Str("{\"actualVersion\":5,\"code\":\"CONFLICT\"}"), Value.Bool(true) },
            List#{ contentText(ok), Value.field("isError", ok), Value.field("structuredContent", ok), contentText(failed), Value.field("isError", failed) })

    /// GraphQL の errors は先頭の extensions を写す。UNAUTHENTICATED だけは別扱い（HTTP 401 にするため）。extensions が無いエラーは INTERNAL。
    @Test
    def testFailureOfErrors(): Unit \ Assert =
        let plain = _ -> { data = Value.Null, errors = Value.Obj(Map#{ "message" => Value.Str("Validation error") }) :: Nil };
        Assert.assertEq(
            expected = (
                Err(McpTools.Failure.Business(obj(List#{ ("code", Value.Str("FORBIDDEN")), ("message", Value.Str("だめ")) }))),
                Err(McpTools.Failure.Unauthenticated("だめ")),
                Err(McpTools.Failure.Business(obj(List#{ ("code", Value.Str("INTERNAL")), ("message", Value.Str("Validation error")) })))),
            (McpTools.call(Tool.ListTypes, Map.empty(), failing(Map#{ "code" => Value.Str("FORBIDDEN") })),
             McpTools.call(Tool.ListTypes, Map.empty(), failing(Map#{ "code" => Value.Str("UNAUTHENTICATED") })),
             McpTools.call(Tool.ListTypes, Map.empty(), plain)))

    /// graphql-java が extensions に足す classification は isError の中身に出さない（code など他の extensions は残る）。code が無ければ INTERNAL。
    @Test
    def testFailureDropsClassification(): Unit \ Assert =
        Assert.assertEq(
            expected = (
                Err(McpTools.Failure.Business(obj(List#{ ("code", Value.Str("NOT_FOUND")), ("entity", Value.Str("Entry")), ("message", Value.Str("だめ")) }))),
                Err(McpTools.Failure.Business(obj(List#{ ("code", Value.Str("INTERNAL")), ("message", Value.Str("だめ")) })))),
            (McpTools.call(Tool.ListTypes, Map.empty(), failing(Map#{ "code" => Value.Str("NOT_FOUND"), "entity" => Value.Str("Entry"), "classification" => Value.Str("DataFetchingException") })),
             McpTools.call(Tool.ListTypes, Map.empty(), failing(Map#{ "classification" => Value.Str("ValidationError") }))))

    /// 256 KB を超える text は本文だけ切って truncated を structuredContent に出す。切っても JSON は壊れない（parse できる）。収まる text は触らない。
    @Test
    def testTruncate(): Unit \ Assert =
        let long = String.repeat(McpTools.maxTextBytes() / 4 + 1, "日本語!");
        let result = McpTools.callResult(Ok(Value.List(Value.Str(long) :: Nil)));
        let text = contentText(result) |> Value.asStr |> Option.getWithDefault("");
        Assert.assertEq(
            expected = (true, Value.Obj(Map#{ "truncated" => Value.Bool(true) }), true, ("abc", false)),
            (Http.utf8Length(text) <= McpTools.maxTextBytes(),
             Value.field("structuredContent", result),
             JsonValue.parse(JsonValue.toJsonString(result)) |> Result.isOk,
             McpTools.truncate("abc")))

}
