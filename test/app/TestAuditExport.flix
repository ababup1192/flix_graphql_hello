///
/// AuditExport: 監査の書き出しの純粋な部分。CSV / JSON Lines の 1 行の形、BOM、ファイル名、URL、クエリ引数の読み取り、
/// 管理 API の断りの写し、cursor で全件を集める道（Graphql は偽の execute）。
///
mod TestAuditExport {

    /// 管理 API の auditEvents が返す 1 件の形。
    def event(id: String, detail: Value): Value =
        Value.Obj(Map#{
            "id" => Value.Str(id), "createdAt" => Value.Str("2026-09-11T05:12:08Z"), "actorKind" => Value.Str("USER"),
            "actorId" => Value.Str("deb0f58dd032"), "actor" => Value.Str("dev@localhost"), "action" => Value.Str("member.invited"),
            "targetKind" => Value.Str("member"), "targetId" => Value.Str("second2@example.com"), "detail" => detail })

    def roleDetail(): Value = Value.Obj(Map#{ "role" => Value.Str("writer") })

    /// CSV の 1 行。セルは全部 `"` で囲み、detail は JSON の compact 文字列（中の `"` は `""`）、末尾は `\r\n`。
    @Test
    def testCsvLine(): Unit \ Assert =
        Assert.assertEq(
            expected = "\"01M27E2P\",\"2026-09-11T05:12:08Z\",\"USER\",\"deb0f58dd032\",\"dev@localhost\",\"member.invited\",\"member\",\"second2@example.com\",\"{\"\"role\"\":\"\"writer\"\"}\",\"https://cms.example.com/p/default/settings/audit?id=01M27E2P\"\r\n",
            AuditExport.csvLine(event("01M27E2P", roleDetail()), "https://cms.example.com/p/default/settings/audit?id=01M27E2P"))

    /// セルの中の `"`・改行・`,` はそのまま囲みの中に入る（`"` だけ `""` に）。
    @Test
    def testCsvCellTable(): Unit \ Assert =
        let table = List#{
            ("plain",           "\"plain\""),
            ("",                "\"\""),
            ("say \"hi\"",      "\"say \"\"hi\"\"\""),
            ("a,b",             "\"a,b\""),
            ("line1\nline2",    "\"line1\nline2\""),
            ("crlf\r\nend",     "\"crlf\r\nend\"")
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(AuditExport.csvCell))

    /// JSON Lines の 1 行。AuditEvent のフィールド + url で、detail は入れ子のまま。末尾は `\n`。
    @Test
    def testJsonLine(): Unit \ Assert =
        let line = AuditExport.jsonLine(event("01M27E2P", roleDetail()), "/p/default/settings/audit?id=01M27E2P");
        let parsed = JsonValue.parse(String.trim(line)) |> Result.getWithDefault(Value.Null);
        Assert.assertEq(
            expected = (true, Value.Str("/p/default/settings/audit?id=01M27E2P"), Value.Str("writer"), Value.Str("01M27E2P")),
            (String.endsWith(suffix = "\n", line), Value.field("url", parsed), Value.path(List#{"detail", "role"}, parsed), Value.field("id", parsed)))

    /// CSV の本文は BOM（U+FEFF）→ 見出し → 行の順で、行は `\r\n` で終わる（見出し + 2 行 → 区切ると末尾の空を入れて 4 つ）。JSON Lines には BOM も見出しも無い。
    @Test
    def testRenderTable(): Unit \ Assert =
        let events = event("01A", roleDetail()) :: event("01B", Value.Obj(Map.empty())) :: Nil;
        let csv = AuditExport.render(AuditExportFormat.Csv, Some("cms.example.com"), "docs", events);
        let jsonl = AuditExport.render(AuditExportFormat.Json, None, "docs", events);
        Assert.assertEq(
            expected = (true, "id,createdAt,actorKind,actorId,actor,action,targetKind,targetId,detail,url\r\n", 4, false, 2),
            (String.startsWith(prefix = "﻿", csv),
             String.dropLeft(1, csv) |> String.takeLeft(String.length(AuditExport.csvHeader())),
             String.splitOn(substr = "\r\n", csv) |> List.length,
             String.startsWith(prefix = "﻿", jsonl),
             String.lines(jsonl) |> List.length))

    /// 見出しは AuditEvent の並び + url。
    @Test
    def testCsvHeader(): Unit \ Assert =
        Assert.assertEq(expected = "id,createdAt,actorKind,actorId,actor,action,targetKind,targetId,detail,url\r\n", AuditExport.csvHeader())

    /// URL は Host があれば https の絶対 URL、無ければ相対。
    @Test
    def testUrlOfTable(): Unit \ Assert =
        let table = List#{
            ((Some("cms.example.com"), "docs", "01A"), "https://cms.example.com/p/docs/settings/audit?id=01A"),
            ((None, "docs", "01A"),                    "/p/docs/settings/audit?id=01A")
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(match (host, slug, id) -> AuditExport.urlOf(host, slug, id)))

    /// ファイル名。since / until は YYYY-MM-DD に切る。両方無ければ all-<今日>、片方なら無い側を all / 今日で埋める。拡張子は csv / jsonl。
    @Test
    def testFileNameTable(): Unit \ Assert =
        let filter = (since, until) -> { actorKind = None, action = None, since = since, until = until };
        // 2026-09-11T00:00:00Z
        let today = 1789084800000i64;
        let table = List#{
            ((AuditExportFormat.Csv,  filter(Some("2026-09-01T00:00:00Z"), Some("2026-09-10T15:00:00Z"))), "audit-docs-2026-09-01_2026-09-10.csv"),
            ((AuditExportFormat.Json, filter(Some("2026-09-01T00:00:00Z"), Some("2026-09-10T15:00:00Z"))), "audit-docs-2026-09-01_2026-09-10.jsonl"),
            ((AuditExportFormat.Csv,  filter(None, None)),                                                 "audit-docs-all-2026-09-11.csv"),
            ((AuditExportFormat.Csv,  filter(Some("2026-09-01T00:00:00Z"), None)),                         "audit-docs-2026-09-01_2026-09-11.csv"),
            ((AuditExportFormat.Csv,  filter(None, Some("2026-09-10T00:00:00Z"))),                         "audit-docs-all_2026-09-10.csv")
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(fst) |> List.map(match (format, found) -> AuditExport.fileName("docs", format, found, today)))

    /// Content-Type と Content-Disposition。
    @Test
    def testHeaders(): Unit \ Assert =
        Assert.assertEq(
            expected = ("text/csv; charset=utf-8", "application/x-ndjson", "attachment; filename=\"audit-docs-all-2026-09-11.csv\""),
            (AuditExport.contentType(AuditExportFormat.Csv), AuditExport.contentType(AuditExportFormat.Json), AuditExport.contentDisposition("audit-docs-all-2026-09-11.csv")))

    /// クエリ引数。空は無い物と同じ、actorKind は SDL の綴りだけ通る。
    @Test
    def testFilterOfTable(): Unit \ Assert =
        let table = List#{
            (Map#{},                                                        Ok({ actorKind = None, action = None, since = None, until = None })),
            (Map#{ "actorKind" => "USER", "action" => "member.", "since" => "2026-09-01T00:00:00Z", "until" => "" },
                                                                             Ok({ actorKind = Some("USER"), action = Some("member."), since = Some("2026-09-01T00:00:00Z"), until = None })),
            (Map#{ "actorKind" => "" },                                      Ok({ actorKind = None, action = None, since = None, until = None })),
            (Map#{ "actorKind" => "user" },                                  Err("actorKind 'user' は USER / API_KEY / PAT / SYSTEM のどれかにしてください"))
        };
        Assert.assertEq(
            expected = table |> List.map(snd) |> List.map(Result.map(found -> (found#actorKind, found#action, found#since, found#until))),
            table |> List.map(fst) |> List.map(AuditExport.filterOf) |> List.map(Result.map(found -> (found#actorKind, found#action, found#since, found#until))))

    /// 無い引数は variables にキーごと無い。
    @Test
    def testFilterVariables(): Unit \ Assert =
        Assert.assertEq(
            expected = Map#{ "actorKind" => Value.Str("USER"), "since" => Value.Str("2026-09-01T00:00:00Z") },
            AuditExport.filterVariables({ actorKind = Some("USER"), action = None, since = Some("2026-09-01T00:00:00Z"), until = None }))

    /// 管理 API のエラーの写し。extensions.code からステータスを決め、無ければ INTERNAL の 500。
    @Test
    def testFailureOfTable(): Unit \ Assert =
        let error = (code, message) -> Value.Obj(Map#{ "message" => Value.Str(message), "extensions" => Value.Obj(Map#{ "code" => Value.Str(code) }) });
        let table = List#{
            (error("FORBIDDEN", "権限がありません"),                            (403, "FORBIDDEN", "権限がありません")),
            (error("INVALID", "'x' は ISO 8601 の時刻ではありません"),          (400, "INVALID", "'x' は ISO 8601 の時刻ではありません")),
            (error("UNAUTHENTICATED", "ログインしてください"),                   (401, "UNAUTHENTICATED", "ログインしてください")),
            (Value.Obj(Map#{ "message" => Value.Str("Validation error") }),  (500, "INTERNAL", "Validation error"))
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(fst) |> List.map(AuditExport.failureOf) |> List.map(found -> (found#status, found#code, found#message)))

    /// 断りの本文は {"error": {"code", "message"}}。
    @Test
    def testFailureBody(): Unit \ Assert =
        Assert.assertEq(
            expected = "{\"error\":{\"code\":\"TOO_MANY\",\"message\":\"100,000 件を超えています。期間を分けてください\"}}",
            AuditExport.failureBody(AuditExport.tooMany()))

    // ---- 集める道（偽の execute）----

    /// 全部で total 件ある管理 API の偽物。auditEventsCount は total、auditEvents は after より小さい id から first 件（id は "e<番号>" で番号の降順）。
    def fakeApi(total: Int32, calls: Ref[List[String], r], request: GraphqlRequest): GraphqlResponse \ r =
        Ref.put(request#queryText :: Ref.get(calls), calls);
        if (String.contains(substr = "auditEventsCount", request#queryText))
            { data = Value.Obj(Map#{ "auditEventsCount" => Value.Int(total) }), errors = Nil }
        else if (String.contains(substr = "recordAuditExport", request#queryText))
            { data = Value.Obj(Map#{ "recordAuditExport" => Value.Bool(true) }), errors = Nil }
        else {
            let first = Map.get("first", request#variables) |> Option.flatMap(Value.asInt) |> Option.getWithDefault(0);
            let start = Map.get("after", request#variables) |> Option.flatMap(Value.asStr) |> Option.flatMap(id -> String.dropLeft(1, id) |> Int32.parse(10) |> Result.toOption) |> Option.map(n -> n - 1) |> Option.getWithDefault(total);
            let ids = List.range(Int32.max(0, start - first) + 1, start + 1) |> List.reverse;
            { data = Value.Obj(Map#{ "auditEvents" => Value.List(ids |> List.map(n -> event("e${n}", roleDetail()))) }), errors = Nil }
        }

    /// 件数がページ（200）の倍数でなくても、満杯でないページで止まり、全件が新しい順に揃う。呼んだのは count 1 回 + ページ 3 回。
    @Test
    def testCollectPagesUntilShort(): Unit \ Assert =
        region rc {
            let calls = Ref.fresh(rc, Nil);
            let collected = AuditExport.collect(fakeApi(450, calls), { actorKind = None, action = None, since = None, until = None });
            let ids = collected |> Result.map(List.map(found -> Value.field("id", found) |> Value.asStr |> Option.getWithDefault(""))) |> Result.mapErr(found -> found#code);
            Assert.assertEq(
                expected = (Ok(450), Ok(Some("e450")), Ok(Some("e1")), 4),
                (ids |> Result.map(List.length), ids |> Result.map(List.head), ids |> Result.map(List.last), Ref.get(calls) |> List.length))
        }

    /// 0 件なら count 1 回 + 空のページ 1 回で終わる。
    @Test
    def testCollectEmpty(): Unit \ Assert =
        region rc {
            let calls = Ref.fresh(rc, Nil);
            let collected = AuditExport.collect(fakeApi(0, calls), { actorKind = None, action = None, since = None, until = None });
            Assert.assertEq(expected = (Ok(0), 2), (collected |> Result.map(List.length) |> Result.mapErr(found -> found#code), Ref.get(calls) |> List.length))
        }

    /// 上限（100,000 件）を超えていれば、ページを 1 つも読まずに 413 の TOO_MANY。
    @Test
    def testCollectTooMany(): Unit \ Assert =
        region rc {
            let calls = Ref.fresh(rc, Nil);
            let collected = AuditExport.collect(fakeApi(100001, calls), { actorKind = None, action = None, since = None, until = None });
            Assert.assertEq(
                expected = (Err((413, "TOO_MANY")), 1),
                (collected |> Result.map(_ -> ()) |> Result.mapErr(found -> (found#status, found#code)), Ref.get(calls) |> List.length))
        }

    /// 管理 API が断れば（forbidden）その code とステータスで止まる。
    @Test
    def testCollectForbidden(): Unit \ Assert =
        let refusing = _ -> { data = Value.Null, errors = Value.Obj(Map#{ "message" => Value.Str("権限がありません"), "extensions" => Value.Obj(Map#{ "code" => Value.Str("FORBIDDEN") }) }) :: Nil };
        Assert.assertEq(
            expected = Err((403, "FORBIDDEN")),
            AuditExport.collect(refusing, { actorKind = None, action = None, since = None, until = None }) |> Result.map(_ -> ()) |> Result.mapErr(found -> (found#status, found#code)))

    /// 書き出した事の記録は recordAuditExport に format（SDL の綴り）・絞り込み・件数を input で渡す。
    @Test
    def testRecordRequest(): Unit \ Assert =
        let request = AuditExport.recordRequest(AuditExportFormat.Csv, { actorKind = Some("USER"), action = None, since = None, until = None }, 12);
        Assert.assertEq(
            expected = (true, Map#{ "input" => Value.Obj(Map#{ "format" => Value.Str("CSV"), "actorKind" => Value.Str("USER"), "count" => Value.Int(12) }) }),
            (String.startsWith(prefix = "mutation AuditExportRecord", request#queryText), request#variables))

}
