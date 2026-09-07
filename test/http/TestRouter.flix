///
/// Router: パターンの解析と往復、表の引き当て（一致・params・404・405 の Allow）、/p/{projectSlug} の複製。DB もソケットも無し。
///
mod TestRouter {

    /// ボディに目印だけ返す handler。
    def reply(text: String): Handler[{}] =
        _ -> { status = 200, headers = Nil, body = text }

    ///
    /// 見本の表。同じパスに複数のメソッド、Param 付き、Account の行、POST を 2 行（Allow の重複を確かめる）。
    ///
    def table(): List[Route[{}]] =
        Router.route(Method.Post, "/graphql",           Some(Engine.Content), reply("content-post")) ::
        Router.route(Method.Get,  "/graphql",           Some(Engine.Content), reply("content-get")) ::
        Router.route(Method.Post, "/graphql",           Some(Engine.Content), reply("shadowed")) ::
        Router.route(Method.Post, "/account/graphql",   Some(Engine.Account), reply("account")) ::
        Router.route(Method.Get,  "/api/{typeApiId}/{entryId}", Some(Engine.Content), reply("entry")) ::
        Router.route(Method.Get,  "/health",            None,                 reply("health")) :: Nil

    /// 一致した行の "GET /path" と params。一致していなければ bug!。
    def foundOf(matched: Match[ef]): (String, Map[String, String]) = match matched {
        case Match.Found(found, params) => (Router.describeAll(found :: Nil) |> List.join(""), params)
        case _                          => bug!("一致していません")
    }

    /// 405 の Allow に並ぶメソッド。405 でなければ bug!。
    def allowedOf(matched: Match[ef]): List[Method] = match matched {
        case Match.MethodNotAllowed(allowed) => allowed
        case _                               => bug!("405 ではありません")
    }

    /// 404 か。
    def isNotFound(matched: Match[ef]): Bool = match matched {
        case Match.NotFound => true
        case _              => false
    }

    /// 一致した行の handler を呼んだボディ。
    def bodyOf(matched: Match[ef]): String \ ef = match matched {
        case Match.Found(found, params) => (found#handle)({ request = { version = "HTTP/1.1", method = "GET", path = "/", headers = Nil, body = "" }, params = params, credential = Credential.Missing })#body
        case _                          => bug!("一致していません")
    }

    // ---- parsePattern / describe ----

    /// "/" は空、Literal と {name} の Param を区切りごとに読む。
    @Test
    def testRouterParsePattern(): Unit \ Assert =
        Assert.assertEq(
            expected = (Ok(Pattern.Pattern(Nil)), Ok(Pattern.Pattern(Segment.Literal("admin") :: Segment.Literal("graphql") :: Nil)),
                        Ok(Pattern.Pattern(Segment.Literal("p") :: Segment.Param("projectSlug") :: Segment.Literal("graphql") :: Nil))),
            (Router.parsePattern("/"), Router.parsePattern("/admin/graphql"), Router.parsePattern("/p/{projectSlug}/graphql")))

    /// / で始まらない、空の区切り（// と末尾の /）、括弧の片方だけ・空の名前、同じ名前の Param は Err。
    @Test
    def testRouterParsePatternRejects(): Unit \ Assert =
        Assert.assertEq(expected = List#{false, false, false, false, false, false, false},
            List#{"graphql", "//x", "/x/", "/{}", "/{a", "/{a}b", "/{a}/{a}"} |> List.map(text -> Router.parsePattern(text) |> Result.isOk))

    /// describe は parsePattern と往復する。
    @Test
    def testRouterDescribeRoundTrip(): Unit \ Assert =
        let texts = List#{"/", "/health", "/p/{projectSlug}/admin/graphql", "/api/{typeApiId}/{entryId}"};
        Assert.assertEq(expected = texts |> List.map(Ok), texts |> List.map(text -> Router.parsePattern(text) |> Result.map(Router.describe)))

    // ---- find ----

    /// パスとメソッドが合う最初の行が勝ち（同じ POST /graphql の 2 行目は影）。Param は params に入る。
    @Test
    def testRouterFindFirstMatch(): Unit \ Assert =
        Assert.assertEq(
            expected = (("POST /graphql", Map.empty()), "content-post", ("GET /api/{typeApiId}/{entryId}", Map#{ "typeApiId" => "blogs", "entryId" => "e1" }), "entry"),
            (Router.find(table(), Method.Post, "/graphql") |> foundOf,
             Router.find(table(), Method.Post, "/graphql") |> bodyOf,
             Router.find(table(), Method.Get, "/api/blogs/e1") |> foundOf,
             Router.find(table(), Method.Get, "/api/blogs/e1") |> bodyOf))

    /// クエリ文字列は落として当てる。末尾の / は別のパス、Param は空を取らない、/ で始まらないパスは当たらない。
    @Test
    def testRouterFindPathShape(): Unit \ Assert =
        Assert.assertEq(expected = (("GET /health", Map.empty()), true, true, true, true),
            (Router.find(table(), Method.Get, "/health?probe=1") |> foundOf,
             Router.find(table(), Method.Get, "/health/") |> isNotFound,
             Router.find(table(), Method.Get, "/api/blogs/") |> isNotFound,
             Router.find(table(), Method.Get, "/api//e1") |> isNotFound,
             Router.find(table(), Method.Get, "health") |> isNotFound))

    /// 無いパスは NotFound。
    @Test
    def testRouterFindNotFound(): Unit \ Assert =
        Assert.assertEq(expected = (true, true, true),
            (Router.find(table(), Method.Get, "/nope") |> isNotFound,
             Router.find(table(), Method.Get, "/") |> isNotFound,
             Router.find(table(), Method.Get, "/api/blogs") |> isNotFound))

    /// パスだけ合えば MethodNotAllowed。Allow は表の順で重複無し（POST, GET）。OPTIONS は 405 にせず NotFound。
    @Test
    def testRouterFindMethodNotAllowed(): Unit \ Assert =
        Assert.assertEq(expected = (Method.Post :: Method.Get :: Nil, Method.Get :: Nil, true),
            (Router.find(table(), Method.Put, "/graphql") |> allowedOf,
             Router.find(table(), Method.Post, "/health") |> allowedOf,
             Router.find(table(), Method.Options, "/graphql") |> isNotFound))

    /// リクエストで引く: 知らないメソッドはパスが合えば 405、合わなければ 404。
    @Test
    def testRouterMatchRequestUnknownMethod(): Unit \ Assert =
        let request = (method, path) -> { version = "HTTP/1.1", method = method, path = path, headers = Nil, body = "" };
        Assert.assertEq(expected = (Method.Post :: Method.Get :: Nil, true, ("GET /health", Map.empty())),
            (Router.matchRequest(table(), request("FOO", "/graphql")) |> allowedOf,
             Router.matchRequest(table(), request("FOO", "/nope")) |> isNotFound,
             Router.matchRequest(table(), request("GET", "/health")) |> foundOf))

    /// allowedMethods は preflight 用。表の順で重複無し、無いパスは空。
    @Test
    def testRouterAllowedMethods(): Unit \ Assert =
        Assert.assertEq(expected = (Method.Post :: Method.Get :: Nil, Method.Get :: Nil, Nil),
            (Router.allowedMethods(table(), "/graphql?x=1"), Router.allowedMethods(table(), "/api/a/b"), Router.allowedMethods(table(), "/nope")))

    // ---- withProjectPrefix ----

    /// Account 以外の行が /p/{projectSlug} 付きで後ろに複製される。
    @Test
    def testRouterWithProjectPrefixDescribe(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
                "POST /graphql", "GET /graphql", "POST /graphql", "POST /account/graphql", "GET /api/{typeApiId}/{entryId}", "GET /health",
                "POST /p/{projectSlug}/graphql", "GET /p/{projectSlug}/graphql", "POST /p/{projectSlug}/graphql", "GET /p/{projectSlug}/api/{typeApiId}/{entryId}", "GET /p/{projectSlug}/health" },
            table() |> Router.withProjectPrefix |> Router.describeAll)

    /// 複製した行は params に projectSlug が入り、元の handler に届く。Account は複製されないので 404。
    @Test
    def testRouterWithProjectPrefixParams(): Unit \ Assert =
        let prefixed = table() |> Router.withProjectPrefix;
        Assert.assertEq(
            expected = (("GET /p/{projectSlug}/api/{typeApiId}/{entryId}", Map#{ "projectSlug" => "shop", "typeApiId" => "blogs", "entryId" => "e1" }), "entry", true),
            (Router.find(prefixed, Method.Get, "/p/shop/api/blogs/e1") |> foundOf,
             Router.find(prefixed, Method.Get, "/p/shop/api/blogs/e1") |> bodyOf,
             Router.find(prefixed, Method.Post, "/p/shop/account/graphql") |> isNotFound))

    /// withParams はパスの params を足し、同じ名前はパスが勝つ。
    @Test
    def testRouterWithParams(): Unit \ Assert =
        let routeRequest = { request = { version = "HTTP/1.1", method = "GET", path = "/", headers = Nil, body = "" }, params = Map#{ "projectSlug" => "from-host", "other" => "x" }, credential = Credential.Missing };
        Assert.assertEq(expected = Map#{ "projectSlug" => "shop", "other" => "x", "entryId" => "e1" },
            Router.withParams(Map#{ "projectSlug" => "shop", "entryId" => "e1" }, routeRequest)#params)

    /// Method の綴りは大文字だけ受け、Allow の並びは ", " 区切り。
    @Test
    def testRouterMethodParseAndJoin(): Unit \ Assert =
        Assert.assertEq(expected = (Some(Method.Get), Some(Method.Options), None, None, "POST, GET, OPTIONS"),
            (Method.parse("GET"), Method.parse("OPTIONS"), Method.parse("get"), Method.parse("FOO"), Method.join(Method.Post :: Method.Get :: Method.Options :: Nil)))

}
