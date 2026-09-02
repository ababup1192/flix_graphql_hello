///
/// graphql-java 込みのテストで使う共通の道具。
///
mod GraphqlTestKit {

    ///
    /// variables も operationName も無い、クエリ文字列だけのリクエスト。
    ///
    pub def queryOnly(queryText: String): GraphqlRequest =
        { queryText = queryText, variables = Map.empty(), operationName = None }

    ///
    /// エンジンを組み立ててリクエストを 1 つ流し、GraphqlResponse を返す。組み立てに失敗すれば Err。
    ///
    pub def executeOnce(schema: Schema, request: GraphqlRequest): Result[String, GraphqlResponse] \ IO =
        Graphql.buildEngine(schema)
            |> Result.map(engine -> Graphql.runWithEngine(engine, () -> Graphql.execute(request, Context.anonymous())))

    ///
    /// クエリ文字列だけで実行し、(data, 先頭の errors[].message) にまとめる。
    ///
    pub def executeQuery(schema: Schema, queryText: String): Result[String, (Value, Option[String])] \ IO =
        executeOnce(schema, queryOnly(queryText)) |> Result.map(response -> (response#data, firstMessage(response)))

    ///
    /// errors の先頭の "message" を文字列で取り出す。errors が空か message が文字列でなければ None。
    ///
    pub def firstMessage(response: GraphqlResponse): Option[String] =
        List.head(response#errors) |> Option.map(Value.field("message")) |> Option.flatMap(Value.asStr)

    ///
    /// アプリのスキーマ（AppSchema）を、メモリ上のカウンタ（初期値 initial）で組み立てる。
    ///
    pub def appSchema(initial: Int32): Schema =
        AppSchema.make(f -> CounterFake.runWithMemory(initial, f))

    ///
    /// Query だけのスキーマ。
    ///
    pub def queryOnlySchema(fields: List[Field[Unit]]): Schema =
        Schema.make(Schema.objectType("Query", () -> fields), None)

}
