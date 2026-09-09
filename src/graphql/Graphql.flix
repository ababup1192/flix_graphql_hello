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
/// WhyNot: DataFetcher に包むクロージャを IO 固定にするのは、リゾルバが graphql-java の Java コールバックの
/// 中で呼ばれ、そこから main のハンドラへは戻れないため。
///
mod Graphql {
    import graphql.ExecutionInput
    import graphql.scalars.ExtendedScalars
    import graphql.GraphQL
import graphql.analysis.MaxQueryDepthInstrumentation
    import graphql.ErrorClassification
    import graphql.ErrorType
    import graphql.GraphQLError
    import graphql.GraphQLException
    import graphql.TypeResolutionEnvironment
    import graphql.execution.DataFetcherResult
    import graphql.execution.UnknownOperationException
    import graphql.language.SourceLocation
    import graphql.parser.ParserOptions
    import graphql.schema.DataFetcher
    import graphql.schema.DataFetchingEnvironment
    import graphql.schema.FieldCoordinates
    import graphql.schema.GraphQLCodeRegistry
    import graphql.schema.GraphQLObjectType
    import graphql.schema.GraphQLSchema
    import graphql.schema.TypeResolver
    import graphql.schema.idl.RuntimeWiring
    import graphql.schema.idl.RuntimeWiring$Builder
    import graphql.schema.idl.SchemaGenerator
    import graphql.schema.idl.SchemaParser
    import graphql.schema.idl.TypeRuntimeWiring
    import java.lang.Class
    import java.lang.Object
    import java.lang.invoke.MethodHandles
    import java.lang.invoke.MethodType
    import java.util.ArrayList
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
        applyParserLimits();
        forM (
            types            <- Schema.collectTypes(schema);
            executableSchema <- makeExecutableSchema(Schema.renderSdl(schema, types), types)
        ) yield Engine.Engine(GraphQL.newGraphQL(executableSchema).instrumentation(new MaxQueryDepthInstrumentation(maxQueryDepth())).build())

    ///
    /// クエリの入れ子の上限。コンテンツ API は参照を辿るたびに SQL を出すので、互いに参照する型で深く掘られると 1 リクエストで SELECT が爆発する。
    /// 入れ子の型（blogs → nodes → sections → hero → link → ...）でも普段はこの半分で足りる。
    ///
    pub def maxQueryDepth(): Int32 = 15

    ///
    /// クエリのトークン数の上限。管理画面（elm-graphql）は variables を使わず引数を document に埋め込むので、
    /// 記事の本文（richText の doc）がそのままクエリに乗る。MCP と CLI も同じ形で大きな本文を送る。
    ///
    /// WhyNot: graphql-java 22.3 の既定（15,000）のままにしないのは、本文の上限（Http.maxBodyBytes() = 1 MiB）より先に当たり、
    /// 長い記事の保存だけが読めない理由で落ちるため。文字数の上限（maxCharacters）が 1 MiB のままなので、
    /// この値を上げてもクエリの大きさは本文の上限で頭打ちになる。
    ///
    /// WhyNot: 環境変数にしないのは、運用で回す値ではなく「本文の上限より先に当たらない」という 1 つの条件で決まるため。
    ///
    pub def maxQueryTokens(): Int32 = 100000

    ///
    /// graphql-java のパーサの上限を JVM 全体に入れる。クエリのパースが読むのは
    /// ParserOptions.getDefaultOperationParserOptions()（ParseAndValidate.parse）なので、そちらを差し替える。
    /// エンジンを組むたびに呼ぶ（同じ値を入れ直すだけ）。
    ///
    /// WhyNot: SDL 側（setDefaultSdlParserOptions）を触らないのは、SDL の既定が既に上限無しのため。
    ///
    /// WhyNot: 既定を transform で写して maxTokens だけ変えないのは、transform が java.util.function.Consumer を取り、
    /// Flix のラムダをそのまま渡せないため。graphql-java 22.3 の既定と同じ値を並べて組み直す。
    ///
    def applyParserLimits(): Unit \ IO =
        ParserOptions.setDefaultOperationParserOptions(
            ParserOptions.newParserOptions().captureIgnoredChars(false).captureSourceLocation(true).captureLineComments(false).maxCharacters(1048576).maxTokens(maxQueryTokens()).maxWhitespaceTokens(200000).maxRuleDepth(500).build())

    ///
    /// 組み立て済みのエンジンで 1 リクエストを実行する。MCP やテストのように「エンジンを持っている側」はこれを直に呼ぶ。
    ///
    /// WhyNot: `Graphql` effect をやめてこの関数（executor）を値で渡さないのは、handler が Main でもテストでも 1 段で
    /// 入れ子の問題が無く、値にしても多相化の手間が同じで得が無いため。
    ///
    pub def executeWith(engine: Engine, request: GraphqlRequest, context: Context): GraphqlResponse \ IO =
        let Engine.Engine(graphql) = engine;
        try {
            toResponse(graphql.execute(toExecutionInput(request, context)).toSpecification())
        } catch {
            case e: UnknownOperationException => invalidRequestResponse(e.getMessage())
        }

    ///
    /// クライアントの入力の誤りで graphql-java が例外を投げた時の応答。data は null、errors[] は path の無い 1 件で
    /// extensions.code は INVALID。HTTP は 200 のまま（GraphQL の実行まで届いた失敗は errors[] で返す決まり）。
    ///
    /// WhyNot: 例外をそのまま外へ出さないのは、HTTP の層で 500 と INTERNAL になり「サーバの障害」としてクライアントに
    /// 再試行を促すため。捕まえるのを UnknownOperationException（operationName が文書の操作と食い違う・複数の操作があるのに
    /// 選んでいない）に絞るのは、DB のようなサーバ起因の例外を 500 と INTERNAL のまま残すため。
    ///
    /// WhyNot: message を日本語に書き換えないのは、文書の誤りの文言は graphql-java の検査エラー（Validation error of type ...）も
    /// 英語のままクライアントに届いており、同じ層の物を揃えるため。
    ///
    def invalidRequestResponse(message: String): GraphqlResponse =
        { data = Value.Null,
          errors = Value.Obj(Map#{
              "message"    => Value.Str(message),
              "extensions" => Value.Obj(Map#{ "code" => Value.Str(ErrorCode.text(ErrorCode.Invalid)) })
          }) :: Nil }

    ///
    /// 組み立て済みのエンジンで `Graphql` effect を本物の実行に置き換えるハンドラ。
    ///
    pub def runWithEngine(engine: Engine, f: Unit -> a \ ef): a \ (ef - Graphql) + IO =
        run f() with handler Graphql {
            def execute(request, context, resume) = resume(executeWith(engine, request, context))
        }

    ///
    /// エンジンの要らない道（/health など）で `Graphql` effect を剥がすハンドラ。実行を求められたらエラーの応答を返す。
    ///
    pub def runWithoutEngine(f: Unit -> a \ ef): a \ ef - Graphql =
        run f() with handler Graphql {
            def execute(_request, _context, resume) =
                resume({ data = Value.Null, errors = Value.Obj(Map#{ "message" => Value.Str("この経路に GraphQL のエンジンはありません") }) :: Nil })
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
        // variables は Java の Map に、context は root の (Context, ()) に載せる
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
            // SDL をパースして型の登録簿にする
            let registry = new SchemaParser().parse(sdl);
            // フィールドごとの DataFetcher と、scalar / union / interface の配線を RuntimeWiring にまとめる
            let builder = RuntimeWiring.newRuntimeWiring().codeRegistry(wireDataFetchers(types));
            wireTypes(builder, types);
            // 登録簿と配線を突き合わせて実行できるスキーマにする（型検査もここ）
            Ok(new SchemaGenerator().makeExecutableSchema(registry, builder.build()))
        } catch {
            case e: GraphQLException => Err("スキーマを組み立てられません: ${e.getMessage()}")
        }

    ///
    /// 全オブジェクト型の全フィールドに DataFetcher を配線した GraphQLCodeRegistry を作る。
    ///
    def wireDataFetchers(types: List[TypeDecl]): GraphQLCodeRegistry \ IO =
        let codeRegistryBuilder = GraphQLCodeRegistry.newCodeRegistry();
        List.forEach(decl -> match decl {
            case TypeDecl.ObjectDecl(object) => List.forEach(field ->
                discard codeRegistryBuilder.dataFetcher(FieldCoordinates.coordinates(object#name, field#info#name), toDataFetcher(field)),
                object#fields)
            case _ => ()
        }, types);
        codeRegistryBuilder.build()

    ///
    /// JSON scalar の実装と、union / interface の TypeResolver を RuntimeWiring の builder に登録する。
    ///
    def wireTypes(builder: RuntimeWiring$Builder, types: List[TypeDecl]): Unit \ IO =
        List.forEach(decl -> match decl {
            case TypeDecl.ScalarDecl("JSON")       => discard builder.scalar(ExtendedScalars.Json)
            case TypeDecl.UnionDecl(union)         => registerTypeResolver(builder, union#name)
            case TypeDecl.InterfaceDecl(interface) => registerTypeResolver(builder, interface#name)
            case _                                 => ()
        }, types)

    ///
    /// union / interface に TypeResolver を登録する。
    ///
    /// WhyNot: GraphQLCodeRegistry.Builder.typeResolver に登録しないのは、graphql-java 22 の SchemaTypeChecker が
    /// RuntimeWiring 側の TypeResolver しか見ず「There is no type resolver defined for」で止まるため。
    /// RuntimeWiring.Builder.type を直接呼ばないのは `type` が Flix の予約語でパースできないため、
    /// WiringFactory の無名クラスを使わないのは Flix 0.75.3 がオーバーロードを名前だけで選び
    /// 「Duplicate method name」の内部エラーになるため。MethodHandle で `type` を呼ぶ。
    ///
    def registerTypeResolver(builder: RuntimeWiring$Builder, typeName: String): Unit \ IO =
        let typeWiring = TypeRuntimeWiring.newTypeWiring(typeName).typeResolver(typeResolver()).build();
        let builderClass = Class.forName("graphql.schema.idl.RuntimeWiring$Builder");
        let wiringClass = Class.forName("graphql.schema.idl.TypeRuntimeWiring");
        let handle = MethodHandles.lookup().findVirtual(builderClass, "type", MethodType.methodType(builderClass, wiringClass));
        let args = new ArrayList();
        let builderObject: Object = checked_cast(builder);
        let wiringObject: Object = checked_cast(typeWiring);
        discard args.add(builderObject);
        discard args.add(wiringObject);
        discard handle.invokeWithArguments(args)

    ///
    /// union / interface の値の具体型を決める。source の箱に付いた型名のタグ（Out.taggedObj）を読む。
    /// タグが無ければ（手書きの Out.union で taggedObj を使わなかった等）null を返し、graphql-java が
    /// 「Could not determine the exact type of」のエラーにする。
    ///
    def typeResolver(): TypeResolver \ IO =
        new TypeResolver {
            def getType(_this: TypeResolver, env: TypeResolutionEnvironment): GraphQLObjectType \ IO =
                let (tag, _) = JavaValue.untag(JavaValue.Boxed.Boxed(env.getObject()));
                env.getSchema().getObjectType(Option.getWithDefault("", tag))
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
    /// message は人が読む文、extensions は機械が読む物（code と、分類ごとの追加）。
    /// path と locations は env から取り、graphql-java が付ける物と同じ形にする。
    ///
    /// WhyNot: GraphqlErrorBuilder を使わないのは、message(String, Object...) の可変長引数を
    /// Flix から渡せないため。GraphQLError を直接実装する。
    ///
    def toErrorResult(env: DataFetchingEnvironment, error: FieldError): Object \ IO =
        let path: JList[Object] = env.getExecutionStepInfo().getPath().toList();
        let locations: JList[SourceLocation] = Adaptor.toList(env.getField().getSourceLocation() :: Nil);
        let message = FieldError.message(error);
        let extensions: JMap[String, Object] = unchecked_cast(JavaValue.toObject(Value.Obj(FieldError.extensions(error))) as JMap[String, Object]);
        let graphqlError = new GraphQLError {
            def getMessage(_this: GraphQLError): String = message
            def getLocations(_this: GraphQLError): JList[SourceLocation] = locations
            def getErrorType(_this: GraphQLError): ErrorClassification = checked_cast(ErrorType.DataFetchingException)
            def getPath(_this: GraphQLError): JList[Object] = path
            def getExtensions(_this: GraphQLError): JMap[String, Object] = extensions
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
