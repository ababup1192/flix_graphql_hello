///
/// MCP のツール。tools/list に出す物（名前・説明・引数・annotations）。
///
pub enum Tool with Eq, Order, ToString {
    case ListTypes
    case GetType
    case SearchEntries
    case GetEntry
    case DiffEntry
    case CreateEntry
    case UpdateEntry
    case PublishCheck
    case Impact
    case Publish
    case Unpublish
    case PreviewUrl
}

mod Tool {

    ///
    /// tools/list の並び。
    ///
    pub def all(): List[Tool] =
        Tool.ListTypes :: Tool.GetType :: Tool.SearchEntries :: Tool.GetEntry :: Tool.DiffEntry :: Tool.CreateEntry ::
        Tool.UpdateEntry :: Tool.PublishCheck :: Tool.Impact :: Tool.Publish :: Tool.Unpublish :: Tool.PreviewUrl :: Nil

    ///
    /// tools/call の name。API の一部なので綴りは変えない。
    ///
    pub def name(tool: Tool): String = match tool {
        case Tool.ListTypes     => "list_types"
        case Tool.GetType       => "get_type"
        case Tool.SearchEntries => "search_entries"
        case Tool.GetEntry      => "get_entry"
        case Tool.DiffEntry     => "diff_entry"
        case Tool.CreateEntry   => "create_entry"
        case Tool.UpdateEntry   => "update_entry"
        case Tool.PublishCheck  => "publish_check"
        case Tool.Impact        => "impact"
        case Tool.Publish       => "publish"
        case Tool.Unpublish     => "unpublish"
        case Tool.PreviewUrl    => "preview_url"
    }

    ///
    /// name から。知らない名前は None（-32602）。
    ///
    pub def parse(text: String): Option[Tool] =
        all() |> List.find(tool -> name(tool) == text)

}

///
/// ツールの引数の型。tools/list の inputSchema と、引数の復号の両方をここから出す。
///
/// - Str / Int / Bool: JSON の string / integer / boolean
/// - Json: JSON のオブジェクト（entry の fields）。中身は見ない
/// - Enum(選択肢): string で、選択肢のどれか
/// - Obj(引数の定義): 入れ子のオブジェクト（VersionRef）
///
pub enum ArgType {
    case Str
    case Int
    case Bool
    case Json
    case Enum(List[String])
    case Obj(List[ArgDef])
}

///
/// 引数 1 つの定義。(名前, 説明, 必須か, 型)。
///
pub enum ArgDef {
    case ArgDef(String, String, Bool, ArgType)
}

mod ArgDef {

    pub def name(argDef: ArgDef): String = { let ArgDef.ArgDef(found, _, _, _) = argDef; found }

    pub def description(argDef: ArgDef): String = { let ArgDef.ArgDef(_, found, _, _) = argDef; found }

    pub def isRequired(argDef: ArgDef): Bool = { let ArgDef.ArgDef(_, _, found, _) = argDef; found }

    pub def argType(argDef: ArgDef): ArgType = { let ArgDef.ArgDef(_, _, _, found) = argDef; found }

}

///
/// ツール 1 つの定義。
///
/// - tool: どのツールか
/// - description: AI が読む説明。呼ぶ順番の決まり（publish の前に publish_check など）もここに書く（説明は仕様として扱う）
/// - args: 引数の定義。inputSchema と復号の元
/// - readOnlyHint / destructiveHint / idempotentHint: MCP の annotations
///
pub type alias ToolDef = { tool = Tool, description = String, args = List[ArgDef], readOnlyHint = Bool, destructiveHint = Bool, idempotentHint = Bool }

///
/// MCP のツールの表と、引数 → 管理 API の GraphQL リクエスト、応答 → content の写し。
/// ユースケースは呼ばず、admin engine への GraphQL クライアントとして動く。Tx・主体・last_used_at・エラーの分類は AdminRunner のまま。
///
/// WhyNot: ユースケース（ContentEntries など）を直に呼ばないのは、Session を持たない pub 関数を素通りして権限の検査が抜けるため。
/// GraphQL 越しなら Runner が主体を決め、業務エラーが同じ code で返る。
///
mod McpTools {

    ///
    /// ツールの呼び出しの失敗。
    ///
    /// - Business: 業務エラー。GraphQL の errors[0].extensions（code / message / violations / entity / id / expectedVersion / actualVersion）をそのまま持つ。isError: true の content になる
    /// - Unauthenticated: 身元の検証に落ちた（死んだ PAT）。HTTP 401 にする
    ///
    pub enum Failure with Eq, ToString {
        case Business(Value)
        case Unauthenticated(String)
    }

    ///
    /// get_entry の format。RICH_TEXT の値をどう写すか。
    ///
    pub enum Format with Eq, Order, ToString {
        case Markdown
        case Text
        case Html
        case Doc
    }

    ///
    /// get_entry の stage。どちらの中身を読むか。
    ///
    pub enum ReadStage with Eq, Order, ToString {
        case Draft
        case Published
    }

    ///
    /// フィールドの kind のうち、中身を辿る時に区別が要る物。それ以外は Other。
    ///
    enum Shape with Eq {
        case RichText
        case Object
        case Blocks
        case Other
    }

    /// format の名前と値の対応。enum の選択肢と復号の両方がここから出る。
    def formats(): List[(String, Format)] =
        ("markdown", Format.Markdown) :: ("text", Format.Text) :: ("html", Format.Html) :: ("doc", Format.Doc) :: Nil

    /// stage の名前と値の対応（GraphQL の ContentStage と同じ綴り）。
    def readStages(): List[(String, ReadStage)] =
        ("DRAFT", ReadStage.Draft) :: ("PUBLISHED", ReadStage.Published) :: Nil

    /// impact の action（GraphQL の ImpactAction と同じ綴り。そのまま variables に渡す）。
    def impactActions(): List[String] = "PUBLISH" :: "UNPUBLISH" :: "DELETE" :: Nil

    /// search_entries の stage の絞り込み（GraphQL の EntryStage と同じ綴り）。
    def entryStages(): List[String] = "DRAFT" :: "PUBLISHED" :: "CHANGED" :: Nil

    /// 名前 → 値の表から引く。
    def lookup(table: List[(String, a)], text: String): Option[a] =
        table |> List.find(pair -> fst(pair) == text) |> Option.map(snd)

    // ---- ツール定義の表 ----

    def entryIdArg(): ArgDef = ArgDef.ArgDef("id", "entry の id", true, ArgType.Str)

    def typeArg(): ArgDef = ArgDef.ArgDef("type", "content type の apiId（list_types の apiId）", true, ArgType.Str)

    def versionRefArg(name: String, description: String): ArgDef =
        ArgDef.ArgDef(name, description, true, ArgType.Obj(
            ArgDef.ArgDef("stage", "DRAFT（今の下書き）か PUBLISHED（公開中の中身。未公開なら NOT_FOUND）", false, ArgType.Enum(readStages() |> List.map(fst))) ::
            ArgDef.ArgDef("versionId", "バージョンの id（get_entry の versions か diff の応答）", false, ArgType.Str) :: Nil))

    ///
    /// 全ツールの定義。tools/list の inputSchema も引数の復号もこの表から出す（二重管理しない）。
    ///
    pub def tools(): List[ToolDef] =
        { tool = Tool.ListTypes, description = "content type の一覧（フィールドの定義込み）。entry を作る前に、型の apiId とフィールドの apiId / kind をここで確かめる",
          args = Nil, readOnlyHint = true, destructiveHint = false, idempotentHint = true } ::
        { tool = Tool.GetType, description = "content type 1 つ（フィールドの定義込み）",
          args = ArgDef.ArgDef("apiId", "content type の apiId", true, ArgType.Str) :: Nil, readOnlyHint = true, destructiveHint = false, idempotentHint = true } ::
        { tool = Tool.SearchEntries, description = "型の entry を検索する。更新が新しい順。RICH_TEXT の値は平文にして返す。stage を渡すとこのページの中から DRAFT / PUBLISHED / CHANGED を絞る",
          args = typeArg() ::
                 ArgDef.ArgDef("search", "下書きの中身に含む文字列", false, ArgType.Str) ::
                 ArgDef.ArgDef("first", "件数（既定 20、最大 100）", false, ArgType.Int) ::
                 ArgDef.ArgDef("skip", "読み飛ばす件数（既定 0）", false, ArgType.Int) ::
                 ArgDef.ArgDef("stage", "entry の状態で絞る", false, ArgType.Enum(entryStages())) :: Nil,
          readOnlyHint = true, destructiveHint = false, idempotentHint = true } ::
        { tool = Tool.GetEntry, description = "entry 1 つ。stage は DRAFT（既定。今の下書き）か PUBLISHED（公開中の中身）。format は RICH_TEXT の値の返し方（markdown が既定。text / html / doc）",
          args = entryIdArg() ::
                 ArgDef.ArgDef("stage", "どちらの中身を読むか（既定 DRAFT）", false, ArgType.Enum(readStages() |> List.map(fst))) ::
                 ArgDef.ArgDef("format", "RICH_TEXT の値の返し方（既定 markdown）", false, ArgType.Enum(formats() |> List.map(fst))) :: Nil,
          readOnlyHint = true, destructiveHint = false, idempotentHint = true } ::
        { tool = Tool.DiffEntry, description = "entry の 2 つのバージョンの差分（from → to）。RICH_TEXT は Markdown の行差分。publish の前に from: { stage: PUBLISHED }, to: { stage: DRAFT } で何が変わるかを見る",
          args = entryIdArg() :: versionRefArg("from", "比べる元。{ stage } か { versionId } のどちらか 1 つ") :: versionRefArg("to", "比べる先。{ stage } か { versionId } のどちらか 1 つ") :: Nil,
          readOnlyHint = true, destructiveHint = false, idempotentHint = true } ::
        { tool = Tool.CreateEntry, description = "下書きを作る。fields は apiId → 値。RICH_TEXT のフィールドは Markdown の文字列で渡せる（doc に変換する）。公開はしない（publish を別に呼ぶ）",
          args = typeArg() :: ArgDef.ArgDef("fields", "apiId → 値のオブジェクト", true, ArgType.Json) :: Nil,
          readOnlyHint = false, destructiveHint = false, idempotentHint = false } ::
        { tool = Tool.UpdateEntry, description = "下書きを直す。fields のキーだけ上書きし、null で消す。RICH_TEXT は Markdown の文字列で渡せる。expectedVersion は get_entry の version（違えば CONFLICT で actualVersion が返るので、読み直してから）",
          args = entryIdArg() :: ArgDef.ArgDef("fields", "apiId → 値のオブジェクト（上書きするキーだけ）", true, ArgType.Json) :: ArgDef.ArgDef("expectedVersion", "get_entry で読んだ version", true, ArgType.Int) :: Nil,
          readOnlyHint = false, destructiveHint = false, idempotentHint = false } ::
        { tool = Tool.PublishCheck, description = "公開できるか（書き込まない）。violations が空なら publish は通る。publish の前に必ず呼ぶ",
          args = entryIdArg() :: Nil, readOnlyHint = true, destructiveHint = false, idempotentHint = true } ::
        { tool = Tool.Impact, description = "操作の影響（書き込まない）。breaks は壊れる参照元、cascades は一緒に動く参照先。publish の前に impact(id, PUBLISH)、unpublish の前に impact(id, UNPUBLISH) を呼ぶ",
          args = entryIdArg() :: ArgDef.ArgDef("action", "PUBLISH / UNPUBLISH / DELETE", true, ArgType.Enum(impactActions())) :: Nil,
          readOnlyHint = true, destructiveHint = false, idempotentHint = true } ::
        { tool = Tool.Publish, description = "下書きを公開する。前に publish_check と impact(id, PUBLISH) と diff_entry を呼び、結果を確かめてから呼ぶ。withDependencies なら未公開の参照先も先に公開する",
          args = entryIdArg() :: ArgDef.ArgDef("withDependencies", "未公開の参照先も一緒に公開する（既定 false）", false, ArgType.Bool) :: Nil,
          readOnlyHint = false, destructiveHint = false, idempotentHint = true } ::
        { tool = Tool.Unpublish, description = "公開を取り下げる（下書きは残る）。前に impact(id, UNPUBLISH) を呼び、breaks が空である事を確かめてから呼ぶ",
          args = entryIdArg() :: Nil, readOnlyHint = false, destructiveHint = true, idempotentHint = true } ::
        { tool = Tool.PreviewUrl, description = "下書きを公開前のサイトで見るプレビュートークンと URL を発行する（1 時間で切れる。型に previewUrl が無ければ url は null）",
          args = entryIdArg() :: Nil, readOnlyHint = false, destructiveHint = false, idempotentHint = false } :: Nil

    ///
    /// ツールの定義。表に無いのは表の書き忘れなので止める。
    ///
    pub def definitionOf(tool: Tool): ToolDef =
        match tools() |> List.find(definition -> definition#tool == tool) {
            case Some(found) => found
            case None        => bug!("tools() に ${tool} の定義がありません")
        }

    // ---- tools/list ----

    ///
    /// tools/list の tools。
    ///
    pub def toolListValue(): List[Value] =
        tools() |> List.map(definition -> Value.Obj(Map#{
            "name"        => Value.Str(Tool.name(definition#tool)),
            "description" => Value.Str(definition#description),
            "inputSchema" => inputSchema(definition#args),
            "annotations" => Value.Obj(Map#{
                "readOnlyHint"    => Value.Bool(definition#readOnlyHint),
                "destructiveHint" => Value.Bool(definition#destructiveHint),
                "idempotentHint"  => Value.Bool(definition#idempotentHint) }) }))

    ///
    /// 引数の定義から JSON Schema（object）を組む。
    ///
    pub def inputSchema(args: List[ArgDef]): Value =
        Value.Obj(Map#{
            "type"                 => Value.Str("object"),
            "additionalProperties" => Value.Bool(false),
            "properties"           => Value.Obj(args |> List.map(argDef -> (ArgDef.name(argDef), propertySchema(argDef))) |> List.toMap),
            "required"             => Value.List(args |> List.filter(ArgDef.isRequired) |> List.map(argDef -> Value.Str(ArgDef.name(argDef)))) })

    /// 引数 1 つの schema（description 付き）。
    def propertySchema(argDef: ArgDef): Value =
        match typeSchema(ArgDef.argType(argDef)) {
            case Value.Obj(fields) => Value.Obj(Map.insert("description", Value.Str(ArgDef.description(argDef)), fields))
            case other             => other
        }

    /// 型の schema。
    def typeSchema(argType: ArgType): Value = match argType {
        case ArgType.Str         => Value.Obj(Map#{ "type" => Value.Str("string") })
        case ArgType.Int         => Value.Obj(Map#{ "type" => Value.Str("integer") })
        case ArgType.Bool        => Value.Obj(Map#{ "type" => Value.Str("boolean") })
        case ArgType.Json        => Value.Obj(Map#{ "type" => Value.Str("object") })
        case ArgType.Enum(names) => Value.Obj(Map#{ "type" => Value.Str("string"), "enum" => Value.List(names |> List.map(Value.Str)) })
        case ArgType.Obj(args)   => inputSchema(args)
    }

    // ---- 引数の復号 ----

    ///
    /// arguments を定義で検査して名前 → 値にする。必須が無い・型が違う・enum 外は Err に日本語の理由（-32602 の message になる）。
    /// null は無いのと同じ。省略した任意の引数は入らない。定義に無い名前は捨てる。
    ///
    pub def decodeArgs(args: List[ArgDef], given: Value): Result[String, Map[String, Value]] = match given {
        case Value.Null        => decodeFields(args, Map.empty())
        case Value.Obj(fields) => decodeFields(args, fields)
        case _                 => Err("arguments はオブジェクトで渡してください")
    }

    def decodeFields(args: List[ArgDef], fields: Map[String, Value]): Result[String, Map[String, Value]] =
        Result.traverse(argDef -> decodeOne(argDef, fields), args)
            |> Result.map(decoded -> decoded |> List.filterMap(identity) |> List.toMap)

    /// 引数 1 つ。無ければ必須なら Err、任意なら None。
    def decodeOne(argDef: ArgDef, fields: Map[String, Value]): Result[String, Option[(String, Value)]] =
        let name = ArgDef.name(argDef);
        match Map.get(name, fields) |> Option.filter(value -> value != Value.Null) {
            case None        => if (ArgDef.isRequired(argDef)) Err("引数 '${name}' が要ります") else Ok(None)
            case Some(value) => checkType(name, ArgDef.argType(argDef), value) |> Result.map(checked -> Some((name, checked)))
        }

    /// 型の検査。Obj は中も復号する（enum 外などは中の名前で Err）。
    def checkType(name: String, argType: ArgType, value: Value): Result[String, Value] = match (argType, value) {
        case (ArgType.Str, Value.Str(_))    => Ok(value)
        case (ArgType.Int, Value.Int(_))    => Ok(value)
        case (ArgType.Bool, Value.Bool(_))  => Ok(value)
        case (ArgType.Json, Value.Obj(_))   => Ok(value)
        case (ArgType.Enum(names), Value.Str(text)) if List.memberOf(text, names) => Ok(value)
        case (ArgType.Obj(args), Value.Obj(_)) => decodeArgs(args, value) |> Result.map(Value.Obj)
        case _                              => Err("引数 '${name}' は ${expectedText(argType)}で渡してください")
    }

    /// 型の説明（エラーの文言用）。
    def expectedText(argType: ArgType): String = match argType {
        case ArgType.Str         => "文字列"
        case ArgType.Int         => "整数"
        case ArgType.Bool        => "真偽値"
        case ArgType.Json        => "オブジェクト"
        case ArgType.Enum(names) => "${List.join(" / ", names)} のどれか"
        case ArgType.Obj(_)      => "オブジェクト"
    }

    // ---- 復号済みの引数を読む ----

    def strArg(name: String, args: Map[String, Value]): String =
        Map.get(name, args) |> Option.flatMap(Value.asStr) |> Option.getWithDefault("")

    def optStrArg(name: String, args: Map[String, Value]): Option[String] =
        Map.get(name, args) |> Option.flatMap(Value.asStr)

    def intArg(name: String, fallback: Int32, args: Map[String, Value]): Int32 =
        Map.get(name, args) |> Option.flatMap(Value.asInt) |> Option.getWithDefault(fallback)

    def boolArg(name: String, args: Map[String, Value]): Bool =
        Map.get(name, args) |> Option.flatMap(value -> match value { case Value.Bool(found) => Some(found) case _ => None }) |> Option.getWithDefault(false)

    def valueArg(name: String, args: Map[String, Value]): Value =
        Map.get(name, args) |> Option.getWithDefault(Value.Null)

    /// enum の引数。復号で選択肢は検査済みなので、表に無ければ既定。
    def enumArg(name: String, table: List[(String, a)], fallback: a, args: Map[String, Value]): a =
        optStrArg(name, args) |> Option.flatMap(lookup(table)) |> Option.getWithDefault(fallback)

    // ---- GraphQL のリクエスト ----

    /// FieldDef の selection。children を depth 段まで。
    def fieldDefSelection(depth: Int32): String =
        let base = "id apiId name kind many required unique localized targetTypeId position config { maxLength sourceField min max integer options }";
        if (depth <= 0) base else "${base} children { ${fieldDefSelection(depth - 1)} }"

    /// ContentType の selection。
    def typeSelection(): String =
        "id apiId kind name singular plural previewUrl createdAt updatedAt fields { ${fieldDefSelection(2)} }"

    /// Entry の中身以外。
    def entrySummarySelection(): String = "id typeId version stage publishedAt createdAt updatedAt"

    /// FieldChange の selection。children を depth 段まで。
    def fieldChangeSelection(depth: Int32): String =
        let base = "path kind before after lines { kind text }";
        if (depth <= 0) base else "${base} children { ${fieldChangeSelection(depth - 1)} }"

    def request(queryText: String, variables: Map[String, Value]): GraphqlRequest =
        { queryText = queryText, variables = variables, operationName = None }

    pub def listTypesRequest(): GraphqlRequest =
        request("{ contentTypes { ${typeSelection()} } }", Map.empty())

    pub def typeRequest(apiId: String): GraphqlRequest =
        request("query($apiId: String!) { contentType(apiId: $apiId) { ${typeSelection()} } }", Map#{ "apiId" => Value.Str(apiId) })

    pub def entriesRequest(typeId: String, search: Option[String], first: Int32, skip: Int32): GraphqlRequest =
        request("query($typeId: ID!, $search: String, $first: Int, $skip: Int) { entries(typeId: $typeId, search: $search, first: $first, skip: $skip) { totalCount nodes { ${entrySummarySelection()} fields } } }",
            Map#{ "typeId" => Value.Str(typeId), "search" => search |> Option.map(Value.Str) |> Option.getWithDefault(Value.Null), "first" => Value.Int(first), "skip" => Value.Int(skip) })

    /// entry と全型の定義。withVersions なら公開時のバージョン（公開中の中身）も。
    pub def entryRequest(id: String, withVersions: Bool): GraphqlRequest =
        let versions = if (withVersions) " versions { id version reason fields createdAt }" else "";
        request("query($id: ID!) { entry(id: $id) { ${entrySummarySelection()} fields${versions} } contentTypes { id fields { ${fieldDefSelection(2)} } } }", Map#{ "id" => Value.Str(id) })

    pub def diffRequest(id: String, fromRef: Value, toRef: Value): GraphqlRequest =
        request("query($id: ID!, $from: VersionRef!, $to: VersionRef!) { entry(id: $id) { id diff(from: $from, to: $to) { ${fieldChangeSelection(3)} } } }",
            Map#{ "id" => Value.Str(id), "from" => fromRef, "to" => toRef })

    pub def createEntryRequest(typeId: String, fields: Value): GraphqlRequest =
        request("mutation($typeId: ID!, $fields: JSON!) { createEntry(typeId: $typeId, fields: $fields) { ${entrySummarySelection()} } }",
            Map#{ "typeId" => Value.Str(typeId), "fields" => fields })

    pub def updateEntryRequest(id: String, fields: Value, expectedVersion: Int32): GraphqlRequest =
        request("mutation($id: ID!, $fields: JSON!, $expectedVersion: Int!) { updateEntry(id: $id, fields: $fields, expectedVersion: $expectedVersion) { ${entrySummarySelection()} } }",
            Map#{ "id" => Value.Str(id), "fields" => fields, "expectedVersion" => Value.Int(expectedVersion) })

    pub def publishCheckRequest(id: String): GraphqlRequest =
        request("query($id: ID!) { publishCheck(id: $id) { ok violations { path message } unpublishedDependencies { ${entrySummarySelection()} } } }", Map#{ "id" => Value.Str(id) })

    pub def impactRequest(id: String, action: String): GraphqlRequest =
        request("query($id: ID!, $action: ImpactAction!) { impact(id: $id, action: $action) { breaks { entry { ${entrySummarySelection()} } via stage } cascades { ${entrySummarySelection()} } } }",
            Map#{ "id" => Value.Str(id), "action" => Value.Str(action) })

    pub def publishRequest(id: String, withDependencies: Bool): GraphqlRequest =
        request("mutation($id: ID!, $withDependencies: Boolean!) { publishEntry(id: $id, withDependencies: $withDependencies) { ${entrySummarySelection()} } }",
            Map#{ "id" => Value.Str(id), "withDependencies" => Value.Bool(withDependencies) })

    pub def unpublishRequest(id: String): GraphqlRequest =
        request("mutation($id: ID!) { unpublishEntry(id: $id) { ${entrySummarySelection()} } }", Map#{ "id" => Value.Str(id) })

    pub def previewUrlRequest(id: String): GraphqlRequest =
        request("mutation($id: ID!) { createPreviewToken(entryId: $id) { token entryId expiresAt url } }", Map#{ "id" => Value.Str(id) })

    // ---- 実行 ----

    ///
    /// 1 リクエスト流し、errors があれば先頭を Failure にする。
    ///
    def ask(execute: GraphqlRequest -> GraphqlResponse \ ef, given: GraphqlRequest): Result[Failure, Value] \ ef =
        let response = execute(given);
        match List.head(response#errors) {
            case None        => Ok(response#data)
            case Some(error) => Err(failureOf(error))
        }

    ///
    /// GraphQL のエラー 1 つを Failure に。extensions（code など）に message を足す。extensions が無い物（graphql-java の検証など）は INTERNAL。
    ///
    def failureOf(error: Value): Failure =
        let message = Value.field("message", error);
        let extensions = match Value.field("extensions", error) {
            case Value.Obj(fields) => fields
            case _                 => Map#{ "code" => Value.Str("INTERNAL") }
        };
        match Map.get("code", extensions) {
            case Some(Value.Str("UNAUTHENTICATED")) => Failure.Unauthenticated(message |> Value.asStr |> Option.getWithDefault("認証に失敗しました"))
            case _                                  => Failure.Business(Value.Obj(Map.insert("message", message, extensions)))
        }

    /// 指した物が無い（GraphQL が null を返した）。管理 API の NOT_FOUND と同じ形。
    def notFound(entity: String, label: String, id: String): Failure =
        Failure.Business(Value.Obj(Map#{ "code" => Value.Str("NOT_FOUND"), "message" => Value.Str("${label} '${id}' が見つかりません"), "entity" => Value.Str(entity), "id" => Value.Str(id) }))

    /// null なら NOT_FOUND。
    def orNotFound(entity: String, label: String, id: String, value: Value): Result[Failure, Value] = match value {
        case Value.Null => Err(notFound(entity, label, id))
        case found      => Ok(found)
    }

    ///
    /// ツールを呼ぶ。復号済みの引数と、admin engine への execute を受ける。
    ///
    pub def call(tool: Tool, args: Map[String, Value], execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef = match tool {
        case Tool.ListTypes     => ask(execute, listTypesRequest()) |> Result.map(Value.field("contentTypes"))
        case Tool.GetType       => getType(strArg("apiId", args), execute)
        case Tool.SearchEntries => searchEntries(args, execute)
        case Tool.GetEntry      => getEntry(args, execute)
        case Tool.DiffEntry     => ask(execute, diffRequest(strArg("id", args), valueArg("from", args), valueArg("to", args)))
                                       |> Result.flatMap(data -> orNotFound("Entry", "entry", strArg("id", args), Value.field("entry", data)))
                                       |> Result.map(Value.field("diff"))
        case Tool.CreateEntry   => createEntry(args, execute)
        case Tool.UpdateEntry   => updateEntry(args, execute)
        case Tool.PublishCheck  => ask(execute, publishCheckRequest(strArg("id", args))) |> Result.map(Value.field("publishCheck"))
        case Tool.Impact        => ask(execute, impactRequest(strArg("id", args), strArg("action", args))) |> Result.map(Value.field("impact"))
        case Tool.Publish       => ask(execute, publishRequest(strArg("id", args), boolArg("withDependencies", args))) |> Result.map(Value.field("publishEntry"))
        case Tool.Unpublish     => ask(execute, unpublishRequest(strArg("id", args))) |> Result.map(Value.field("unpublishEntry"))
        case Tool.PreviewUrl    => ask(execute, previewUrlRequest(strArg("id", args))) |> Result.map(Value.field("createPreviewToken"))
    }

    /// 型を apiId で引く。無ければ NOT_FOUND。
    def getType(apiId: String, execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef =
        ask(execute, typeRequest(apiId)) |> Result.flatMap(data -> orNotFound("ContentType", "content type", apiId, Value.field("contentType", data)))

    /// search_entries。型を引いてから entries。RICH_TEXT は平文に。stage があればこのページの中から絞る。
    def searchEntries(args: Map[String, Value], execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef =
        let first = Int32.min(100, Int32.max(1, intArg("first", 20, args)));
        let skip = Int32.max(0, intArg("skip", 0, args));
        let stage = optStrArg("stage", args);
        getType(strArg("type", args), execute) |> Result.flatMap(typeDef ->
            ask(execute, entriesRequest(Value.field("id", typeDef) |> Value.asStr |> Option.getWithDefault(""), optStrArg("search", args), first, skip))
                |> Result.map(data -> pageOf(fieldsOf(typeDef), stage, Value.field("entries", data))))

    /// entries の応答を { totalCount, count, nodes } に。nodes は stage で絞り、fields の RICH_TEXT を平文に。
    def pageOf(defs: List[Value], stage: Option[String], page: Value): Value =
        let nodes = listOf(Value.field("nodes", page))
            |> List.filter(node -> stage |> Option.forAll(wanted -> Value.field("stage", node) == Value.Str(wanted)))
            |> List.map(withFields(defs, readConverter(Format.Text)));
        Value.Obj(Map#{ "totalCount" => Value.field("totalCount", page), "count" => Value.Int(List.length(nodes)), "nodes" => Value.List(nodes) })

    /// get_entry。stage が PUBLISHED なら公開時のバージョンの中身。RICH_TEXT を format で写す。
    def getEntry(args: Map[String, Value], execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef =
        let id = strArg("id", args);
        let stage = enumArg("stage", readStages(), ReadStage.Draft, args);
        let format = enumArg("format", formats(), Format.Markdown, args);
        ask(execute, entryRequest(id, stage == ReadStage.Published)) |> Result.flatMap(data ->
            orNotFound("Entry", "entry", id, Value.field("entry", data)) |> Result.flatMap(entry ->
                contentOf(stage, id, entry) |> Result.map(fields ->
                    Value.Obj(Map.insert("fields", mapRichText(fieldDefsFor(entry, data), readConverter(format), fields), Map.remove("versions", objectFields(entry)))))))

    /// stage の中身。DRAFT は fields、PUBLISHED は一番新しい PUBLISH のバージョンの fields（未公開なら NOT_FOUND）。
    def contentOf(stage: ReadStage, id: String, entry: Value): Result[Failure, Value] = match stage {
        case ReadStage.Draft     => Ok(Value.field("fields", entry))
        case ReadStage.Published =>
            if (Value.field("stage", entry) == Value.Str("DRAFT")) Err(notFound("Version", "公開中の中身", id))
            else
                listOf(Value.field("versions", entry))
                    |> List.find(version -> Value.field("reason", version) == Value.Str("PUBLISH"))
                    |> Option.map(Value.field("fields"))
                    |> Option.toOk(notFound("Version", "公開中の中身", id))
    }

    /// create_entry。型を引いて RICH_TEXT の Markdown を doc にしてから createEntry。
    def createEntry(args: Map[String, Value], execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef =
        getType(strArg("type", args), execute) |> Result.flatMap(typeDef ->
            ask(execute, createEntryRequest(Value.field("id", typeDef) |> Value.asStr |> Option.getWithDefault(""), mapRichText(fieldsOf(typeDef), toDocValue, valueArg("fields", args))))
                |> Result.map(Value.field("createEntry")))

    /// update_entry。entry の型を引いて RICH_TEXT の Markdown を doc にしてから updateEntry。
    def updateEntry(args: Map[String, Value], execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef =
        let id = strArg("id", args);
        ask(execute, entryRequest(id, false)) |> Result.flatMap(data ->
            orNotFound("Entry", "entry", id, Value.field("entry", data)) |> Result.flatMap(entry ->
                ask(execute, updateEntryRequest(id, mapRichText(fieldDefsFor(entry, data), toDocValue, valueArg("fields", args)), intArg("expectedVersion", 0, args)))
                    |> Result.map(Value.field("updateEntry"))))

    // ---- 応答の読み方 ----

    def listOf(value: Value): List[Value] = match value {
        case Value.List(items) => items
        case _                 => Nil
    }

    def objectFields(value: Value): Map[String, Value] = match value {
        case Value.Obj(fields) => fields
        case _                 => Map.empty()
    }

    /// 型（か variant）の fields。
    def fieldsOf(typeDef: Value): List[Value] = listOf(Value.field("fields", typeDef))

    /// entry の typeId に合う型の fields（data.contentTypes から）。
    def fieldDefsFor(entry: Value, data: Value): List[Value] =
        listOf(Value.field("contentTypes", data))
            |> List.find(typeDef -> Value.field("id", typeDef) == Value.field("typeId", entry))
            |> Option.map(fieldsOf)
            |> Option.getWithDefault(Nil)

    /// entry の fields を写した物に差し替える。
    def withFields(defs: List[Value], convert: Value -> Value, entry: Value): Value =
        Value.Obj(Map.insert("fields", mapRichText(defs, convert, Value.field("fields", entry)), objectFields(entry)))

    // ---- richText の写し ----

    ///
    /// entry の中身のうち RICH_TEXT の値だけを convert で写す。OBJECT の中（many なら各要素）と BLOCKS の各 block（blockType の variant の子）も辿る。
    /// 定義に無いキーはそのまま。
    ///
    pub def mapRichText(defs: List[Value], convert: Value -> Value, fields: Value): Value = match fields {
        case Value.Obj(entries) =>
            Value.Obj(Map.mapWithKey((apiId, value) ->
                defs |> List.find(fieldDef -> Value.field("apiId", fieldDef) == Value.Str(apiId))
                     |> Option.map(fieldDef -> mapField(fieldDef, convert, value))
                     |> Option.getWithDefault(value), entries))
        case other => other
    }

    /// フィールド 1 つの値。
    def mapField(fieldDef: Value, convert: Value -> Value, value: Value): Value = match (shapeOf(fieldDef), value) {
        case (Shape.RichText, _)              => convert(value)
        case (Shape.Object, Value.List(items)) => Value.List(items |> List.map(mapRichText(childrenOf(fieldDef), convert)))
        case (Shape.Object, _)                => mapRichText(childrenOf(fieldDef), convert, value)
        case (Shape.Blocks, Value.List(items)) => Value.List(items |> List.map(mapBlock(fieldDef, convert)))
        case _                                => value
    }

    /// block 1 つ。blockType の variant の子で辿る。variant が無ければそのまま。
    def mapBlock(fieldDef: Value, convert: Value -> Value, block: Value): Value =
        childrenOf(fieldDef)
            |> List.find(variant -> Value.field("apiId", variant) == Value.field("blockType", block))
            |> Option.map(variant -> mapRichText(childrenOf(variant), convert, block))
            |> Option.getWithDefault(block)

    /// kind の文字列を 1 回だけ Shape に。
    def shapeOf(fieldDef: Value): Shape = match Value.field("kind", fieldDef) {
        case Value.Str("RICH_TEXT") => Shape.RichText
        case Value.Str("OBJECT")    => Shape.Object
        case Value.Str("BLOCKS")    => Shape.Blocks
        case _                      => Shape.Other
    }

    def childrenOf(fieldDef: Value): List[Value] = listOf(Value.field("children", fieldDef))

    ///
    /// 書く向き: 文字列なら Markdown として doc に。doc（オブジェクト）や null はそのまま。
    ///
    pub def toDocValue(value: Value): Value = match value {
        case Value.Str(text) => JsonValue.fromJson(Markdown.fromMarkdown(text))
        case other           => other
    }

    ///
    /// 読む向き: format ごとの doc の写し。doc（オブジェクト）でない値はそのまま。
    ///
    /// WhyNot: html で画像の URL の写しを空にするのは、MCP の html は AI が読む物で配信用ではなく、asset の URL を引く分の SQL を増やさないため。
    /// image は data-asset-id だけ持つ p になる。
    ///
    pub def readConverter(format: Format): Value -> Value = match format {
        case Format.Markdown => docTo(doc -> Markdown.toMarkdown(doc))
        case Format.Text     => docTo(doc -> RichText.toText(doc))
        case Format.Html     => docTo(doc -> RichText.toHtml(Map.empty(), doc))
        case Format.Doc      => identity
    }

    /// doc なら render した文字列に。
    def docTo(render: Util.Json.Json -> String, value: Value): Value = match value {
        case Value.Obj(_) => Value.Str(render(JsonValue.toJson(value)))
        case other        => other
    }

    // ---- content ----

    ///
    /// content[0].text の上限（256 KB）。超えたら本文だけ切って truncated を出す。
    ///
    pub def maxTextBytes(): Int32 = 256 * 1024

    ///
    /// text が上限に収まるまで切る。(切った text, 切ったか)。
    ///
    pub def truncate(text: String): (String, Bool) =
        if (Http.utf8Length(text) <= maxTextBytes()) (text, false) else (cutToFit(maxTextBytes(), text), true)

    /// chars 文字で切って収まらなければ半分にする（1 文字は最大 4 バイトなので 2 回で必ず収まる）。
    def cutToFit(chars: Int32, text: String): String =
        let cut = String.takeLeft(chars, text);
        if (Http.utf8Length(cut) <= maxTextBytes()) cut else cutToFit(chars / 2, text)

    ///
    /// tools/call の result。成功は data の JSON を text に、業務エラーは extensions の JSON を text にして isError。
    /// 切り詰めたら structuredContent に truncated: true。
    ///
    pub def callResult(outcome: Result[Failure, Value]): Value = match outcome {
        case Ok(data)                       => textResult(JsonValue.toJsonString(data), false)
        case Err(Failure.Business(found))   => textResult(JsonValue.toJsonString(found), true)
        case Err(Failure.Unauthenticated(message)) => textResult(JsonValue.toJsonString(Value.Obj(Map#{ "code" => Value.Str("UNAUTHENTICATED"), "message" => Value.Str(message) })), true)
    }

    def textResult(text: String, isError: Bool): Value =
        let (cut, truncated) = truncate(text);
        let base = Map#{ "content" => Value.List(Value.Obj(Map#{ "type" => Value.Str("text"), "text" => Value.Str(cut) }) :: Nil), "isError" => Value.Bool(isError) };
        Value.Obj(if (truncated) Map.insert("structuredContent", Value.Obj(Map#{ "truncated" => Value.Bool(true) }), base) else base)

}
