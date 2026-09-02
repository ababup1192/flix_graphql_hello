///
/// リクエスト単位の情報。すべてのリゾルバに第 1 引数として届く。
/// userId は認証済みならその ID（JWT 検証を入れるまでは None）。
///
pub type alias Context = { userId = Option[String] }

mod Context {

    ///
    /// 認証していない Context。JWT 検証を入れるまでは全リクエストがこれ。
    ///
    pub def anonymous(): Context = { userId = None }

}

///
/// リゾルバが返すエラー。今はメッセージ文字列だけで、GraphQL の errors[].message になる。
///
/// WhyNot: 最初から enum にしないのは、リゾルバ側の `Err("...")` の書き味を保つため。
/// extensions（code など）が要るときは、この alias を enum に差し替えれば署名は全部ここに向いている。
///
pub type alias FieldError = String

///
/// SDL に出す型参照。オブジェクト型はフィールド一覧を thunk で持つ。
///
/// WhyNot: Object のフィールド一覧を値で持たないのは、Post.author: Author と Author.posts: [Post]
/// のように相互に参照する型を組み立てると、値のまま持つ限り無限に展開されるため。
/// thunk なら SDL 生成時に型名で重複を排除しながら辿れる。
///
pub enum TypeRef {
    /// 組み込みスカラー（Int / Float / String / Boolean / ID）
    case Scalar(String)
    /// オブジェクト型。名前と、型消去済みのフィールド一覧
    case Object(String, Unit -> List[ErasedField])
    /// enum 型。名前と値の名前一覧
    case Enum(String, List[String])
    /// [T]
    case ListOf(TypeRef)
    /// nullable の T（Flix の Option）
    case Nullable(TypeRef)
}

mod TypeRef {

    ///
    /// nullable にする。すでに nullable ならそのまま。
    ///
    pub def nullable(typeRef: TypeRef): TypeRef = match typeRef {
        case TypeRef.Nullable(_) => typeRef
        case _                   => TypeRef.Nullable(typeRef)
    }

    ///
    /// SDL の型表記。Nullable 以外は末尾に ! が付く。
    ///
    pub def toSdl(typeRef: TypeRef): String = match typeRef {
        case TypeRef.Nullable(inner) => bareName(inner)
        case _                       => "${bareName(typeRef)}!"
    }

    ///
    /// enum 型か。SDL のリテラルで引用符を付けるかどうかに使う。
    ///
    pub def isEnum(typeRef: TypeRef): Bool = match typeRef {
        case TypeRef.Enum(_, _)      => true
        case TypeRef.Nullable(inner) => isEnum(inner)
        case _                       => false
    }

    ///
    /// ! を付けない型名。
    ///
    def bareName(typeRef: TypeRef): String = match typeRef {
        case TypeRef.Scalar(name)    => name
        case TypeRef.Object(name, _) => name
        case TypeRef.Enum(name, _)   => name
        case TypeRef.ListOf(inner)   => "[${toSdl(inner)}]"
        case TypeRef.Nullable(inner) => bareName(inner)
    }

}

///
/// SDL に出す引数の情報。
///
pub type alias ArgInfo = { name = String, typeRef = TypeRef, description = Option[String], defaultValue = Option[Value] }

///
/// @deprecated の reason の有無。
///
pub enum Deprecation with Eq, ToString {
    /// @deprecated(reason: "...")
    case Reason(String)
    /// reason 無しの @deprecated（GraphQL の既定の reason "No longer supported" になる）
    case NoReason
}

///
/// SDL に出すフィールドの情報。
///
pub type alias FieldInfo = { name = String, args = List[ArgInfo], typeRef = TypeRef, description = Option[String], deprecated = Option[Deprecation] }

///
/// source の型を消したフィールド。graphql-java の DataFetcher に直接なる形。
/// fetch は「箱詰めされた (Context, source) と引数を受け、箱詰めされた戻り値を返す」。
///
pub type alias ErasedField = { info = FieldInfo, fetch = JavaValue.Boxed -> Args -> Result[FieldError, JavaValue.Boxed] \ IO }

///
/// SDL に出す型宣言。ルート型から到達できる物を Schema.collectTypes が集める。
///
pub enum TypeDecl {
    /// type Name { ... }。フィールドは DataFetcher の配線にも使う
    case ObjectDecl(String, List[ErasedField])
    /// enum Name { ... }
    case EnumDecl(String, List[String])
}

///
/// フィールドの引数 1 つ。名前と GraphQL の型。
///
pub enum Arg[a] {
    /// codec は引数のデコードと SDL の型に使う
    case Arg({ name = String, codec = GqlCodec[a], description = Option[String], defaultValue = Option[Value] })
}

mod Arg {

    ///
    /// 引数を作る。
    ///
    pub def arg(name: String, codec: GqlCodec[a]): Arg[a] =
        Arg.Arg({ name = name, codec = codec, description = None, defaultValue = None })

    ///
    /// SDL の description を付ける。
    ///
    pub def withDescription(text: String, arg: Arg[a]): Arg[a] =
        let Arg.Arg(inner) = arg;
        Arg.Arg({ description = Some(text) | inner })

    ///
    /// クライアントが省略したときの値。Flix の値で受け、SDL には codec で変換して出す。
    ///
    pub def withDefault(value: a, arg: Arg[a]): Arg[a] =
        let Arg.Arg(inner) = arg;
        Arg.Arg({ defaultValue = Some(GqlCodec.encode(inner#codec, value)) | inner })

    ///
    /// クライアントが省略したときの値を Value で受ける。生成器（schemagen）が SDL の既定値をそのまま渡す用。
    ///
    pub def withDefaultValue(value: Value, arg: Arg[a]): Arg[a] =
        let Arg.Arg(inner) = arg;
        Arg.Arg({ defaultValue = Some(value) | inner })

    ///
    /// SDL 用の情報。
    ///
    pub def info(arg: Arg[a]): ArgInfo =
        let Arg.Arg(inner) = arg;
        { name = inner#name, typeRef = GqlCodec.typeRef(inner#codec), description = inner#description, defaultValue = inner#defaultValue }

    ///
    /// 引数 Map から値を取り出してデコードする。無ければ Null として扱う（nullable なら None になる）。
    /// 型が合わなければ引数名と SDL の型を含む Err。
    ///
    pub def decode(arg: Arg[a], args: Args): Result[FieldError, a] =
        let Arg.Arg(inner) = arg;
        GqlCodec.decode(inner#codec, Map.getWithDefault(inner#name, Value.Null, args))
            |> Result.mapErr(reason -> "argument '${inner#name}' must be ${TypeRef.toSdl(GqlCodec.typeRef(inner#codec))}: ${reason}")

}

///
/// フィールドの戻り値の型。スカラーは Value に潰し、オブジェクトは Flix の値のまま子フィールドへ渡す。
///
/// WhyNot: オブジェクト型を GqlCodec で Value.Obj に潰さないのは、それだとクエリの selection に
/// 関係なく全フィールドのリゾルバ（IO を含む）が走るため。graphql-java の流儀どおり、
/// 親は source を返すだけにして、子フィールドは要求されたときだけ動かす。
///
pub enum Out[a] {
    /// encode は Context ごと箱詰めして子フィールドへ渡す
    case Out({ typeRef = TypeRef, encode = Context -> a -> JavaValue.Boxed \ IO })
}

mod Out {

    ///
    /// スカラーの戻り値。
    ///
    pub def scalar(codec: GqlCodec[a]): Out[a] =
        Out.Out({ typeRef = GqlCodec.typeRef(codec), encode = (_context, x) -> JavaValue.toBoxed(GqlCodec.encode(codec, x)) })

    ///
    /// オブジェクト型の戻り値。値は箱詰めして、子フィールドの source になる。
    ///
    pub def obj(objectType: ObjectType[a]): Out[a] =
        Out.Out({ typeRef = ObjectType.typeRef(objectType), encode = (context, x) -> JavaValue.box((context, x)) })

    ///
    /// nullable にする。None は null。二重に重ねても 1 段。
    ///
    pub def option(out: Out[a]): Out[Option[a]] =
        let Out.Out(inner) = out;
        Out.Out({
            typeRef = TypeRef.nullable(inner#typeRef),
            encode  = (context, maybe) -> match maybe {
                case Some(x) => (inner#encode)(context, x)
                case None    => JavaValue.boxedNull()
            }
        })

    ///
    /// リストにする。
    ///
    pub def list(out: Out[a]): Out[List[a]] =
        let Out.Out(inner) = out;
        Out.Out({
            typeRef = TypeRef.ListOf(inner#typeRef),
            encode  = (context, items) -> JavaValue.boxedList(List.map(x -> (inner#encode)(context, x), items))
        })

    /// Int
    pub def int32(): Out[Int32] = scalar(GqlCodec.int32())
    /// Float
    pub def float64(): Out[Float64] = scalar(GqlCodec.float64())
    /// String
    pub def string(): Out[String] = scalar(GqlCodec.string())
    /// Boolean
    pub def bool(): Out[Bool] = scalar(GqlCodec.bool())
    /// ID
    pub def id(): Out[Id] = scalar(GqlCodec.id())

    ///
    /// SDL に出す型参照。
    ///
    pub def typeRef(out: Out[a]): TypeRef =
        let Out.Out(inner) = out;
        inner#typeRef

    ///
    /// 戻り値を箱詰めする。
    ///
    pub def encode(out: Out[a], context: Context, x: a): JavaValue.Boxed \ IO =
        let Out.Out(inner) = out;
        (inner#encode)(context, x)

}

///
/// オブジェクト型のフィールド 1 つ。source は親オブジェクトの Flix の型（ルートなら Unit）。
/// resolve は引数のデコードから戻り値の箱詰めまでを閉じた関数で、Err はそのまま GraphQL のエラーになる。
///
/// WhyNot: effect を IO に固定するのは、effect 多相にすると List[Field[a]] に並べられないため。
/// 他の effect を使うリゾルバは、フィールドを作る時点でハンドラで包む（Counter を参照）。
///
pub enum Field[source] {
    /// info は SDL 用、resolve は実行用
    case Field({ info = FieldInfo, resolve = Context -> source -> Args -> Result[FieldError, JavaValue.Boxed] \ IO })
}

mod Field {

    ///
    /// SDL の description を付ける。
    ///
    pub def withDescription(text: String, field: Field[source]): Field[source] =
        let Field.Field(inner) = field;
        Field.Field({ info = { description = Some(text) | inner#info } | inner })

    ///
    /// @deprecated(reason: "...") を付ける。
    ///
    pub def withDeprecation(reason: String, field: Field[source]): Field[source] =
        let Field.Field(inner) = field;
        Field.Field({ info = { deprecated = Some(Deprecation.Reason(reason)) | inner#info } | inner })

    ///
    /// reason 無しの @deprecated を付ける（GraphQL の既定の reason "No longer supported" になる）。
    ///
    pub def deprecate(field: Field[source]): Field[source] =
        let Field.Field(inner) = field;
        Field.Field({ info = { deprecated = Some(Deprecation.NoReason) | inner#info } | inner })

    ///
    /// source の型を消して、graphql-java に渡せる形にする。
    ///
    pub def erase(field: Field[source]): ErasedField =
        let Field.Field(inner) = field;
        { info = inner#info, fetch = (boxed, args) -> {
            let (context, src): (Context, source) = JavaValue.unbox(boxed);
            (inner#resolve)(context, src, args)
        } }

}

///
/// オブジェクト型。名前とフィールド一覧。a はこの型を表す Flix の型。
///
pub enum ObjectType[a] {
    /// フィールド一覧は相互参照を許すため thunk
    case ObjectType({ name = String, fields = Unit -> List[Field[a]] })
}

mod ObjectType {

    ///
    /// SDL に出す型参照。
    ///
    pub def typeRef(objectType: ObjectType[a]): TypeRef =
        let ObjectType.ObjectType(inner) = objectType;
        TypeRef.Object(inner#name, () -> List.map(Field.erase, (inner#fields)()))

}

///
/// スキーマ全体。Query と（あれば）Mutation のルート型。
///
pub enum Schema {
    /// ルート型の source は無いので Unit
    case Schema({ queryType = ObjectType[Unit], mutationType = Option[ObjectType[Unit]] })
}

///
/// スキーマを Flix の値として組み立てる DSL。
/// ここで作った値から SDL（Schema.toSdl）と graphql-java の DataFetcher（Schema.objectTypes）の両方を導くので、
/// スキーマとリゾルバがずれることは構造上あり得ない。
///
mod Schema {

    ///
    /// 引数を作る。Arg.arg の短い呼び名。
    ///
    pub def arg(name: String, codec: GqlCodec[a]): Arg[a] = Arg.arg(name, codec)

    ///
    /// 引数の無いフィールド。
    ///
    pub def field0(name: String, out: Out[r], f: Context -> source -> Result[FieldError, r] \ IO): Field[source] =
        makeField(name, Nil, out, (context, src, _args) -> f(context, src))

    ///
    /// 引数 1 つのフィールド。
    ///
    pub def field1(name: String, a: Arg[a], out: Out[r], f: Context -> source -> a -> Result[FieldError, r] \ IO): Field[source] =
        makeField(name, Arg.info(a) :: Nil, out, (context, src, args) ->
            forM (
                av <- Arg.decode(a, args);
                x  <- f(context, src, av)
            ) yield x)

    ///
    /// 引数 2 つのフィールド。
    ///
    pub def field2(name: String, a: Arg[a], b: Arg[b], out: Out[r], f: Context -> source -> a -> b -> Result[FieldError, r] \ IO): Field[source] =
        makeField(name, Arg.info(a) :: Arg.info(b) :: Nil, out, (context, src, args) ->
            forM (
                av <- Arg.decode(a, args);
                bv <- Arg.decode(b, args);
                x  <- f(context, src, av, bv)
            ) yield x)

    ///
    /// 引数 3 つのフィールド。4 つ以上は input 型にまとめる。
    ///
    pub def field3(name: String, a: Arg[a], b: Arg[b], c: Arg[c], out: Out[r], f: Context -> source -> a -> b -> c -> Result[FieldError, r] \ IO): Field[source] =
        makeField(name, Arg.info(a) :: Arg.info(b) :: Arg.info(c) :: Nil, out, (context, src, args) ->
            forM (
                av <- Arg.decode(a, args);
                bv <- Arg.decode(b, args);
                cv <- Arg.decode(c, args);
                x  <- f(context, src, av, bv, cv)
            ) yield x)

    ///
    /// 引数を Args のまま受けるフィールド。引数の個数に上限が無い。
    /// 生成器（schemagen）が使う。人が書くときは field0..3 の方が引数の型が決まって安全。
    ///
    pub def fieldRaw(name: String, args: List[ArgInfo], out: Out[r], f: Context -> source -> Args -> Result[FieldError, r] \ IO): Field[source] =
        makeField(name, args, out, f)

    ///
    /// オブジェクト型を作る。fields は相互参照を許すため thunk で受ける。
    ///
    pub def objectType(name: String, fields: Unit -> List[Field[a]]): ObjectType[a] =
        ObjectType.ObjectType({ name = name, fields = fields })

    ///
    /// スキーマを作る。
    ///
    pub def make(queryType: ObjectType[Unit], mutationType: Option[ObjectType[Unit]]): Schema =
        Schema.Schema({ queryType = queryType, mutationType = mutationType })

    ///
    /// ルート型から到達できる全型宣言（オブジェクト型と enum）を並べる。
    /// Query → Mutation の順に深さ優先で辿り、名前で重複を除く。
    /// 同じ名前で中身の違う型が 2 つあれば Err。
    ///
    /// WhyNot: 同名で中身が同じ物を Err にしないのは、`postType()` のように型を関数で作ると
    /// 参照のたびに新しい値ができ、同じ定義の再参照と別定義の重複を見分けられないため。
    /// 中身（SDL）が同じなら最初の物を使う。source の Flix 型だけが違う重複は検出できない
    /// （docs/design/typed-schema.md の既知の制限）。
    ///
    pub def collectTypes(schema: Schema): Result[String, List[TypeDecl]] =
        let Schema.Schema(inner) = schema;
        let roots = ObjectType.typeRef(inner#queryType) :: (inner#mutationType |> Option.map(ObjectType.typeRef) |> Option.toList);
        List.foldLeft((state, root) -> Result.flatMap(visit(root), state), Ok((Map.empty(), Nil)), roots)
            |> Result.map(state -> snd(state) |> List.reverse)

    ///
    /// SDL を出す。
    ///
    pub def toSdl(schema: Schema): Result[String, String] =
        collectTypes(schema) |> Result.map(types -> renderSdl(schema, types))

    ///
    /// 集めた型宣言から SDL を組み立てる。buildEngine は同じ一覧から DataFetcher も配線するので、
    /// SDL と配線が別の評価結果からずれることは無い。
    ///
    pub def renderSdl(schema: Schema, types: List[TypeDecl]): String =
        let Schema.Schema(inner) = schema;
        (schemaBlock(inner) :: List.map(declBlock, types)) |> List.join("\n\n")

    ///
    /// フィールドの共通部分。引数のデコード（g の中）と戻り値の箱詰めをつなぐ。
    ///
    def makeField(name: String, args: List[ArgInfo], out: Out[r], g: Context -> source -> Args -> Result[FieldError, r] \ IO): Field[source] =
        Field.Field({
            info    = { name = name, args = args, typeRef = Out.typeRef(out), description = None, deprecated = None },
            resolve = (context, src, argMap) -> g(context, src, argMap) |> Result.map(x -> Out.encode(out, context, x))
        })

    ///
    /// 型宣言の走査状態（名前 → その型のシグネチャ, 訪問順の逆順の一覧）。
    ///
    type alias VisitState = (Map[String, String], List[TypeDecl])

    ///
    /// 型参照を深さ優先で辿り、型宣言を集める。
    ///
    def visit(typeRef: TypeRef, state: VisitState): Result[String, VisitState] =
        match typeRef {
            case TypeRef.Scalar(_)               => Ok(state)
            case TypeRef.ListOf(inner)           => visit(inner, state)
            case TypeRef.Nullable(inner)         => visit(inner, state)
            case TypeRef.Enum(name, values)      => declare(name, TypeDecl.EnumDecl(name, values), state, Ok)
            case TypeRef.Object(name, fieldsOf)  =>
                let fields = fieldsOf();
                declare(name, TypeDecl.ObjectDecl(name, fields), state, declared ->
                    List.foldLeft((accumulated, field) -> Result.flatMap(visitField(field), accumulated), Ok(declared), fields))
        }

    ///
    /// 型宣言を 1 つ登録する。同じ名前が既にあれば、シグネチャが同じなら何もせず、違えば Err。
    /// 初めての名前なら登録してから visitInner（フィールドの型を辿る処理）を続ける。
    ///
    def declare(name: String, decl: TypeDecl, state: VisitState, visitInner: VisitState -> Result[String, VisitState]): Result[String, VisitState] =
        let (seen, collected) = state;
        let signature = declBlock(decl);
        match Map.get(name, seen) {
            case Some(known) if known == signature => Ok(state)
            case Some(_)                           => Err("型 ${name} が別の中身で 2 回定義されています")
            case None                              => visitInner((Map.insert(name, signature, seen), decl :: collected))
        }

    ///
    /// フィールドの引数の型と戻り値の型を辿る。
    ///
    def visitField(field: ErasedField, state: VisitState): Result[String, VisitState] =
        List.foldLeft((accumulated, arg) -> Result.flatMap(visit(arg#typeRef), accumulated), Ok(state), field#info#args)
            |> Result.flatMap(visit(field#info#typeRef))

    ///
    /// schema { query: ... mutation: ... } のブロック。
    ///
    def schemaBlock(inner: { queryType = ObjectType[Unit], mutationType = Option[ObjectType[Unit]] }): String =
        let ObjectType.ObjectType(queryInner) = inner#queryType;
        let mutationLine = inner#mutationType |> Option.map(match ObjectType.ObjectType(m) -> "\n  mutation: ${m#name}") |> Option.getWithDefault("");
        "schema {\n  query: ${queryInner#name}${mutationLine}\n}"

    ///
    /// type Name { ... } または enum Name { ... } のブロック。
    ///
    def declBlock(decl: TypeDecl): String = match decl {
        case TypeDecl.ObjectDecl(name, fields) =>
            let body = fields |> List.map(field -> fieldLine(field#info)) |> List.join("\n");
            "type ${name} {\n${body}\n}"
        case TypeDecl.EnumDecl(name, values) =>
            let body = values |> List.map(value -> "  ${value}") |> List.join("\n");
            "enum ${name} {\n${body}\n}"
    }

    ///
    /// フィールド 1 行。description があれば直前の行に、deprecated があれば末尾に付く。
    ///
    /// WhyNot: description を """ """ のブロック文字列で出さないのは、本文に """ が入ると
    /// エスケープが要り、通常の文字列リテラル（JSON と同じエスケープ）なら JsonValue に任せられるため。
    ///
    def fieldLine(info: FieldInfo): String =
        let description = info#description |> Option.map(text -> "  ${stringLiteral(text)}\n") |> Option.getWithDefault("");
        let deprecated = info#deprecated |> Option.map(deprecation -> match deprecation {
            case Deprecation.Reason(text) => " @deprecated(reason: ${stringLiteral(text)})"
            case Deprecation.NoReason     => " @deprecated"
        }) |> Option.getWithDefault("");
        "${description}  ${info#name}${argsBlock(info#args)}: ${TypeRef.toSdl(info#typeRef)}${deprecated}"

    ///
    /// (a: Int!, b: Int! = 1) の部分。引数が無ければ空。
    ///
    def argsBlock(args: List[ArgInfo]): String = match args {
        case Nil => ""
        case _   => "(" + (args |> List.map(argText) |> List.join(", ")) + ")"
    }

    ///
    /// 引数 1 つ。description は文字列リテラルで前に置く。
    ///
    def argText(arg: ArgInfo): String =
        let description = arg#description |> Option.map(text -> "${stringLiteral(text)} ") |> Option.getWithDefault("");
        let defaultValue = arg#defaultValue |> Option.map(value -> " = ${literal(TypeRef.isEnum(arg#typeRef), value)}") |> Option.getWithDefault("");
        "${description}${arg#name}: ${TypeRef.toSdl(arg#typeRef)}${defaultValue}"

    ///
    /// GraphQL の文字列リテラル。エスケープは JSON と同じ。
    ///
    def stringLiteral(text: String): String = JsonValue.toJsonString(Value.Str(text))

    ///
    /// Value を GraphQL のリテラルにする。オブジェクトのキーは JSON と違って引用符が付かず、
    /// enum の値（isEnum）も引用符無しで出す。
    ///
    def literal(isEnum: Bool, value: Value): String = match value {
        case Value.Str(name) if isEnum => name
        case Value.List(items)         => "[" + (items |> List.map(literal(isEnum)) |> List.join(", ")) + "]"
        case Value.Obj(fields)         => "{" + (Map.toList(fields) |> List.map(match (key, v) -> "${key}: ${literal(false, v)}") |> List.join(", ")) + "}"
        case _                         => JsonValue.toJsonString(value)
    }

}
