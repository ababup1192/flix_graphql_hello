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
    case DeleteEntry
    case RestoreVersion
    case PreviewUrl
    case Whoami
}

mod Tool {

    ///
    /// tools/list の並び。
    ///
    pub def all(): List[Tool] =
        Tool.ListTypes :: Tool.GetType :: Tool.SearchEntries :: Tool.GetEntry :: Tool.DiffEntry :: Tool.CreateEntry ::
        Tool.UpdateEntry :: Tool.PublishCheck :: Tool.Impact :: Tool.Publish :: Tool.Unpublish :: Tool.DeleteEntry :: Tool.RestoreVersion ::
        Tool.PreviewUrl :: Tool.Whoami :: Nil

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
        case Tool.DeleteEntry   => "delete_entry"
        case Tool.RestoreVersion => "restore_version"
        case Tool.PreviewUrl    => "preview_url"
        case Tool.Whoami        => "whoami"
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
    /// 中身を検査しない値（EntryFieldCondition の value のように、op と kind で型が決まる物）
    case Any
    case Enum(List[String])
    case Obj(List[ArgDef])
    case Arr(ArgType)
}

///
/// entries の問い合わせに渡す物。filter（GraphQL の where）と orderBy は管理 API の入力の形そのまま（渡さなければ None）。
///
/// WhyNot: フィールドを where と呼ばないのは、where が Flix の予約語で、レコードのフィールド名でも
/// パースエラー（Expected '}' before '='）になるため。GraphQL の変数名は where のまま。
///
pub type alias EntriesQuery = {
    typeId = String, search = Option[String], filter = Option[Value], orderBy = Option[Value],
    first = Int32, skip = Int32, after = Option[String]
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
/// WhyNot: ユースケース（ContentEntries など）を直に呼ばないのは、管理 API と同じ形（証明の作り方、id の写し、エラーの形）を 2 度書かないため。
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

    ///
    /// 一覧で返す本文（RICH_TEXT）の量。
    ///
    pub enum Body with Eq {
        case Full
        case Excerpt
    }

    /// body の名前と値の対応。
    def bodies(): List[(String, Body)] = ("full", Body.Full) :: ("excerpt", Body.Excerpt) :: Nil

    /// 名前に戻す（応答の body に出す）。
    def bodyName(body: Body): String = match body {
        case Body.Full    => "full"
        case Body.Excerpt => "excerpt"
    }

    /// excerpt にする時の文字数。
    def excerptChars(): Int32 = 200

    /// フィールドの条件の比べ方（GraphQL の FieldConditionOp と同じ綴り）。
    def fieldConditionOps(): List[String] =
        "EQ" :: "IN" :: "CONTAINS" :: "STARTS_WITH" :: "GT" :: "GTE" :: "LT" :: "LTE" :: "IS_NULL" :: "ARRAY_CONTAINS" :: Nil

    /// 名前 → 値の表から引く。
    def lookup(table: List[(String, a)], text: String): Option[a] =
        table |> List.find(pair -> fst(pair) == text) |> Option.map(snd)

    // ---- ツール定義の表 ----

    def entryIdArg(): ArgDef = ArgDef.ArgDef("id", "entry の id", true, ArgType.Str)

    def typeArg(): ArgDef = ArgDef.ArgDef("type", "content type の apiId（list_types の apiId）", true, ArgType.Str)

    ///
    /// 一覧の絞り込み（管理 API の EntryWhere と同じ形をそのまま渡す）。
    ///
    def whereArg(): ArgDef =
        ArgDef.ArgDef("where", "絞り込み。fields の value は op と kind で型が決まる（IN は配列、IS_NULL は真偽値、GT 〜 LTE は数値か日時の文字列）", false,
            ArgType.Obj(
                ArgDef.ArgDef("stage", "公開中か下書きか（PUBLISHED は公開後に下書きが進んだ物も含む）", false, ArgType.Enum(readStages() |> List.map(fst))) ::
                ArgDef.ArgDef("id_in", "この id のどれか", false, ArgType.Arr(ArgType.Str)) ::
                ArgDef.ArgDef("fields", "フィールドの値の条件（複数なら全部に当たる物）", false, ArgType.Arr(ArgType.Obj(
                    ArgDef.ArgDef("apiId", "フィールドの apiId", true, ArgType.Str) ::
                    ArgDef.ArgDef("op", "比べ方", true, ArgType.Enum(fieldConditionOps())) ::
                    ArgDef.ArgDef("value", "比べる値", false, ArgType.Any) :: Nil))) :: Nil))

    ///
    /// 一覧の並び順（管理 API の EntryOrderBy と同じ形）。
    ///
    def orderByArg(): ArgDef =
        ArgDef.ArgDef("orderBy", "並び順（先頭が優先）。既定は更新が新しい順。field はフィールドの apiId か updatedAt / createdAt / publishedAt", false,
            ArgType.Arr(ArgType.Obj(
                ArgDef.ArgDef("field", "並べる物", true, ArgType.Str) ::
                ArgDef.ArgDef("direction", "昇順か降順か", true, ArgType.Enum("ASC" :: "DESC" :: Nil)) :: Nil)))

    def versionRefArg(name: String, description: String): ArgDef =
        ArgDef.ArgDef(name, description, true, ArgType.Obj(
            ArgDef.ArgDef("stage", "DRAFT（今の下書き）か PUBLISHED（公開中の中身。未公開なら空で、差分は全部 ADDED）", false, ArgType.Enum(readStages() |> List.map(fst))) ::
            ArgDef.ArgDef("versionId", "バージョンの id（get_entry の応答の versions[].id）", false, ArgType.Str) :: Nil))

    ///
    /// RICH_TEXT に渡す Markdown の方言（Markdown.flix の冒頭の要約）。create_entry / update_entry の description に載せる。
    /// 説明は仕様として扱うので、書ける物は全部書き、無い物（文字色・文字サイズ）も書く。
    ///
    pub def markdownGuide(): String =
        "RICH_TEXT の Markdown は GFM + 次の方言だけ（文字色・文字サイズ・生の HTML は無い）: "
        ++ "見出しの id は `## 見出し {#id}`。"
        ++ "callout は `> [!NOTE]` / `> [!TIP]` / `> [!WARNING]`（`> **ポイント:**` は callout にならない）。"
        ++ "折りたたみは `<details><summary>要約</summary>` から `</details>` の行まで。"
        ++ "数式は `$…$`（行内）と `$$` の行で囲む（ブロック）。TeX のまま。"
        ++ "コードは ```` ```lang:path/file {1,3-5} ````（`:` の後がファイル名、`{}` が強調する行。どちらも省ける。lang が mermaid なら図）。"
        ++ "画像は `![alt](asset:ID \"caption\")`、動画は `@[video](asset:ID)`。1 行に画像を空白区切りで 2 つ以上並べると gallery。"
        ++ "画像に使えるのは asset の id だけで、外部 URL の画像（`![alt](https://…)`）は image にならず alt を URL へのリンクにした文字になる。"
        ++ "他の entry へのリンクは `[text](entry:ID)`。"
        ++ "タスクは `- [ ]` / `- [x]`。"
        ++ "URL だけの行は YouTube / Vimeo / X なら embed、他は linkCard。"
        ++ "下線は `<u>…</u>`、下付きは `~x~`、上付きは `^x^`、蛍光ペンは `==x==`。入れ子は 2 空白"

    ///
    /// 値の形の決まり（description に載せる）。試用で AI が迷った所だけ。
    ///
    pub def fieldValueGuide(): String =
        "値の形: SLUG は config.sourceField があっても自動生成しない（create 時に自分で入れる。required なら無いと公開できない）。"
        ++ "REFERENCE は entry の id の文字列で、存在しない id でも下書きには通り、publish_check で参照先の消失として出る。"
        ++ "DATE は UTC の ISO 8601 ちょうど 1 通り（2026-09-09T00:00:00Z）。オフセット付き・ミリ秒付き・日付だけは断る。DATE_ONLY は日付だけ（2026-09-09）で、時刻付きは断る。ASSET と本文の画像は asset の id だけ（外部 URL は使えない）。"

    ///
    /// 全ツールの定義。tools/list の inputSchema も引数の復号もこの表から出す（二重管理しない）。並びは Tool.all。
    ///
    /// WhyNot: 1 つのリストに書かないのは、description が長くて 1 つの関数に置くと呼び出し側に inline されて JVM の「Method too large」で落ちるため。
    ///
    pub def tools(): List[ToolDef] = Tool.all() |> List.map(definitionOf)

    ///
    /// ツールの定義。
    ///
    pub def definitionOf(tool: Tool): ToolDef = match tool {
        case Tool.ListTypes      => listTypesDef()
        case Tool.GetType        => getTypeDef()
        case Tool.SearchEntries  => searchEntriesDef()
        case Tool.GetEntry       => getEntryDef()
        case Tool.DiffEntry      => diffEntryDef()
        case Tool.CreateEntry    => createEntryDef()
        case Tool.UpdateEntry    => updateEntryDef()
        case Tool.PublishCheck   => publishCheckDef()
        case Tool.Impact         => impactDef()
        case Tool.Publish        => publishDef()
        case Tool.Unpublish      => unpublishDef()
        case Tool.DeleteEntry    => deleteEntryDef()
        case Tool.RestoreVersion => restoreVersionDef()
        case Tool.PreviewUrl     => previewUrlDef()
        case Tool.Whoami         => whoamiDef()
    }

    def listTypesDef(): ToolDef =
        { tool = Tool.ListTypes, description = "content type の一覧（フィールドの定義込み）。entry を作る前に、型の apiId とフィールドの apiId / kind をここで確かめる。${fieldValueGuide()}",
          args = Nil, readOnlyHint = true, destructiveHint = false, idempotentHint = true }

    def getTypeDef(): ToolDef =
        { tool = Tool.GetType, description = "content type 1 つ（フィールドの定義込み）。${fieldValueGuide()}",
          args = ArgDef.ArgDef("apiId", "content type の apiId", true, ArgType.Str) :: Nil, readOnlyHint = true, destructiveHint = false, idempotentHint = true }

    def searchEntriesDef(): ToolDef =
        { tool = Tool.SearchEntries, description = "型の entry を検索する。where で絞り、orderBy で並べる（既定は更新が新しい順）。"
                                                   ++ "RICH_TEXT の値は平文で返す。既定の body: full は本文を全部返すので、一覧を見るだけなら body: \"excerpt\" を渡し、全文は get_entry で読む（60 KB の本文が並ぶと応答が上限に当たる）。"
                                                   ++ "stage は DRAFT ならサーバ側で絞り切る。PUBLISHED / CHANGED は公開中をサーバ側で絞ってから、このページの中で分ける（CHANGED は SQL の上では公開中に含まれるため）。where.stage を一緒に渡した時は stage が勝つ。"
                                                   ++ "totalCount はサーバ側で絞った後・ページの中で分ける前の件数、count はこのページに残った件数。next_cursor が null でなければ、それを after に渡して続きを読める",
          args = typeArg() ::
                 ArgDef.ArgDef("search", "下書きの中身に含む文字列（本文・タグの値にも当たる）", false, ArgType.Str) ::
                 whereArg() ::
                 orderByArg() ::
                 ArgDef.ArgDef("first", "件数（既定 20、最大 100）", false, ArgType.Int) ::
                 ArgDef.ArgDef("skip", "読み飛ばす件数（既定 0）。after とは同時に渡せない", false, ArgType.Int) ::
                 ArgDef.ArgDef("after", "前の応答の next_cursor。その次から読む", false, ArgType.Str) ::
                 ArgDef.ArgDef("stage", "entry の状態で絞る", false, ArgType.Enum(entryStages())) ::
                 ArgDef.ArgDef("body", "RICH_TEXT の返し方（既定 full）。一覧では excerpt を勧める", false, ArgType.Enum(bodies() |> List.map(fst))) :: Nil,
          readOnlyHint = true, destructiveHint = false, idempotentHint = true }

    def getEntryDef(): ToolDef =
        { tool = Tool.GetEntry, description = "entry 1 つ。stage は DRAFT（既定。今の下書き）か PUBLISHED（公開中の中身。fields だけが公開中の物で、stage と version は下書きの物のまま）。"
                                              ++ "format は RICH_TEXT の値の返し方（markdown が既定。text / html / doc）。version は下書きの楽観ロック用で、publish しても進まない（update_entry で進む）。"
                                              ++ "versions はバージョンの一覧（新しい順。id / version / reason / author / createdAt。中身は含めない）で、diff_entry と restore_version の versionId はここから取る",
          args = entryIdArg() ::
                 ArgDef.ArgDef("stage", "どちらの中身を読むか（既定 DRAFT）", false, ArgType.Enum(readStages() |> List.map(fst))) ::
                 ArgDef.ArgDef("format", "RICH_TEXT の値の返し方（既定 markdown）", false, ArgType.Enum(formats() |> List.map(fst))) :: Nil,
          readOnlyHint = true, destructiveHint = false, idempotentHint = true }

    def diffEntryDef(): ToolDef =
        { tool = Tool.DiffEntry, description = "entry の 2 つのバージョンの差分（from → to）。RICH_TEXT は両方にあれば Markdown の行差分（TEXT）、片方に無ければ doc ごと ADDED / REMOVED。"
                                               ++ "publish の前に from: { stage: PUBLISHED }, to: { stage: DRAFT } で何が変わるかを見る。versionId は get_entry の versions から",
          args = entryIdArg() :: versionRefArg("from", "比べる元。{ stage } か { versionId } のどちらか 1 つ") :: versionRefArg("to", "比べる先。{ stage } か { versionId } のどちらか 1 つ") :: Nil,
          readOnlyHint = true, destructiveHint = false, idempotentHint = true }

    def createEntryDef(): ToolDef =
        { tool = Tool.CreateEntry, description = "下書きを作る。fields は apiId → 値。RICH_TEXT のフィールドは Markdown の文字列で渡せる（doc に変換する）。公開はしない（publish を別に呼ぶ）。${fieldValueGuide()}${markdownGuide()}",
          args = typeArg() :: ArgDef.ArgDef("fields", "apiId → 値のオブジェクト", true, ArgType.Json) :: Nil,
          readOnlyHint = false, destructiveHint = false, idempotentHint = false }

    def updateEntryDef(): ToolDef =
        { tool = Tool.UpdateEntry, description = "下書きを直す。fields のキーだけ上書きし、null で消す。RICH_TEXT は Markdown の文字列で渡せる。expectedVersion は get_entry の version（違えば CONFLICT で actualVersion が返るので、読み直してから）。${fieldValueGuide()}${markdownGuide()}",
          args = entryIdArg() :: ArgDef.ArgDef("fields", "apiId → 値のオブジェクト（上書きするキーだけ）", true, ArgType.Json) :: ArgDef.ArgDef("expectedVersion", "get_entry で読んだ version", true, ArgType.Int) :: Nil,
          readOnlyHint = false, destructiveHint = false, idempotentHint = false }

    def publishCheckDef(): ToolDef =
        { tool = Tool.PublishCheck, description = "公開できるか（書き込まない）。ok は violations が空という意味。unpublishedDependencies（未公開の参照先）があれば、素の publish は INVALID で失敗し、publish に withDependencies: true が要る。publish の前に必ず呼ぶ",
          args = entryIdArg() :: Nil, readOnlyHint = true, destructiveHint = false, idempotentHint = true }

    def impactDef(): ToolDef =
        { tool = Tool.Impact, description = "操作の影響（書き込まない）。breaks は壊れる参照元、cascades は一緒に動く参照先。publish の前に impact(id, PUBLISH)、unpublish の前に impact(id, UNPUBLISH)、delete_entry の前に impact(id, DELETE) を呼ぶ",
          args = entryIdArg() :: ArgDef.ArgDef("action", "PUBLISH / UNPUBLISH / DELETE", true, ArgType.Enum(impactActions())) :: Nil,
          readOnlyHint = true, destructiveHint = false, idempotentHint = true }

    def publishDef(): ToolDef =
        { tool = Tool.Publish, description = "下書きを公開する。前に publish_check と impact(id, PUBLISH) と diff_entry を呼び、結果を確かめてから呼ぶ。publish_check に unpublishedDependencies があれば withDependencies: true で未公開の参照先も先に公開する（無いと INVALID）",
          args = entryIdArg() :: ArgDef.ArgDef("withDependencies", "未公開の参照先も一緒に公開する（既定 false）", false, ArgType.Bool) :: Nil,
          readOnlyHint = false, destructiveHint = false, idempotentHint = true }

    def unpublishDef(): ToolDef =
        { tool = Tool.Unpublish, description = "公開を取り下げる（下書きは残る）。前に impact(id, UNPUBLISH) を呼び、breaks が空である事を確かめてから呼ぶ",
          args = entryIdArg() :: Nil, readOnlyHint = false, destructiveHint = true, idempotentHint = true }

    def deleteEntryDef(): ToolDef =
        { tool = Tool.DeleteEntry, description = "entry をゴミ箱に入れる。ゴミ箱に入るだけで戻せる（DB からは消えない）。公開中なら公開の取り下げも含み、公開中の entry が参照していれば拒まれる。先に impact(id, DELETE) を呼び、breaks が空である事を確かめてから呼ぶ",
          args = entryIdArg() :: Nil, readOnlyHint = false, destructiveHint = true, idempotentHint = true }

    def restoreVersionDef(): ToolDef =
        { tool = Tool.RestoreVersion, description = "バージョンの中身を下書きに戻す（versionId は get_entry の versions から）。公開側は動かないので、公開するには publish。expectedVersion は get_entry の version（違えば CONFLICT）",
          args = entryIdArg() :: ArgDef.ArgDef("versionId", "戻すバージョンの id（get_entry の versions[].id）", true, ArgType.Str) :: ArgDef.ArgDef("expectedVersion", "get_entry で読んだ version", true, ArgType.Int) :: Nil,
          readOnlyHint = false, destructiveHint = false, idempotentHint = false }

    def previewUrlDef(): ToolDef =
        { tool = Tool.PreviewUrl, description = "下書きを公開前のサイトで見るプレビュートークンと URL を発行する（1 時間で切れる）。型に previewUrl が無ければ url は null で、howToUse にトークンの使い方が入る: "
                                                ++ "コンテンツ API（GET / POST /graphql）に X-Preview-Token: <token> を付けると、この entry と参照先の下書きが読める",
          args = entryIdArg() :: Nil, readOnlyHint = false, destructiveHint = false, idempotentHint = false }

    def whoamiDef(): ToolDef =
        { tool = Tool.Whoami, description = "今の身元（API キー / PAT / ログイン）の名前・役割・scope と、使える権限（permissions）の一覧。tools/list は権限で絞らないので、書く前にここで確かめると FORBIDDEN を避けられる",
          args = Nil, readOnlyHint = true, destructiveHint = false, idempotentHint = true }

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
        case ArgType.Any         => Value.Obj(Map.empty())
        case ArgType.Enum(names) => Value.Obj(Map#{ "type" => Value.Str("string"), "enum" => Value.List(names |> List.map(Value.Str)) })
        case ArgType.Obj(args)   => inputSchema(args)
        case ArgType.Arr(inner)  => Value.Obj(Map#{ "type" => Value.Str("array"), "items" => typeSchema(inner) })
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
        case (ArgType.Any, _)               => Ok(value)
        case (ArgType.Enum(names), Value.Str(text)) if List.memberOf(text, names) => Ok(value)
        case (ArgType.Obj(args), Value.Obj(_)) => decodeArgs(args, value) |> Result.map(Value.Obj)
        case (ArgType.Arr(inner), Value.List(items)) => Result.traverse(item -> checkType(name, inner, item), items) |> Result.map(Value.List)
        case _                              => Err("引数 '${name}' は ${expectedText(argType)}で渡してください")
    }

    /// 型の説明（エラーの文言用）。
    def expectedText(argType: ArgType): String = match argType {
        case ArgType.Str         => "文字列"
        case ArgType.Int         => "整数"
        case ArgType.Bool        => "真偽値"
        case ArgType.Json        => "オブジェクト"
        case ArgType.Any         => "値"
        case ArgType.Enum(names) => "${List.join(" / ", names)} のどれか"
        case ArgType.Obj(_)      => "オブジェクト"
        case ArgType.Arr(inner)  => "${expectedText(inner)}の配列"
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

    ///
    /// 管理 API へのリクエスト。文書の操作には `McpGetEntry` のように「Mcp + ツール名の UpperCamel」の名前を付ける（リクエストの行の graphql.operation.name と、
    /// graphql-java のエラーの path に出る）。
    ///
    def request(queryText: String, variables: Map[String, Value]): GraphqlRequest =
        { queryText = queryText, variables = variables, operationName = None }

    pub def listTypesRequest(): GraphqlRequest =
        request("query McpListTypes { contentTypes { ${typeSelection()} } }", Map.empty())

    pub def typeRequest(apiId: String): GraphqlRequest =
        request("query McpGetType($apiId: String!) { contentType(apiId: $apiId) { ${typeSelection()} } }", Map#{ "apiId" => Value.Str(apiId) })

    ///
    /// entries の問い合わせ。where と orderBy は管理 API の入力をそのまま変数に載せる（形は decodeArgs が検査済み）。
    ///
    pub def entriesRequest(entriesQuery: EntriesQuery): GraphqlRequest =
        request("query McpSearchEntries($typeId: ID!, $search: String, $where: EntryWhere, $orderBy: [EntryOrderBy!], $first: Int, $skip: Int, $after: String) "
                ++ "{ entries(typeId: $typeId, search: $search, where: $where, orderBy: $orderBy, first: $first, skip: $skip, after: $after) "
                ++ "{ totalCount pageInfo { hasNextPage endCursor } nodes { ${entrySummarySelection()} fields } } }",
            Map#{ "typeId" => Value.Str(entriesQuery#typeId),
                  "search" => entriesQuery#search |> Option.map(Value.Str) |> Option.getWithDefault(Value.Null),
                  "where" => entriesQuery#filter |> Option.getWithDefault(Value.Null),
                  "orderBy" => entriesQuery#orderBy |> Option.getWithDefault(Value.Null),
                  "first" => Value.Int(entriesQuery#first), "skip" => Value.Int(entriesQuery#skip),
                  "after" => entriesQuery#after |> Option.map(Value.Str) |> Option.getWithDefault(Value.Null) })

    /// EntryVersion の中身以外（get_entry の versions に出す物）。
    def versionSummarySelection(): String = "id version reason author createdAt"

    /// entry（バージョンの一覧込み）と全型の定義。withVersionFields なら各バージョンの中身も（公開中の中身を読む時）。
    pub def entryRequest(id: String, withVersionFields: Bool): GraphqlRequest =
        let versionFields = if (withVersionFields) " fields" else "";
        request("query McpGetEntry($id: ID!) { entry(id: $id) { ${entrySummarySelection()} fields versions { ${versionSummarySelection()}${versionFields} } } contentTypes { id fields { ${fieldDefSelection(2)} } } }", Map#{ "id" => Value.Str(id) })

    pub def diffRequest(id: String, fromRef: Value, toRef: Value): GraphqlRequest =
        request("query McpDiffEntry($id: ID!, $from: VersionRef!, $to: VersionRef!) { entry(id: $id) { id diff(from: $from, to: $to) { ${fieldChangeSelection(3)} } } }",
            Map#{ "id" => Value.Str(id), "from" => fromRef, "to" => toRef })

    pub def createEntryRequest(typeId: String, fields: Value): GraphqlRequest =
        request("mutation McpCreateEntry($typeId: ID!, $fields: JSON!) { createEntry(typeId: $typeId, fields: $fields) { ${entrySummarySelection()} } }",
            Map#{ "typeId" => Value.Str(typeId), "fields" => fields })

    pub def updateEntryRequest(id: String, fields: Value, expectedVersion: Int32): GraphqlRequest =
        request("mutation McpUpdateEntry($id: ID!, $fields: JSON!, $expectedVersion: Int!) { updateEntry(id: $id, fields: $fields, expectedVersion: $expectedVersion) { ${entrySummarySelection()} } }",
            Map#{ "id" => Value.Str(id), "fields" => fields, "expectedVersion" => Value.Int(expectedVersion) })

    pub def publishCheckRequest(id: String): GraphqlRequest =
        request("query McpPublishCheck($id: ID!) { publishCheck(id: $id) { ok violations { path message } unpublishedDependencies { ${entrySummarySelection()} } } }", Map#{ "id" => Value.Str(id) })

    pub def impactRequest(id: String, action: String): GraphqlRequest =
        request("query McpImpact($id: ID!, $action: ImpactAction!) { impact(id: $id, action: $action) { breaks { entry { ${entrySummarySelection()} } via stage } cascades { ${entrySummarySelection()} } } }",
            Map#{ "id" => Value.Str(id), "action" => Value.Str(action) })

    pub def publishRequest(id: String, withDependencies: Bool): GraphqlRequest =
        request("mutation McpPublish($id: ID!, $withDependencies: Boolean!) { publishEntry(id: $id, withDependencies: $withDependencies) { ${entrySummarySelection()} } }",
            Map#{ "id" => Value.Str(id), "withDependencies" => Value.Bool(withDependencies) })

    pub def unpublishRequest(id: String): GraphqlRequest =
        request("mutation McpUnpublish($id: ID!) { unpublishEntry(id: $id) { ${entrySummarySelection()} } }", Map#{ "id" => Value.Str(id) })

    pub def deleteEntryRequest(id: String): GraphqlRequest =
        request("mutation McpDeleteEntry($id: ID!) { deleteEntry(id: $id) }", Map#{ "id" => Value.Str(id) })

    pub def restoreVersionRequest(id: String, versionId: String, expectedVersion: Int32): GraphqlRequest =
        request("mutation McpRestoreVersion($id: ID!, $versionId: ID!, $expectedVersion: Int!) { restoreVersion(id: $id, versionId: $versionId, expectedVersion: $expectedVersion) { ${entrySummarySelection()} } }",
            Map#{ "id" => Value.Str(id), "versionId" => Value.Str(versionId), "expectedVersion" => Value.Int(expectedVersion) })

    pub def previewUrlRequest(id: String): GraphqlRequest =
        request("mutation McpPreviewUrl($id: ID!) { createPreviewToken(entryId: $id) { token entryId expiresAt url } }", Map#{ "id" => Value.Str(id) })

    pub def whoamiRequest(): GraphqlRequest =
        request("query McpWhoami { viewer { kind name roles scope permissions } }", Map.empty())

    ///
    /// url が無い時の preview_url の案内。
    ///
    pub def previewHowToUse(): String =
        "コンテンツ API（GET / POST /graphql）に X-Preview-Token: <token> を付けると、この entry と参照先の下書きが読める（型に previewUrl を設定すれば url が出る）"

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
    /// GraphQL のエラー 1 つを Failure に。extensions（code など）に message を足す。code が無い物（graphql-java の検証など）は INTERNAL。
    ///
    /// WhyNot: graphql-java が足す classification を残さないのは、error-codes.md の extensions に無い名前で、AI が code と取り違えるため。
    ///
    def failureOf(error: Value): Failure =
        let message = Value.field("message", error);
        let extensions = objectFields(Value.field("extensions", error))
            |> Map.remove("classification")
            |> Map.insertWith((_, existing) -> existing, "code", Value.Str("INTERNAL"));
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
        case Tool.DeleteEntry   => ask(execute, deleteEntryRequest(strArg("id", args))) |> Result.map(data -> Value.Obj(Map#{ "id" => Value.field("deleteEntry", data), "deleted" => Value.Bool(true) }))
        case Tool.RestoreVersion => ask(execute, restoreVersionRequest(strArg("id", args), strArg("versionId", args), intArg("expectedVersion", 0, args))) |> Result.map(Value.field("restoreVersion"))
        case Tool.PreviewUrl    => ask(execute, previewUrlRequest(strArg("id", args))) |> Result.map(data -> withHowToUse(Value.field("createPreviewToken", data)))
        case Tool.Whoami        => ask(execute, whoamiRequest()) |> Result.map(Value.field("viewer"))
    }

    /// preview_url の応答。url が null なら howToUse を足す。
    def withHowToUse(preview: Value): Value = match Value.field("url", preview) {
        case Value.Null => Value.Obj(Map.insert("howToUse", Value.Str(previewHowToUse()), objectFields(preview)))
        case _          => preview
    }

    /// 型を apiId で引く。無ければ NOT_FOUND。
    def getType(apiId: String, execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef =
        ask(execute, typeRequest(apiId)) |> Result.flatMap(data -> orNotFound("ContentType", "content type", apiId, Value.field("contentType", data)))

    /// search_entries。型を引いてから entries。RICH_TEXT は平文に。stage があればこのページの中から絞る。after は管理 API の cursor をそのまま通す。
    def searchEntries(args: Map[String, Value], execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef =
        let stage = optStrArg("stage", args);
        let body = enumArg("body", bodies(), Body.Full, args);
        getType(strArg("type", args), execute) |> Result.flatMap(typeDef ->
            ask(execute, entriesRequest({
                    typeId = Value.field("id", typeDef) |> Value.asStr |> Option.getWithDefault(""),
                    search = optStrArg("search", args),
                    filter = withServerStage(stage, Map.get("where", args)),
                    orderBy = Map.get("orderBy", args),
                    first = Int32.min(100, Int32.max(1, intArg("first", 20, args))),
                    skip = Int32.max(0, intArg("skip", 0, args)),
                    after = optStrArg("after", args) }))
                |> Result.map(data -> pageOf(fieldsOf(typeDef), pageStage(stage), body, Value.field("entries", data))))

    ///
    /// MCP の stage（3 値）を where.stage（2 値）に写して where に載せる。stage を渡していなければ where はそのまま。
    ///
    /// WhyNot: CHANGED をそのまま送らないのは、SQL の上では CHANGED が「公開中で下書きが進んだ物」＝ PUBLISHED の
    /// 部分集合で、where.stage が PUBLISHED / DRAFT の 2 値しか持たないため。上位集合まではサーバ側で絞れる。
    ///
    /// WhyNot: where.stage を優先しないのは、stage の方が細かい 3 値で、両方渡された時に細かい側を捨てると
    /// 絞り込みが緩む（利用者が意図した以上に返る）ため。
    ///
    def withServerStage(stage: Option[String], filter: Option[Value]): Option[Value] =
        match serverStage(stage) {
            case None       => filter
            case Some(text) =>
                let base = filter |> Option.flatMap(value -> match value { case Value.Obj(fields) => Some(fields) case _ => None }) |> Option.getWithDefault(Map.empty());
                Some(Value.Obj(Map.insert("stage", Value.Str(text), base)))
        }

    /// サーバ側で絞れる stage。CHANGED は公開中の部分集合なので PUBLISHED まで絞る。
    pub def serverStage(stage: Option[String]): Option[String] = match stage {
        case Some("DRAFT")     => Some("DRAFT")
        case Some("PUBLISHED") => Some("PUBLISHED")
        case Some("CHANGED")   => Some("PUBLISHED")
        case _                 => None
    }

    /// ページの中でさらに分ける必要がある stage。DRAFT はサーバ側で絞り切れているので None。
    pub def pageStage(stage: Option[String]): Option[String] = match stage {
        case Some("DRAFT") => None
        case other         => other
    }

    /// entries の応答を { totalCount, count, body, nodes, next_cursor } に。nodes は残りの stage で分け、fields の RICH_TEXT を平文に。
    /// next_cursor は次のページがあれば endCursor、無ければ null。
    def pageOf(defs: List[Value], stage: Option[String], body: Body, page: Value): Value =
        let nodes = listOf(Value.field("nodes", page))
            |> List.filter(node -> stage |> Option.forAll(wanted -> Value.field("stage", node) == Value.Str(wanted)))
            |> List.map(withFields(defs, listConverter(body)));
        let nextCursor = if (Value.path(List#{"pageInfo", "hasNextPage"}, page) == Value.Bool(true)) Value.path(List#{"pageInfo", "endCursor"}, page) else Value.Null;
        Value.Obj(Map#{ "totalCount" => Value.field("totalCount", page), "count" => Value.Int(List.length(nodes)),
                        "body" => Value.Str(bodyName(body)), "nodes" => Value.List(nodes), "next_cursor" => nextCursor })

    ///
    /// 一覧の RICH_TEXT の写し方。full は平文のまま、excerpt は先頭 200 文字に切って、切った印と元の長さを本文の末尾に置く。
    ///
    /// WhyNot: 切った印を別のフィールドにしないのは、値だけを読むエージェントが切り詰めに気付かず、
    /// 200 文字を全文と思って要約や重複の判定を誤るため。本文の中に書けば必ず目に入る。
    ///
    pub def listConverter(body: Body): Value -> Value = match body {
        case Body.Full    => readConverter(Format.Text)
        case Body.Excerpt => value -> excerptOf(readConverter(Format.Text)(value))
    }

    /// 平文を先頭 200 文字に切る。収まっていればそのまま。
    def excerptOf(value: Value): Value = match value {
        case Value.Str(text) =>
            let length = String.length(text);
            if (length <= excerptChars()) value
            else Value.Str(String.takeLeft(excerptChars(), text) ++ "…（先頭 ${excerptChars()} 文字。全 ${length} 文字。全文は get_entry で）")
        case other => other
    }

    /// get_entry。stage が PUBLISHED なら公開時のバージョンの中身。RICH_TEXT を format で写す。versions は中身を落として付ける。
    def getEntry(args: Map[String, Value], execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef =
        let id = strArg("id", args);
        let stage = enumArg("stage", readStages(), ReadStage.Draft, args);
        let format = enumArg("format", formats(), Format.Markdown, args);
        ask(execute, entryRequest(id, stage == ReadStage.Published)) |> Result.flatMap(data ->
            orNotFound("Entry", "entry", id, Value.field("entry", data)) |> Result.flatMap(entry ->
                contentOf(stage, id, entry) |> Result.map(fields ->
                    Value.Obj(objectFields(entry)
                        |> Map.insert("fields", mapRichText(fieldDefsFor(entry, data), readConverter(format), fields))
                        |> Map.insert("versions", Value.List(listOf(Value.field("versions", entry)) |> List.map(withoutFields)))))))

    /// バージョンの中身（fields）を落とす。
    def withoutFields(version: Value): Value = Value.Obj(Map.remove("fields", objectFields(version)))

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

    /// create_entry。型を引いて RICH_TEXT の Markdown を doc にしてから createEntry。型が無ければ、書く権限が無い人には型の有無より先に FORBIDDEN。
    def createEntry(args: Map[String, Value], execute: GraphqlRequest -> GraphqlResponse \ ef): Result[Failure, Value] \ ef =
        match getType(strArg("type", args), execute) {
            case Ok(typeDef) =>
                ask(execute, createEntryRequest(Value.field("id", typeDef) |> Value.asStr |> Option.getWithDefault(""), mapRichText(fieldsOf(typeDef), toDocValue, valueArg("fields", args))))
                    |> Result.map(Value.field("createEntry"))
            case Err(missing) => Err(forbiddenBefore(missing, execute))
        }

    ///
    /// 型が引けなかった時の失敗。NOT_FOUND なら createEntry を typeId 無しで 1 回投げ、FORBIDDEN が返ればそれ（権限の断りが型の有無より先）、
    /// それ以外（書ける人には typeId の INVALID）なら元の NOT_FOUND。
    ///
    /// WhyNot: mutation を先に投げて型の解決を後にしないのは、createEntry が typeId（ID）を取るのに対しツールの引数は apiId で、
    /// RICH_TEXT の Markdown を doc にするにも型の定義が先に要るため。型の無い時だけ 1 回余分に投げる。
    ///
    /// WhyNot: 型が無い時に NOT_FOUND をそのまま返さないのは、読むだけの PAT や鍵から「型が無い」と「書けない」が読み分けられ、
    /// 管理 API の createEntry（権限 → 型の順に断る）と答えが揃わないため（2026-09-08 の実機 E2E）。
    ///
    def forbiddenBefore(missing: Failure, execute: GraphqlRequest -> GraphqlResponse \ ef): Failure \ ef =
        if (not isNotFound(missing)) missing
        else match ask(execute, createEntryRequest("", Value.Obj(Map.empty()))) {
            case Err(Failure.Business(found)) if Value.field("code", found) == Value.Str("FORBIDDEN") => Failure.Business(found)
            case _ => missing
        }

    /// NOT_FOUND の業務エラーか。
    def isNotFound(failure: Failure): Bool = match failure {
        case Failure.Business(found) => Value.field("code", found) == Value.Str("NOT_FOUND")
        case Failure.Unauthenticated(_) => false
    }

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
