///
/// HTTP のメソッド。`HttpRequest#method` は文字列のままなので、表と比べる前に `Method.parse` で変換する。
///
pub enum Method with Eq, Order {
    case Get
    case Post
    case Put
    case Patch
    case Delete
    case Options
    case Head
}

instance ToString[Method] {
    pub def toString(method: Method): String = Method.name(method)
}

mod Method {

    ///
    /// リクエスト行の綴り（"GET" など）。Allow ヘッダにもこれを並べる。
    ///
    pub def name(method: Method): String = match method {
        case Method.Get     => "GET"
        case Method.Post    => "POST"
        case Method.Put     => "PUT"
        case Method.Patch   => "PATCH"
        case Method.Delete  => "DELETE"
        case Method.Options => "OPTIONS"
        case Method.Head    => "HEAD"
    }

    ///
    /// リクエスト行の綴りから。大文字だけを受け、知らない物は None。
    ///
    pub def parse(text: String): Option[Method] = match text {
        case "GET"     => Some(Method.Get)
        case "POST"    => Some(Method.Post)
        case "PUT"     => Some(Method.Put)
        case "PATCH"   => Some(Method.Patch)
        case "DELETE"  => Some(Method.Delete)
        case "OPTIONS" => Some(Method.Options)
        case "HEAD"    => Some(Method.Head)
        case _         => None
    }

    ///
    /// Allow / Access-Control-Allow-Methods の値（"POST, GET"）。
    ///
    pub def join(methods: List[Method]): String =
        methods |> List.map(name) |> List.join(", ")

}

///
/// パスのパターンの 1 区切り。
///
/// - Literal: そのままの文字列と一致する（"graphql"）
/// - Param: 空でない 1 区切りを取り、名前で params に入れる（"{projectSlug}"）
///
pub enum Segment with Eq, Order, ToString {
    case Literal(String)
    case Param(String)
}

///
/// パスのパターン。"/" で区切った Segment の並び。"/" だけなら空。
///
pub enum Pattern with Eq, Order {
    case Pattern(List[Segment])
}

instance ToString[Pattern] {
    pub def toString(pattern: Pattern): String = Router.describe(pattern)
}

///
/// どの GraphQL エンジンで受けるか。エンジンが要らない道（/health など）は Route の engine を None にする。
///
pub enum Engine with Eq, Order, ToString {
    case Content
    case Admin
    case Account
}

///
/// 一致した時に handler が受ける物。
///
/// - request: 届いたリクエストそのまま
/// - params: パターンの Param の名前 → 生の文字列。型付きの id は handler の入口で parse する
/// - credential: ヘッダから読んだ Credential。middleware（Credentials.wrap）が入れる。キャッシュの可否と MCP のプレビュートークンの断りが見る
/// - auth: 認証の結果（認証済みユーザーか、断る理由）。エンジンのある行では Main.runRoute がプロジェクトと同じ Tx で決めて入れる
///
pub type alias RouteRequest = { request = HttpRequest, params = Map[String, String], credential = Credential, auth = Result[Rejection, Authenticated] }

///
/// 1 ルートの処理。
///
pub type alias Handler[ef: Eff] = RouteRequest -> HttpResponse \ ef

///
/// handler を包んで別の handler にする物（CORS、身元の読み取りなど）。
///
pub type alias Middleware[ef: Eff] = Handler[ef] -> Handler[ef]

///
/// ルート表の 1 行。
///
/// - method: 受けるメソッド
/// - pattern: パス
/// - engine: 必要な GraphQL エンジン。None ならエンジン無しで handler を呼ぶ
/// - handle: 処理（`handler` は Flix の予約語なので使えない）
///
pub type alias Route[ef: Eff] = { method = Method, pattern = Pattern, engine = Option[Engine], handle = Handler[ef] }

///
/// 表を引いた結果。
///
/// - Found: 一致した行と、パスから取った params
/// - MethodNotAllowed: パスは合う行があるがメソッドが違う。Allow に並べるメソッド（表の順、重複無し）
/// - NotFound: パスの合う行が無い
///
pub enum Match[ef: Eff] {
    case Found(Route[ef], Map[String, String])
    case MethodNotAllowed(List[Method])
    case NotFound
}

///
/// ルート表。パターンの解析、表の引き当て、プロジェクト接頭辞の複製。ソケットも effect も触らない純粋関数だけ。
///
/// 末尾スラッシュは同一視しない（"/health/" は "/health" に当たらない）。クエリ文字列は落としてから当てる。
///
mod Router {

    ///
    /// 表の 1 行を作る。pattern は "/p/{projectSlug}/graphql" の形。
    /// 解析できないパターンは表の書き間違いなので、起動時に止める（`describe` の一覧のテストが先に見つける）。
    ///
    pub def route(method: Method, pattern: String, engine: Option[Engine], handle: Handler[ef]): Route[ef] =
        match parsePattern(pattern) {
            case Ok(parsed)   => { method = method, pattern = parsed, engine = engine, handle = handle }
            case Err(message) => bug!("route '${pattern}': ${message}")
        }

    ///
    /// プロジェクトを選ぶ params の名前。`withProjectPrefix` が入れ、Host から選ぶ middleware も同じ名前に入れる。
    ///
    pub def projectSlugParam(): String = "projectSlug"

    ///
    /// "/p/{projectSlug}/graphql" のような文字列を Pattern にする。
    /// "/" で始まらない、空の区切り（"//" や末尾の "/"）、"{" "}" が区切りの形になっていない、同じ名前の Param が 2 つ、は Err。
    ///
    pub def parsePattern(text: String): Result[String, Pattern] =
        if (not String.startsWith(prefix = "/", text)) Err("パターンは / で始めてください")
        else if (text == "/") Ok(Pattern.Pattern(Nil))
        else
            String.splitOn(substr = "/", String.drop(1, text))
                |> List.map(parseSegment)
                |> Result.sequence
                |> Result.flatMap(segments ->
                    if (hasDuplicateParam(segments)) Err("同じ名前の Param が 2 つあります") else Ok(Pattern.Pattern(segments)))

    ///
    /// 1 区切り。"{name}" は Param、それ以外は Literal。空と、括弧の片方だけの物は Err。
    ///
    def parseSegment(text: String): Result[String, Segment] =
        if (text == "") Err("空の区切りがあります（// や末尾の /）")
        else if (String.startsWith(prefix = "{", text) and String.endsWith(suffix = "}", text)) {
            let name = text |> String.drop(1) |> String.dropRight(1);
            if (name == "" or String.contains(substr = "{", name) or String.contains(substr = "}", name)) Err("Param の名前が空か壊れています: ${text}")
            else Ok(Segment.Param(name))
        }
        else if (String.contains(substr = "{", text) or String.contains(substr = "}", text)) Err("Param は {name} の形で 1 区切りにしてください: ${text}")
        else Ok(Segment.Literal(text))

    /// Param の名前に重複があるか。
    def hasDuplicateParam(segments: List[Segment]): Bool =
        let names = segments |> List.filterMap(segment -> match segment { case Segment.Param(name) => Some(name) case Segment.Literal(_) => None });
        List.length(names) != Set.size(List.toSet(names))

    ///
    /// Pattern を "/p/{projectSlug}/graphql" の形に戻す。`parsePattern` と往復する。
    ///
    pub def describe(pattern: Pattern): String =
        let Pattern.Pattern(segments) = pattern;
        "/" + (segments |> List.map(segment -> match segment { case Segment.Literal(text) => text case Segment.Param(name) => "{${name}}" }) |> List.join("/"))

    ///
    /// 表の全行を "POST /graphql" の形で並べる。テストの期待値と一覧に。
    ///
    pub def describeAll(routes: List[Route[ef]]): List[String] =
        routes |> List.map(found -> "${Method.name(found#method)} ${describe(found#pattern)}")

    ///
    /// パスからクエリ文字列を落とす（"/health?probe=1" → "/health"）。
    ///
    pub def pathOf(path: String): String =
        String.splitOn(substr = "?", path) |> List.head |> Option.getWithDefault(path)

    ///
    /// パス（クエリ文字列は落とした後）を区切りに分ける。"/" は空、"/a/b" は ["a", "b"]、"/a/" は ["a", ""]（末尾の空は残す）。
    /// "/" で始まらない物は None。
    ///
    def segmentsOf(path: String): Option[List[String]] =
        match String.splitOn(substr = "/", path) {
            case "" :: "" :: Nil => Some(Nil)
            case "" :: rest      => Some(rest)
            case _               => None
        }

    ///
    /// パターンに区切りを当てる。全部を使い切れば params。Param は空の区切りを取らない。
    ///
    def matchSegments(pattern: List[Segment], segments: List[String], params: Map[String, String]): Option[Map[String, String]] =
        match (pattern, segments) {
            case (Nil, Nil)                                                          => Some(params)
            case (Segment.Literal(text) :: restPattern, found :: rest) if text == found => matchSegments(restPattern, rest, params)
            case (Segment.Param(name) :: restPattern, found :: rest) if found != ""    => matchSegments(restPattern, rest, Map.insert(name, found, params))
            case _                                                                   => None
        }

    ///
    /// パスの合う行を表の順に並べる（params 付き）。
    ///
    def candidates(routes: List[Route[ef]], path: String): List[(Route[ef], Map[String, String])] =
        match segmentsOf(pathOf(path)) {
            case None           => Nil
            case Some(segments) =>
                routes |> List.filterMap(found ->
                    let Pattern.Pattern(pattern) = found#pattern;
                    matchSegments(pattern, segments, Map.empty()) |> Option.map(params -> (found, params)))
        }

    ///
    /// 表を上から当てる。パスとメソッドの両方が合う最初の行が Found。
    /// パスだけ合う行があれば MethodNotAllowed（Allow は表の順で重複無し）。OPTIONS は preflight の middleware が受ける物なので 405 にせず NotFound。
    ///
    pub def find(routes: List[Route[ef]], method: Method, path: String): Match[ef] =
        let matched = candidates(routes, path);
        match List.find(pair -> fst(pair)#method == method, matched) {
            case Some((found, params)) => Match.Found(found, params)
            case None =>
                let allowed = matched |> List.map(pair -> fst(pair)#method) |> List.distinct;
                if (List.isEmpty(allowed) or method == Method.Options) Match.NotFound else Match.MethodNotAllowed(allowed)
        }

    ///
    /// リクエストで表を引く。知らないメソッド（"FOO"）はパスが合えば MethodNotAllowed、合わなければ NotFound。
    ///
    pub def matchRequest(routes: List[Route[ef]], request: HttpRequest): Match[ef] =
        match Method.parse(request#method) {
            case Some(method) => find(routes, method, request#path)
            case None         =>
                let allowed = allowedMethods(routes, request#path);
                if (List.isEmpty(allowed)) Match.NotFound else Match.MethodNotAllowed(allowed)
        }

    ///
    /// このパスで受けるメソッド（表の順、重複無し）。preflight の Allow-Methods と 405 の Allow に。
    ///
    pub def allowedMethods(routes: List[Route[ef]], path: String): List[Method] =
        candidates(routes, path) |> List.map(pair -> fst(pair)#method) |> List.distinct

    ///
    /// Account 以外の行を "/p/{projectSlug}" 付きで複製して後ろに足す。複製した行は params に projectSlug が入る。
    ///
    pub def withProjectPrefix(routes: List[Route[ef]]): List[Route[ef]] =
        let prefixed = routes
            |> List.filter(found -> found#engine != Some(Engine.Account))
            |> List.map(found ->
                let Pattern.Pattern(segments) = found#pattern;
                { pattern = Pattern.Pattern(Segment.Literal("p") :: Segment.Param(projectSlugParam()) :: segments) | found });
        routes ::: prefixed

    ///
    /// パスから取った params を RouteRequest に足す。同じ名前があればパスの物が勝つ（/p/ が Host より優先）。
    ///
    pub def withParams(params: Map[String, String], routeRequest: RouteRequest): RouteRequest =
        { params = Map.foldLeftWithKey((acc, name, value) -> Map.insert(name, value, acc), routeRequest#params, params) | routeRequest }

}
