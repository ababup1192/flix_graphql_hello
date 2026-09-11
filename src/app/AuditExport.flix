///
/// 監査の書き出し（GET /admin/audit.csv / audit.jsonl）。管理 API のエンジンへの GraphQL クライアントとして動き、
/// `auditEventsCount` で上限を見て、`auditEvents` を cursor で回して全件を集め、最後に `recordAuditExport` で「持ち出した」事を積む。
/// 行の形・ファイル名・URL・引数の読み取りは純粋。HTTP と Graphql effect に触るのは Server.auditExportRoute。
///
/// WhyNot: ユースケース（Audit.recent）を直に呼ばないのは、権限・絞り込みの検査・Tx の単位を管理 API と二重に持たないため（MCP と同じ形）。
///
mod AuditExport {

    ///
    /// クエリ引数（auditEvents と同じ意味・同じ書式）。値は GraphQL の variables にそのまま渡し、検査は管理 API が行う。
    ///
    /// - actorKind: USER / API_KEY / PAT / SYSTEM
    /// - action: 前方一致
    /// - since / until: ISO 8601
    ///
    pub type alias Filter = { actorKind = Option[String], action = Option[String], since = Option[String], until = Option[String] }

    ///
    /// 断る理由。HTTP のステータスと、本文 {"error": {"code", "message"}} に出す code / message。
    ///
    pub type alias Failure = { status = Int32, code = String, message = String }

    /// 1 ページに読む件数。auditEvents の first の上限（EntryPage.clamp が 200 に丸める）に合わせる。
    pub def pageSize(): Int32 = 200

    /// 1 回の書き出しの上限。超えたら 413 で期間を分けてもらう。
    pub def maxRows(): Int32 = 100000

    /// 上限を超えた時の断り。
    pub def tooMany(): Failure =
        { status = 413, code = "TOO_MANY", message = "100,000 件を超えています。期間を分けてください" }

    // ---- 引数 ----

    ///
    /// クエリ文字列から絞り込みを読む。空の値は無い物と同じ。actorKind が SDL の enum に無い綴りなら Err（文言）。
    ///
    /// WhyNot: 綴りの検査を管理 API に任せないのは、enum の綴り違いは graphql-java の検証で落ち、extensions.code が付かないため。
    ///
    pub def filterOf(params: Map[String, String]): Result[String, Filter] =
        let given = name -> Map.get(name, params) |> Option.filter(text -> not String.isEmpty(text));
        match given("actorKind") {
            case Some(kind) if not List.memberOf(kind, actorKinds()) => Err("actorKind '${kind}' は ${List.join(" / ", actorKinds())} のどれかにしてください")
            case actorKind => Ok({ actorKind = actorKind, action = given("action"), since = given("since"), until = given("until") })
        }

    /// 管理 API の ActorKind の綴り。
    def actorKinds(): List[String] = List#{"USER", "API_KEY", "PAT", "SYSTEM"}

    /// 絞り込みを variables に。無い引数はキーごと無い（GraphQL では null と同じ）。
    pub def filterVariables(filter: Filter): Map[String, Value] =
        List#{ ("actorKind", filter#actorKind), ("action", filter#action), ("since", filter#since), ("until", filter#until) }
            |> List.filterMap(match (key, value) -> value |> Option.map(text -> (key, Value.Str(text))))
            |> List.toMap

    // ---- 管理 API へのリクエスト ----

    /// 絞り込みの引数の宣言と、auditEvents / auditEventsCount への渡し方。
    def filterDeclaration(): String = "$actorKind: ActorKind, $action: String, $since: String, $until: String"
    def filterArguments(): String = "actorKind: $actorKind, action: $action, since: $since, until: $until"

    /// 件数。
    pub def countRequest(filter: Filter): GraphqlRequest =
        { queryText = "query AuditExportCount(${filterDeclaration()}) { auditEventsCount(${filterArguments()}) }",
          variables = filterVariables(filter), operationName = None }

    /// 1 ページ（新しい順）。after は前のページの最後の id。
    pub def pageRequest(filter: Filter, after: Option[String]): GraphqlRequest =
        { queryText = "query AuditExportPage($first: Int!, $after: ID, ${filterDeclaration()}) { auditEvents(first: $first, after: $after, ${filterArguments()}) { ${selection()} } }",
          variables = filterVariables(filter)
              |> Map.insert("first", Value.Int(pageSize()))
              |> Map.insert("after", after |> Option.map(Value.Str) |> Option.getWithDefault(Value.Null)),
          operationName = None }

    /// AuditEvent の全フィールド（SDL の並び）。CSV の列の順もこれ。
    pub def selection(): String = "id createdAt actorKind actorId actor action targetKind targetId detail"

    /// 書き出した事を積む。
    pub def recordRequest(format: AuditExportFormat, filter: Filter, count: Int32): GraphqlRequest =
        let input = filterVariables(filter)
            |> Map.insert("format", Value.Str(formatName(format)))
            |> Map.insert("count", Value.Int(count));
        { queryText = "mutation AuditExportRecord($input: AuditExportInput!) { recordAuditExport(input: $input) }",
          variables = Map#{ "input" => Value.Obj(input) }, operationName = None }

    /// SDL の AuditExportFormat の綴り。
    def formatName(format: AuditExportFormat): String = match format {
        case AuditExportFormat.Csv  => "CSV"
        case AuditExportFormat.Json => "JSON"
    }

    // ---- 実行 ----

    ///
    /// 全件を新しい順に集める。先に件数を見て上限を超えていれば 413、管理 API が断れば（forbidden・引数の形）その code を写す。
    ///
    pub def collect(execute: GraphqlRequest -> GraphqlResponse \ ef, filter: Filter): Result[Failure, List[Value]] \ ef =
        match ask(execute, countRequest(filter)) {
            case Err(failure) => Err(failure)
            case Ok(data)     =>
                let total = Value.field("auditEventsCount", data) |> Value.asInt |> Option.getWithDefault(0);
                if (total > maxRows()) Err(tooMany()) else pages(execute, filter, None, Nil)
        }

    /// after より古いページを読み足す。ページが満杯でなければ終わり。集めた物は先頭に積み、最後に戻す。
    def pages(execute: GraphqlRequest -> GraphqlResponse \ ef, filter: Filter, after: Option[String], acc: List[Value]): Result[Failure, List[Value]] \ ef =
        match ask(execute, pageRequest(filter, after)) {
            case Err(failure) => Err(failure)
            case Ok(data)     =>
                let page = match Value.field("auditEvents", data) { case Value.List(found) => found case _ => Nil };
                let collected = List.foldLeft((stacked, event) -> event :: stacked, acc, page);
                let lastId = List.last(page) |> Option.flatMap(event -> Value.field("id", event) |> Value.asStr);
                match lastId {
                    case Some(id) if List.length(page) >= pageSize() => pages(execute, filter, Some(id), collected)
                    case _                                          => Ok(List.reverse(collected))
                }
        }

    ///
    /// 書き出した事を積む。読みの後に 1 回（別の Tx）。
    ///
    pub def record(execute: GraphqlRequest -> GraphqlResponse \ ef, format: AuditExportFormat, filter: Filter, count: Int32): Result[Failure, Unit] \ ef =
        ask(execute, recordRequest(format, filter, count)) |> Result.map(_ -> ())

    /// 1 リクエスト流し、errors があれば先頭を Failure にする。
    def ask(execute: GraphqlRequest -> GraphqlResponse \ ef, given: GraphqlRequest): Result[Failure, Value] \ ef =
        let response = execute(given);
        match List.head(response#errors) {
            case None        => Ok(response#data)
            case Some(error) => Err(failureOf(error))
        }

    ///
    /// GraphQL のエラー 1 つを断りに。extensions.code を写し（無ければ INTERNAL）、HTTP のステータスは code から決める。
    ///
    pub def failureOf(error: Value): Failure =
        let code = Value.path(List#{"extensions", "code"}, error) |> Value.asStr |> Option.getWithDefault("INTERNAL");
        { status = statusOf(code), code = code, message = Value.field("message", error) |> Value.asStr |> Option.getWithDefault("") }

    /// extensions.code → HTTP のステータス。
    pub def statusOf(code: String): Int32 = match code {
        case "UNAUTHENTICATED" => 401
        case "FORBIDDEN"       => 403
        case "NOT_FOUND"       => 404
        case "INVALID"         => 400
        case _                 => 500
    }

    /// 断りの本文 {"error": {"code": ..., "message": ...}}。
    pub def failureBody(failure: Failure): String =
        JsonValue.toJsonString(Value.Obj(Map#{ "error" => Value.Obj(Map#{ "code" => Value.Str(failure#code), "message" => Value.Str(failure#message) }) }))

    // ---- 出る物の形 ----

    /// Content-Type。
    pub def contentType(format: AuditExportFormat): String = match format {
        case AuditExportFormat.Csv  => "text/csv; charset=utf-8"
        case AuditExportFormat.Json => "application/x-ndjson"
    }

    /// ファイルの拡張子。
    pub def extension(format: AuditExportFormat): String = match format {
        case AuditExportFormat.Csv  => "csv"
        case AuditExportFormat.Json => "jsonl"
    }

    ///
    /// ファイル名。`audit-<slug>-<since>_<until>.<ext>`（since / until は YYYY-MM-DD に切る）。
    /// 両方無ければ `audit-<slug>-all-<今日>.<ext>`、片方だけなら無い側を all か今日で埋める。
    ///
    pub def fileName(slug: String, format: AuditExportFormat, filter: Filter, nowMs: Int64): String =
        let today = dateOf(Timestamp.toIso8601(Timestamp.fromEpochMillis(nowMs)));
        let range = match (filter#since, filter#until) {
            case (None, None)               => "all-${today}"
            case (since, until)             => "${since |> Option.map(dateOf) |> Option.getWithDefault("all")}_${until |> Option.map(dateOf) |> Option.getWithDefault(today)}"
        };
        "audit-${slug}-${range}.${extension(format)}"

    /// ISO 8601 の先頭の YYYY-MM-DD。
    pub def dateOf(iso: String): String = String.takeLeft(10, iso)

    /// Content-Disposition。
    pub def contentDisposition(fileName: String): String = "attachment; filename=\"${fileName}\""

    ///
    /// 管理画面でその 1 件を開く URL。Host があれば https の絶対 URL、無ければ相対。
    ///
    pub def urlOf(host: Option[String], slug: String, id: String): String =
        let path = "/p/${slug}/settings/audit?id=${id}";
        match host {
            case Some(found) => "https://${found}${path}"
            case None        => path
        }

    /// UTF-8 の BOM（U+FEFF。文字列の中に見えない 1 文字が入っている）。Excel が UTF-8 と判定するために先頭に置く。
    pub def bom(): String = "﻿"

    /// CSV の見出し行。AuditEvent の並び + url。
    pub def csvHeader(): String = "id,createdAt,actorKind,actorId,actor,action,targetKind,targetId,detail,url\r\n"

    ///
    /// CSV の 1 行。セルは常に `"` で囲み、中の `"` は `""` に。detail は JSON の compact 文字列を 1 セルに。改行は `\r\n`。
    ///
    pub def csvLine(event: Value, url: String): String =
        let text = name -> Value.field(name, event) |> Value.asStr |> Option.getWithDefault("");
        List#{ text("id"), text("createdAt"), text("actorKind"), text("actorId"), text("actor"), text("action"), text("targetKind"), text("targetId"),
               JsonValue.toJsonString(Value.field("detail", event)), url }
            |> List.map(csvCell)
            |> List.join(",")
            |> cell -> "${cell}\r\n"

    /// セル 1 つ。`"` で囲み、中の `"` は `""`。改行と `,` は囲みの中でそのまま。
    pub def csvCell(text: String): String = "\"${String.replace(src = "\"", dst = "\"\"", text)}\""

    ///
    /// JSON Lines の 1 行。AuditEvent のフィールド + url。detail は入れ子のまま。
    ///
    pub def jsonLine(event: Value, url: String): String =
        let fields = match event { case Value.Obj(found) => found case _ => Map.empty() };
        "${JsonValue.toJsonString(Value.Obj(Map.insert("url", Value.Str(url), fields)))}\n"

    ///
    /// 本文。CSV は BOM + 見出し + 行、JSON Lines は行だけ。
    ///
    pub def render(format: AuditExportFormat, host: Option[String], slug: String, events: List[Value]): String =
        let line = event -> {
            let url = urlOf(host, slug, Value.field("id", event) |> Value.asStr |> Option.getWithDefault(""));
            match format {
                case AuditExportFormat.Csv  => csvLine(event, url)
                case AuditExportFormat.Json => jsonLine(event, url)
            }
        };
        let lines = events |> List.map(line) |> List.join("");
        match format {
            case AuditExportFormat.Csv  => "${bom()}${csvHeader()}${lines}"
            case AuditExportFormat.Json => lines
        }

}
