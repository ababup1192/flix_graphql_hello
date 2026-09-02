///
/// テスト用の Graphql effect の偽ハンドラ。エンジン無しで Server などを確かめる。
///
mod GraphqlFake {

    ///
    /// Graphql effect を「受け取ったリクエストをそのまま data に入れて返す」ハンドラで剥がす。
    /// data は { "query": Str, "variables": Obj, "operationName": Str か Null }。
    ///
    pub def runWithEcho(f: Unit -> a \ ef): a \ ef - Graphql =
        run f() with handler Graphql {
            def execute(request, _context, resume) =
                resume({ data = echo(request), errors = Nil })
        }

    ///
    /// GraphqlRequest を data の形の Value にする。
    ///
    pub def echo(request: GraphqlRequest): Value =
        Value.Obj(Map#{
            "query"         => Value.Str(request#queryText),
            "variables"     => Value.Obj(request#variables),
            "operationName" => request#operationName |> Option.map(Value.Str) |> Option.getWithDefault(Value.Null)
        })

    ///
    /// Graphql effect を「リクエストを見ずに固定の GraphqlResponse を返す」ハンドラで剥がす。
    ///
    pub def runWithFixedResponse(response: GraphqlResponse, f: Unit -> a \ ef): a \ ef - Graphql =
        run f() with handler Graphql {
            def execute(_request, _context, resume) = resume(response)
        }

}
