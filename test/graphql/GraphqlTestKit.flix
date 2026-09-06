///
/// graphql-java 込みのテストで使う共通の道具。
///
mod GraphqlTestKit {
    import java.util.concurrent.atomic.AtomicInteger

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
    /// リクエストを 1 つ流し、(data, 先頭の errors[].message) にまとめる。
    ///
    pub def executeRequest(schema: Schema, request: GraphqlRequest): Result[String, (Value, Option[String])] \ IO =
        executeOnce(schema, request) |> Result.map(summarize)

    ///
    /// クエリ文字列だけで実行し、(data, 先頭の errors[].message) にまとめる。
    ///
    pub def executeQuery(schema: Schema, queryText: String): Result[String, (Value, Option[String])] \ IO =
        executeRequest(schema, queryOnly(queryText))

    ///
    /// 組み立て済みのエンジンにクエリを 1 つ流し、(data, 先頭の errors[].message) にまとめる。
    ///
    pub def askEngine(engine: Graphql.Engine, queryText: String): (Value, Option[String]) \ IO =
        Graphql.runWithEngine(engine, () -> Graphql.execute(queryOnly(queryText), Context.anonymous())) |> summarize

    ///
    /// executeQuery が Err（エンジンが組めない）なのはテストの前提が壊れているので止める。
    ///
    pub def ask(schema: Schema, queryText: String): (Value, Option[String]) \ IO = match executeQuery(schema, queryText) {
        case Ok(found)    => found
        case Err(message) => bug!("graphql: ${message}")
    }

    ///
    /// (data, 先頭の errors[].message)。
    ///
    pub def summarize(response: GraphqlResponse): (Value, Option[String]) =
        (response#data, firstMessage(response))

    ///
    /// errors の先頭の "message" を文字列で取り出す。errors が空か message が文字列でなければ None。
    ///
    pub def firstMessage(response: GraphqlResponse): Option[String] =
        firstErrorField("message", response) |> Value.asStr

    ///
    /// errors の先頭の名前付きフィールド（path / locations など）。無ければ Null。
    ///
    pub def firstErrorField(name: String, response: GraphqlResponse): Value =
        List.head(response#errors) |> Option.map(Value.field(name)) |> Option.getWithDefault(Value.Null)

    ///
    /// graphql-java の検証で落ちたか（message が "Validation error" で始まる）。
    ///
    pub def isValidationError(message: Option[String]): Bool =
        message |> Option.map(String.startsWith(prefix = "Validation error")) |> Option.getWithDefault(false)

    ///
    /// アプリのスキーマ（AppSchema）を、メモリ上のカウンタ（初期値 initial）で組み立てる。
    /// カウンタは 1 つのスキーマの中の全 fetch で共有される。
    ///
    pub def appSchema(initial: Int32): Schema \ IO =
        let cell = new AtomicInteger(initial);
        AppSchema.make(f -> CounterFake.runWithCell(cell, f))

    ///
    /// Query だけの、IO しか使わないスキーマ。
    ///
    pub def queryOnlySchema(fields: List[Field[Unit, IO]]): Schema =
        Schema.make(Schema.objectType("Query", () -> fields), None, Runner.io())

}
