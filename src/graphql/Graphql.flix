///
/// リゾルバに渡される引数。GraphQL の引数名 → 値。
///
pub type alias Args = Map[String, Value]

///
/// リゾルバ。引数を受けてフィールドの値を返す。Err のメッセージは GraphQL のエラーとして返る。
/// 純粋な計算は effect 無しで書き、登録時に checked_ecast で IO へ広げる。
/// 状態は SQLite など外部に置き、IO で読み書きする。
///
/// エラーメッセージの言語: クライアントに返る文字列（リゾルバの Err、Server の 400 ボディ）は英語、
/// 起動時に運用者が読む文字列（buildEngine / mergeResolvers の Err、Main の println）は日本語。
///
/// WhyNot: 任意の代数的 effect を許さないのは、リゾルバが graphql-java の Java コールバックの
/// 中で呼ばれ、そこからは Flix のハンドラへ戻れないため。IO だけがコールバック内でも動く。
///
pub type alias Resolver = Args -> Result[String, Value] \ IO

///
/// スキーマ。SDL と、（型名, フィールド名）ごとのリゾルバ。
///
pub type alias Schema = { sdl = String, resolvers = Map[(String, String), Resolver] }

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
    /// リクエスト（クエリ・variables・operationName）を実行する。
    ///
    def execute(request: GraphqlRequest): GraphqlResponse
}

mod Graphql {
    import graphql.ExecutionInput
    import graphql.GraphQL
    import graphql.GraphQLException
    import graphql.schema.DataFetcher
    import graphql.schema.DataFetchingEnvironment
    import graphql.schema.FieldCoordinates
    import graphql.schema.GraphQLCodeRegistry
    import graphql.schema.GraphQLFieldDefinition
    import graphql.schema.GraphQLObjectType
    import graphql.schema.GraphQLSchema
    import graphql.schema.idl.RuntimeWiring
    import graphql.schema.idl.SchemaGenerator
    import graphql.schema.idl.SchemaParser
    import java.lang.Object
    import java.util.{Map => JMap}
    import java.util.Objects

    ///
    /// スキーマから組み立てた実行エンジン。graphql-java の GraphQL インスタンスを包む。
    ///
    pub enum Engine {
        /// 組み立て済みの graphql-java エンジン
        case Engine(GraphQL)
    }

    ///
    /// モジュールごとのリゾルバ一覧を 1 つの Map にまとめる。
    /// 同じ（型名, フィールド名）が 2 つ以上の一覧にあれば、そのキーを列挙した Err。
    ///
    /// WhyNot: Map.union で済ませないのは、左優先で重複キーが黙って落ち、
    /// 別モジュールのリゾルバが登録されたつもりで消えるため。
    ///
    pub def mergeResolvers(groups: List[Map[(String, String), Resolver]]): Result[String, Map[(String, String), Resolver]] =
        let (merged, duplicated) = List.foldLeft((state, group) -> {
            let (accumulated, seenTwice) = state;
            let overlap = Map.keysOf(group) |> Set.filter(coordinates -> Map.memberOf(coordinates, accumulated));
            (Map.union(accumulated, group), Set.union(seenTwice, overlap))
        }, (Map.empty(), Set.empty()), groups);
        if (Set.isEmpty(duplicated))
            Ok(merged)
        else
            Err("リゾルバのキーが重複しています: [${showCoordinates(Set.toList(duplicated))}]")

    ///
    /// SDL とリゾルバから graphql-java のエンジンを組み立てる。
    /// SDL が壊れているか、リゾルバとスキーマのフィールドが食い違っていれば Err。
    ///
    /// WhyNot: data fetcher の配線に定番の RuntimeWiring.Builder.type を使わないのは、
    /// `type` が Flix の予約語でメソッド呼び出しがパースできないため。
    /// 同じ配線ができる GraphQLCodeRegistry 経由にしている。
    ///
    pub def buildEngine(schema: Schema): Result[String, Engine] \ IO =
        forM (
            executableSchema <- makeExecutableSchema(schema);
            _ <- validateResolvers(executableSchema, schema#resolvers)
        ) yield Engine.Engine(GraphQL.newGraphQL(executableSchema).build())

    ///
    /// 組み立て済みのエンジンで `Graphql` effect を本物の実行に置き換えるハンドラ。
    ///
    pub def runWithEngine(engine: Engine, f: Unit -> a \ ef): a \ (ef - Graphql) + IO =
        let Engine.Engine(graphql) = engine;
        run f() with handler Graphql {
            def execute(request, resume) =
                resume(toResponse(graphql.execute(toExecutionInput(request)).toSpecification()))
        }

    ///
    /// GraphqlRequest を graphql-java の ExecutionInput に組み立てる。
    /// operationName は Some のときだけ渡す（None を null で渡すのと同じ意味だが、null を作らずに済む）。
    ///
    /// WhyNot: クエリ文字列を Builder.query で渡さないのは、`query` が Flix の予約語で
    /// メソッド呼び出しがパースできないため。文字列を受け取る newExecutionInput(String) で渡す。
    ///
    /// WhyNot: variables を Adaptor.toMap で直接 Map[String, Object] にしないのは、
    /// Value.Obj を JavaValue.toObject に通せば同じ java.util.Map が出て、変換を 1 か所に保てるため。
    ///
    def toExecutionInput(request: GraphqlRequest): ExecutionInput \ IO =
        let variables: JMap[String, Object] = unchecked_cast(JavaValue.toObject(Value.Obj(request#variables)) as JMap[String, Object]);
        let builder = ExecutionInput.newExecutionInput(request#queryText).variables(variables);
        match request#operationName {
            case Some(name) => builder.operationName(name).build()
            case None       => builder.build()
        }

    ///
    /// SDL をパースし、リゾルバを配線した GraphQLSchema を作る。
    /// graphql-java がパースや型検査で投げた例外はメッセージにして Err で返す。
    ///
    def makeExecutableSchema(schema: Schema): Result[String, GraphQLSchema] \ IO =
        try {
            let registry = new SchemaParser().parse(schema#sdl);
            let codeRegistryBuilder = GraphQLCodeRegistry.newCodeRegistry();
            Map.forEach((coordinates, resolver) -> {
                let (typeName, fieldName) = coordinates;
                discard codeRegistryBuilder.dataFetcher(FieldCoordinates.coordinates(typeName, fieldName), toDataFetcher(resolver))
            }, schema#resolvers);
            let wiring = RuntimeWiring.newRuntimeWiring().codeRegistry(codeRegistryBuilder.build()).build();
            Ok(new SchemaGenerator().makeExecutableSchema(registry, wiring))
        } catch {
            case e: GraphQLException => Err("スキーマを組み立てられません: ${e.getMessage()}")
        }

    ///
    /// リゾルバの登録先がスキーマに全部あるか、Query / Mutation の全フィールドにリゾルバがあるかを調べる。
    ///
    /// WhyNot: TypeDefinitionRegistry ではなく組み立て済みの GraphQLSchema を見るのは、
    /// registry 側の型がジェネリクス（Optional<TypeDefinition<?>>）で Flix から扱いにくいため。
    /// 同じ SDL から作った物なので、フィールドの有無は一致する。
    ///
    def validateResolvers(executableSchema: GraphQLSchema, resolvers: Map[(String, String), Resolver]): Result[String, Unit] \ IO =
        let unknown = Map.keysOf(resolvers) |> Set.toList |> List.filter(coordinates -> not hasField(executableSchema, coordinates));
        let missing = rootFields(executableSchema) |> List.filter(coordinates -> not Map.memberOf(coordinates, resolvers));
        match (unknown, missing) {
            case (Nil, Nil) => Ok(())
            case _          => Err("リゾルバとスキーマが食い違っています。スキーマに無いフィールド: [${showCoordinates(unknown)}] / リゾルバが無いフィールド: [${showCoordinates(missing)}]")
        }

    ///
    /// （型名, フィールド名）の一覧を "Query.add, Query.fibonacci" の形にする。
    ///
    def showCoordinates(coordinates: List[(String, String)]): String =
        coordinates |> List.map(match (typeName, fieldName) -> "${typeName}.${fieldName}") |> List.join(", ")

    ///
    /// スキーマに（型名, フィールド名）のフィールドがあるか。
    ///
    /// WhyNot: 型を引いてから instanceof で GraphQLFieldsContainer に絞らないのは、
    /// GraphQLSchema.getFieldDefinition が「型が無い」なら例外・「フィールドが無い」なら null で
    /// 教えてくれるので、それで足りるため。
    ///
    def hasField(executableSchema: GraphQLSchema, coordinates: (String, String)): Bool \ IO =
        let (typeName, fieldName) = coordinates;
        try {
            not Objects.isNull(executableSchema.getFieldDefinition(FieldCoordinates.coordinates(typeName, fieldName)))
        } catch {
            case _: GraphQLException => false
        }

    ///
    /// Query と（あれば）Mutation の全フィールドを（型名, フィールド名）で並べる。
    ///
    /// WhyNot: Subscription をここに入れないのは、Subscription のリゾルバが値ではなく
    /// Publisher（ストリーム）を返す物で、Resolver の型（Result[String, Value]）では表せないため。
    /// Subscription は意図的に扱わない。
    ///
    def rootFields(executableSchema: GraphQLSchema): List[(String, String)] \ IO =
        (executableSchema.getQueryType() :: executableSchema.getMutationType() :: Nil)
            |> List.filter(objectType -> not Objects.isNull(objectType))
            |> List.flatMap(fieldsOf)

    ///
    /// オブジェクト型の全フィールドを（型名, フィールド名）で並べる。
    ///
    def fieldsOf(objectType: GraphQLObjectType): List[(String, String)] \ IO =
        let fields: List[GraphQLFieldDefinition] = Adaptor.fromList(objectType.getFieldDefinitions());
        List.map(field -> (objectType.getName(), field.getName()), fields)

    ///
    /// リゾルバを graphql-java の DataFetcher に包む。引数と戻り値の変換はここで行う。
    /// リゾルバの Err は GraphQLException として投げ、graphql-java に errors へ入れてもらう。
    ///
    def toDataFetcher(resolver: Resolver): DataFetcher[Object] \ IO =
        new DataFetcher[Object] {
            def get(_this: DataFetcher[Object], env: DataFetchingEnvironment): Object \ IO =
                match resolver(JavaValue.fromArguments(env.getArguments())) {
                    case Ok(value)    => JavaValue.toObject(value)
                    case Err(message) => throw new GraphQLException(message)
                }
        }

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
