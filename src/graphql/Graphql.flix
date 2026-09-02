///
/// リゾルバに渡される引数。GraphQL の引数名 → 値。
///
pub type alias Args = Map[String, Value]

///
/// クエリを実行した結果。data はクエリの形どおりのオブジェクト、
/// errors は GraphQL 仕様どおりのエラーオブジェクト（message などを持つ Obj）。
///
pub type alias GraphqlResponse = { data = Value, errors = List[Value] }

///
/// GraphQL over HTTP の 1 リクエスト。
/// query はクエリ文字列、variables はクエリの $変数へ渡す値、
/// operationName はクエリに複数の操作があるときに実行する物の名前。
///
pub type alias GraphqlRequest = { queryText = String, variables = Map[String, Value], operationName = Option[String] }

///
/// GraphQL のクエリを実行する effect。
/// ロジック側はこの effect だけに依存し、graphql-java を使うかどうかはハンドラが決める。
///
pub eff Graphql {
    ///
    /// リクエスト（クエリ・variables・operationName）を context 付きで実行する。
    /// context はリクエスト単位の情報（認証済みユーザなど）で、すべてのリゾルバに届く。
    ///
    def execute(request: GraphqlRequest, context: Context): GraphqlResponse
}

///
/// graphql-java でスキーマを組み立てて実行する。
/// スキーマは Schema の値から SDL と DataFetcher の両方を導くので、起動時の照合は要らない。
///
/// WhyNot: リゾルバに任意の代数的 effect を許さないのは、リゾルバが graphql-java の Java コールバックの
/// 中で呼ばれ、そこからは Flix のハンドラへ戻れないため。IO だけがコールバック内でも動く。
///
mod Graphql {
    import graphql.ExecutionInput
    import graphql.GraphQL
    import graphql.ErrorClassification
    import graphql.ErrorType
    import graphql.GraphQLError
    import graphql.GraphQLException
    import graphql.execution.DataFetcherResult
    import graphql.language.SourceLocation
    import graphql.schema.DataFetcher
    import graphql.schema.DataFetchingEnvironment
    import graphql.schema.FieldCoordinates
    import graphql.schema.GraphQLCodeRegistry
    import graphql.schema.GraphQLSchema
    import graphql.schema.idl.RuntimeWiring
    import graphql.schema.idl.SchemaGenerator
    import graphql.schema.idl.SchemaParser
    import java.lang.Object
    import java.util.{List => JList}
    import java.util.{Map => JMap}

    ///
    /// スキーマから組み立てた実行エンジン。graphql-java の GraphQL インスタンスを包む。
    ///
    pub enum Engine {
        /// 組み立て済みの graphql-java エンジン
        case Engine(GraphQL)
    }

    ///
    /// Schema の値から graphql-java のエンジンを組み立てる。
    /// 同名で中身の違うオブジェクト型があるか、生成した SDL を graphql-java が受け付けなければ Err。
    ///
    /// WhyNot: data fetcher の配線に定番の RuntimeWiring.Builder.type を使わないのは、
    /// `type` が Flix の予約語でメソッド呼び出しがパースできないため。
    /// 同じ配線ができる GraphQLCodeRegistry 経由にしている。
    ///
    pub def buildEngine(schema: Schema): Result[String, Engine] \ IO =
        forM (
            types            <- Schema.collectTypes(schema);
            executableSchema <- makeExecutableSchema(Schema.renderSdl(schema, types), types)
        ) yield Engine.Engine(GraphQL.newGraphQL(executableSchema).build())

    ///
    /// 組み立て済みのエンジンで `Graphql` effect を本物の実行に置き換えるハンドラ。
    ///
    pub def runWithEngine(engine: Engine, f: Unit -> a \ ef): a \ (ef - Graphql) + IO =
        let Engine.Engine(graphql) = engine;
        run f() with handler Graphql {
            def execute(request, context, resume) =
                resume(toResponse(graphql.execute(toExecutionInput(request, context)).toSpecification()))
        }

    ///
    /// GraphqlRequest を graphql-java の ExecutionInput に組み立てる。
    /// context は root オブジェクトに (Context, ()) として載せ、ルート型のフィールドが source として受け取る。
    /// operationName は Some のときだけ渡す。
    ///
    /// WhyNot: context を graphql-java の GraphQLContext に載せないのは、取り出す get がジェネリクスで
    /// Flix から型を決めにくいため。source に相乗りさせれば Flix の値だけで往復できる。
    ///
    /// WhyNot: クエリ文字列を Builder.query で渡さないのは、`query` が Flix の予約語で
    /// メソッド呼び出しがパースできないため。文字列を受け取る newExecutionInput(String) で渡す。
    ///
    /// WhyNot: variables を Adaptor.toMap で直接 Map[String, Object] にしないのは、
    /// Value.Obj を JavaValue.toObject に通せば同じ java.util.Map が出て、変換を 1 か所に保てるため。
    ///
    def toExecutionInput(request: GraphqlRequest, context: Context): ExecutionInput \ IO =
        let variables: JMap[String, Object] = unchecked_cast(JavaValue.toObject(Value.Obj(request#variables)) as JMap[String, Object]);
        let root = JavaValue.toObjectOfBoxed(JavaValue.box((context, ())));
        let builder = ExecutionInput.newExecutionInput(request#queryText).variables(variables).root(root);
        match request#operationName {
            case Some(name) => builder.operationName(name).build()
            case None       => builder.build()
        }

    ///
    /// SDL をパースし、全オブジェクト型の全フィールドに DataFetcher を配線した GraphQLSchema を作る。
    /// graphql-java がパースや型検査で投げた例外はメッセージにして Err で返す。
    ///
    def makeExecutableSchema(sdl: String, types: List[TypeDecl]): Result[String, GraphQLSchema] \ IO =
        try {
            let registry = new SchemaParser().parse(sdl);
            let codeRegistryBuilder = GraphQLCodeRegistry.newCodeRegistry();
            List.forEach(decl -> match decl {
                case TypeDecl.EnumDecl(_, _)             => ()
                case TypeDecl.ObjectDecl(typeName, fields) => List.forEach(field ->
                    discard codeRegistryBuilder.dataFetcher(FieldCoordinates.coordinates(typeName, field#info#name), toDataFetcher(field)),
                    fields)
            }, types);
            let wiring = RuntimeWiring.newRuntimeWiring().codeRegistry(codeRegistryBuilder.build()).build();
            Ok(new SchemaGenerator().makeExecutableSchema(registry, wiring))
        } catch {
            case e: GraphQLException => Err("スキーマを組み立てられません: ${e.getMessage()}")
        }

    ///
    /// フィールドを graphql-java の DataFetcher に包む。
    /// source（親が箱詰めした (Context, 値)）と引数を渡し、戻りの箱を開いて返す。
    /// Err は DataFetcherResult のエラーにして返す。FieldError から GraphQL のエラーへの変換はここ 1 か所。
    ///
    /// WhyNot: Err を例外で投げないのは、graphql-java が "Exception while fetching data (/path) : " を
    /// message の前に付けてしまい、リゾルバの文言がそのままクライアントに届かないため。
    /// DataFetcherResult なら message はそのままで、path と locations は graphql-java が付ける。
    ///
    def toDataFetcher(field: ErasedField): DataFetcher[Object] \ IO =
        new DataFetcher[Object] {
            def get(_this: DataFetcher[Object], env: DataFetchingEnvironment): Object \ IO =
                match (field#fetch)(JavaValue.Boxed.Boxed(env.getSource()), JavaValue.fromArguments(env.getArguments())) {
                    case Ok(boxed)  => JavaValue.toObjectOfBoxed(boxed)
                    case Err(error) => toErrorResult(env, error)
                }
        }

    ///
    /// FieldError を、値 null とエラー 1 つを持つ DataFetcherResult にする。
    /// path と locations は env から取り、graphql-java が付ける物と同じ形にする。
    ///
    /// WhyNot: GraphqlErrorBuilder を使わないのは、message(String, Object...) の可変長引数を
    /// Flix から渡せないため。GraphQLError を直接実装する。
    ///
    def toErrorResult(env: DataFetchingEnvironment, error: FieldError): Object \ IO =
        let path: JList[Object] = env.getExecutionStepInfo().getPath().toList();
        let locations: JList[SourceLocation] = Adaptor.toList(env.getField().getSourceLocation() :: Nil);
        let graphqlError = new GraphQLError {
            def getMessage(_this: GraphQLError): String = error
            def getLocations(_this: GraphQLError): JList[SourceLocation] = locations
            def getErrorType(_this: GraphQLError): ErrorClassification = checked_cast(ErrorType.DataFetchingException)
            def getPath(_this: GraphQLError): JList[Object] = path
        };
        unchecked_cast(DataFetcherResult.newResult().error(graphqlError).build() as Object)

    ///
    /// ExecutionResult.toSpecification() の Map を GraphqlResponse へ変換する。
    ///
    /// WhyNot: ExecutionResult.getData() を使わないのは、戻り型がジェネリクスで
    /// Flix が型を決められないため。戻り型が具象の toSpecification() で受ける。
    ///
    def toResponse(specification: JMap[String, Object]): GraphqlResponse \ IO =
        let specificationObject: Object = checked_cast(specification);
        let whole = JavaValue.fromObject(specificationObject);
        { data = Value.field("data", whole), errors = toErrors(whole) }

    ///
    /// レスポンス全体から errors の一覧を取り出す。errors が無ければ空。
    ///
    def toErrors(whole: Value): List[Value] = match Value.field("errors", whole) {
        case Value.List(items) => items
        case _                 => Nil
    }

}
