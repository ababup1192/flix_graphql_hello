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
/// リゾルバの効果 ef を IO に落とすハンドラ。Schema.make に 1 回だけ渡す。
/// 受け取る thunk は戻り値の箱詰め（IO）まで済ませた物なので、その効果は ef + IO。
///
/// WhyNot: `(Unit -> a \ ef) -> a \ IO` と書かないのは、型別名が自由な型変数 a を持てず、
/// Flix に rank-2 型も無いため。戻り型を箱に固定すれば ef を多相のまま値として渡せる。
///
pub type alias Runner[ef: Eff] = (Unit -> Result[FieldError, JavaValue.Boxed] \ ef + IO) -> Result[FieldError, JavaValue.Boxed] \ IO

mod Runner {

    ///
    /// IO しか使わないリゾルバ用。thunk をそのまま呼ぶ。
    ///
    pub def io(): Runner[IO] = f -> f()

}

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
    /// オブジェクト型。implements する interface は名前だけ（interface 自身の宣言はそれを返すフィールドから辿る）
    case Object({ name = String, description = Option[String], interfaces = List[String], fields = Unit -> List[ErasedField] })
    /// union 型。members はオブジェクト型の参照
    case Union({ name = String, description = Option[String], members = List[TypeRef] })
    /// interface 型。fields は SDL に出す形だけ（リゾルバは実装型が持つ）、members は実装するオブジェクト型の参照
    case Interface({ name = String, description = Option[String], fields = List[FieldInfo], members = List[TypeRef] })
    /// enum 型。名前、description、値の一覧
    case Enum(String, Option[String], List[EnumValueInfo])
    /// input 型。名前、description、フィールド一覧（引数と同じ形。値で持てるのは input の循環参照を生成器が禁じているため）
    case InputObject(String, Option[String], List[ArgInfo])
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
    /// 型に description を付ける。Object / Enum / InputObject 以外（スカラー、nullable やリストで包んだ物）はそのまま。
    ///
    pub def describe(text: String, typeRef: TypeRef): TypeRef = match typeRef {
        case TypeRef.Object(inner)                => TypeRef.Object({ description = Some(text) | inner })
        case TypeRef.Union(inner)                 => TypeRef.Union({ description = Some(text) | inner })
        case TypeRef.Interface(inner)             => TypeRef.Interface({ description = Some(text) | inner })
        case TypeRef.Enum(name, _, values)        => TypeRef.Enum(name, Some(text), values)
        case TypeRef.InputObject(name, _, fields) => TypeRef.InputObject(name, Some(text), fields)
        case _                                    => typeRef
    }

    ///
    /// enum 型か。SDL のリテラルで引用符を付けるかどうかに使う。
    ///
    pub def isEnum(typeRef: TypeRef): Bool = match typeRef {
        case TypeRef.Enum(_, _, _)   => true
        case TypeRef.Nullable(inner) => isEnum(inner)
        case _                       => false
    }

    ///
    /// ! を付けない型名。
    ///
    pub def bareName(typeRef: TypeRef): String = match typeRef {
        case TypeRef.Scalar(name)    => name
        case TypeRef.Object(inner)           => inner#name
        case TypeRef.Union(inner)            => inner#name
        case TypeRef.Interface(inner)        => inner#name
        case TypeRef.Enum(name, _, _)        => name
        case TypeRef.InputObject(name, _, _) => name
        case TypeRef.ListOf(inner)   => "[${toSdl(inner)}]"
        case TypeRef.Nullable(inner) => bareName(inner)
    }

}

///
/// SDL に出す enum 値の情報。
///
pub type alias EnumValueInfo = { name = String, description = Option[String], deprecated = Option[Deprecation] }

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
    /// type Name implements I { ... }。フィールドは DataFetcher の配線にも使う
    case ObjectDecl({ name = String, description = Option[String], interfaces = List[String], fields = List[ErasedField] })
    /// union Name = A | B。TypeResolver の登録にも使う
    case UnionDecl({ name = String, description = Option[String], members = List[String] })
    /// interface Name { ... }。TypeResolver の登録にも使う。members は実装型の名前（SDL には出ず、implements の検査に使う）
    case InterfaceDecl({ name = String, description = Option[String], fields = List[FieldInfo], members = List[String] })
    /// enum Name { ... }
    case EnumDecl(String, Option[String], List[EnumValueInfo])
    /// input Name { ... }
    case InputDecl(String, Option[String], List[ArgInfo])
    /// scalar Name（組み込み以外のスカラー。今は JSON だけ）
    case ScalarDecl(String)
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
    /// input 型の引数には使えない（encode が無いので SDL に null が出る）。withDefaultValue で Value を渡す。
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
        decodeAs("argument", arg, args)

    ///
    /// input 型のフィールドとして取り出す。エラー文が「field 'x' must be ...」になる以外は decode と同じ。
    /// 外側の decode がこの文を包むので、ネストした位置（argument 'input' must be PostInput!: field 'status' must be ...）が読める。
    ///
    pub def decodeField(arg: Arg[a], fields: Args): Result[FieldError, a] =
        decodeAs("field", arg, fields)

    ///
    /// decode / decodeField の共通部分。kind はエラー文の頭。
    ///
    def decodeAs(kind: String, arg: Arg[a], args: Args): Result[FieldError, a] =
        let Arg.Arg(inner) = arg;
        GqlCodec.decode(inner#codec, Map.getWithDefault(inner#name, Value.Null, args))
            |> Result.mapErr(reason -> "${kind} '${inner#name}' must be ${TypeRef.toSdl(GqlCodec.typeRef(inner#codec))}: ${reason}")

}

///
/// フィールドの戻り値の型。スカラーは Value に潰し、オブジェクトは Flix の値のまま子フィールドへ渡す。
///
/// WhyNot: オブジェクト型を GqlCodec で Value.Obj に潰さないのは、それだとクエリの selection に
/// 関係なく全フィールドのリゾルバ（IO を含む）が走るため。graphql-java の流儀どおり、
/// 親は source を返すだけにして、子フィールドは要求されたときだけ動かす。
///
/// WhyNot: typeRef を値でなく Runner を受ける関数で持つのは、TypeRef.Object が IO に落とした
/// フィールド一覧を持ち、その型消去に Runner が要るが、Out.obj の時点では Runner が手元に無いため。
/// TypeRef 自身に効果変数を通すと ArgInfo / FieldInfo / GqlCodec まで変数が広がる。
///
pub enum Out[a: Type, ef: Eff] {
    /// encode は Context ごと箱詰めして子フィールドへ渡す
    case Out({ typeRef = Runner[ef] -> TypeRef, encode = Context -> a -> JavaValue.Boxed \ IO })
}

mod Out {

    ///
    /// スカラーの戻り値。
    ///
    pub def scalar(codec: GqlCodec[a]): Out[a, ef] =
        Out.Out({ typeRef = _runner -> GqlCodec.typeRef(codec), encode = (_context, x) -> JavaValue.toBoxed(GqlCodec.encode(codec, x)) })

    ///
    /// オブジェクト型の戻り値。値は箱詰めして、子フィールドの source になる。
    ///
    pub def obj(objectType: ObjectType[a, ef]): Out[a, ef] =
        Out.Out({ typeRef = runner -> ObjectType.typeRef(runner, objectType), encode = (context, x) -> JavaValue.box((context, x)) })

    ///
    /// union / interface の枝になるオブジェクト型の参照（型消去済み）。
    ///
    pub def member(objectType: ObjectType[b, ef]): MemberRef[ef] =
        runner -> ObjectType.typeRef(runner, objectType)

    ///
    /// union 型の戻り値。encode は Flix の enum の値を枝の型で箱詰めする（taggedObj を使う）。
    ///
    pub def union(name: String, members: List[MemberRef[ef]], encode: Context -> a -> JavaValue.Boxed \ IO): Out[a, ef] =
        Out.Out({ typeRef = runner -> TypeRef.Union({ name = name, description = None, members = List.map(m -> m(runner), members) }), encode = encode })

    ///
    /// interface 型の戻り値。fields は SDL に出す形（Schema.abstractField で作る）、members は実装するオブジェクト型。
    ///
    pub def interface(name: String, fields: List[Field[Unit, ef]], members: List[MemberRef[ef]], encode: Context -> a -> JavaValue.Boxed \ IO): Out[a, ef] =
        Out.Out({
            typeRef = runner -> TypeRef.Interface({
                name = name, description = None,
                fields = List.map(field -> Field.erase(runner, field)#info, fields),
                members = List.map(m -> m(runner), members)
            }),
            encode = encode
        })

    ///
    /// union / interface の枝の値を、その型のオブジェクトとして箱詰めし、型名のタグを付ける。
    ///
    pub def taggedObj(objectType: ObjectType[b, ef], context: Context, x: b): JavaValue.Boxed \ IO =
        JavaValue.tag(ObjectType.name(objectType), encode(obj(objectType), context, x))

    ///
    /// union / interface / オブジェクト型に SDL の description を付ける。
    ///
    pub def describe(text: String, out: Out[a, ef]): Out[a, ef] =
        let Out.Out(inner) = out;
        Out.Out({ typeRef = runner -> TypeRef.describe(text, (inner#typeRef)(runner)) | inner })

    ///
    /// nullable にする。None は null。二重に重ねても 1 段。
    ///
    pub def option(out: Out[a, ef]): Out[Option[a], ef] =
        let Out.Out(inner) = out;
        Out.Out({
            typeRef = runner -> TypeRef.nullable((inner#typeRef)(runner)),
            encode  = (context, maybe) -> match maybe {
                case Some(x) => (inner#encode)(context, x)
                case None    => JavaValue.boxedNull()
            }
        })

    ///
    /// リストにする。
    ///
    pub def list(out: Out[a, ef]): Out[List[a], ef] =
        let Out.Out(inner) = out;
        Out.Out({
            typeRef = runner -> TypeRef.ListOf((inner#typeRef)(runner)),
            encode  = (context, items) -> JavaValue.boxedList(List.map(x -> (inner#encode)(context, x), items))
        })

    /// Int
    pub def int32(): Out[Int32, ef] = scalar(GqlCodec.int32())
    /// Float
    pub def float64(): Out[Float64, ef] = scalar(GqlCodec.float64())
    /// String
    pub def string(): Out[String, ef] = scalar(GqlCodec.string())
    /// Boolean
    pub def bool(): Out[Bool, ef] = scalar(GqlCodec.bool())
    /// ID
    pub def id(): Out[Id, ef] = scalar(GqlCodec.id())
    /// JSON（任意の JSON 値）
    pub def json(): Out[Value, ef] = scalar(GqlCodec.json())

    ///
    /// SDL に出す型参照。オブジェクト型のフィールドを runner で IO に落として型消去する。
    ///
    pub def typeRef(runner: Runner[ef], out: Out[a, ef]): TypeRef =
        let Out.Out(inner) = out;
        (inner#typeRef)(runner)

    ///
    /// 戻り値を箱詰めする。
    ///
    pub def encode(out: Out[a, ef], context: Context, x: a): JavaValue.Boxed \ IO =
        let Out.Out(inner) = out;
        (inner#encode)(context, x)

}

///
/// オブジェクト型のフィールド 1 つ。source は親オブジェクトの Flix の型（ルートなら Unit）、
/// ef はリゾルバの効果。resolve は引数のデコードから戻り値の箱詰めまでを閉じた関数で、
/// Err はそのまま GraphQL のエラーになる。
///
/// WhyNot: フィールドごとに別の効果変数を持たせないのは、1 つの型のフィールドを List[Field[a, ef]] に
/// 並べるため。
///
pub enum Field[source: Type, ef: Eff] {
    /// typeRef は SDL 用（Runner で型消去してから確定）、resolve は実行用
    case Field({
        name = String, args = List[ArgInfo], description = Option[String], deprecated = Option[Deprecation],
        typeRef = Runner[ef] -> TypeRef,
        resolve = Context -> source -> Args -> Result[FieldError, JavaValue.Boxed] \ ef + IO
    })
}

mod Field {

    ///
    /// SDL の description を付ける。
    ///
    pub def withDescription(text: String, field: Field[source, ef]): Field[source, ef] =
        let Field.Field(inner) = field;
        Field.Field({ description = Some(text) | inner })

    ///
    /// @deprecated(reason: "...") を付ける。
    ///
    pub def withDeprecation(reason: String, field: Field[source, ef]): Field[source, ef] =
        let Field.Field(inner) = field;
        Field.Field({ deprecated = Some(Deprecation.Reason(reason)) | inner })

    ///
    /// reason 無しの @deprecated を付ける（GraphQL の既定の reason "No longer supported" になる）。
    ///
    pub def deprecate(field: Field[source, ef]): Field[source, ef] =
        let Field.Field(inner) = field;
        Field.Field({ deprecated = Some(Deprecation.NoReason) | inner })

    ///
    /// source の型と効果を消して、graphql-java に渡せる形にする。
    /// 効果は runner で IO に落とす。
    ///
    pub def erase(runner: Runner[ef], field: Field[source, ef]): ErasedField =
        let Field.Field(inner) = field;
        {
            info  = { name = inner#name, args = inner#args, typeRef = (inner#typeRef)(runner), description = inner#description, deprecated = inner#deprecated },
            fetch = (boxed, args) -> runner(() -> {
                let (_, untagged) = JavaValue.untag(boxed);
                let (context, src): (Context, source) = JavaValue.unbox(untagged);
                (inner#resolve)(context, src, args)
            })
        }

}

///
/// オブジェクト型。名前とフィールド一覧。a はこの型を表す Flix の型、ef はフィールドのリゾルバの効果。
///
pub enum ObjectType[a: Type, ef: Eff] {
    /// フィールド一覧は相互参照を許すため thunk。interfaces は implements する interface の名前
    case ObjectType({ name = String, description = Option[String], interfaces = List[String], fields = Unit -> List[Field[a, ef]] })
}

///
/// union / interface の枝の参照。Runner で型消去してから TypeRef になる。
///
pub type alias MemberRef[ef: Eff] = Runner[ef] -> TypeRef

mod ObjectType {

    ///
    /// implements する interface の名前を付ける。interface のフィールドを全部持つかは graphql-java（と生成器）が検査する。
    ///
    pub def implementing(names: List[String], objectType: ObjectType[a, ef]): ObjectType[a, ef] =
        let ObjectType.ObjectType(inner) = objectType;
        ObjectType.ObjectType({ interfaces = names | inner })

    ///
    /// SDL の description を付ける。
    ///
    pub def withDescription(text: String, objectType: ObjectType[a, ef]): ObjectType[a, ef] =
        let ObjectType.ObjectType(inner) = objectType;
        ObjectType.ObjectType({ description = Some(text) | inner })

    ///
    /// 型の名前。
    ///
    pub def name(objectType: ObjectType[a, ef]): String =
        let ObjectType.ObjectType(inner) = objectType;
        inner#name

    ///
    /// SDL に出す型参照。フィールドは runner で IO に落として型消去する。
    ///
    pub def typeRef(runner: Runner[ef], objectType: ObjectType[a, ef]): TypeRef =
        let ObjectType.ObjectType(inner) = objectType;
        TypeRef.Object({ name = inner#name, description = inner#description, interfaces = inner#interfaces, fields = () -> List.map(Field.erase(runner), (inner#fields)()) })

}

///
/// ルート型。名前と、runner で IO に落とした後の型参照。
///
pub type alias RootType = { name = String, typeRef = TypeRef }

///
/// スキーマ全体。Query と（あれば）Mutation のルート型。Schema.make でリゾルバの効果は IO に落ちている。
///
pub enum Schema {
    /// ルート型は名前と型消去済みの参照
    case Schema({ queryType = RootType, mutationType = Option[RootType] })
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
    pub def field0(name: String, out: Out[r, ef], f: Context -> source -> Result[FieldError, r] \ ef): Field[source, ef] =
        makeField(name, Nil, out, (context, src, _args) -> f(context, src))

    ///
    /// 引数 1 つのフィールド。
    ///
    pub def field1(name: String, a: Arg[a], out: Out[r, ef], f: Context -> source -> a -> Result[FieldError, r] \ ef): Field[source, ef] =
        makeField(name, Arg.info(a) :: Nil, out, (context, src, args) ->
            forM (
                av <- Arg.decode(a, args);
                x  <- f(context, src, av)
            ) yield x)

    ///
    /// 引数 2 つのフィールド。
    ///
    pub def field2(name: String, a: Arg[a], b: Arg[b], out: Out[r, ef], f: Context -> source -> a -> b -> Result[FieldError, r] \ ef): Field[source, ef] =
        makeField(name, Arg.info(a) :: Arg.info(b) :: Nil, out, (context, src, args) ->
            forM (
                av <- Arg.decode(a, args);
                bv <- Arg.decode(b, args);
                x  <- f(context, src, av, bv)
            ) yield x)

    ///
    /// 引数 3 つのフィールド。4 つ以上は input 型にまとめる。
    ///
    pub def field3(name: String, a: Arg[a], b: Arg[b], c: Arg[c], out: Out[r, ef], f: Context -> source -> a -> b -> c -> Result[FieldError, r] \ ef): Field[source, ef] =
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
    pub def fieldRaw(name: String, args: List[ArgInfo], out: Out[r, ef], f: Context -> source -> Args -> Result[FieldError, r] \ ef): Field[source, ef] =
        makeField(name, args, out, f)

    ///
    /// オブジェクト型を作る。fields は相互参照を許すため thunk で受ける。
    ///
    pub def objectType(name: String, fields: Unit -> List[Field[a, ef]]): ObjectType[a, ef] =
        ObjectType.ObjectType({ name = name, description = None, interfaces = Nil, fields = fields })

    ///
    /// interface のフィールド。SDL の形だけを持ち、リゾルバは実装型の物が使われる。
    ///
    /// WhyNot: FieldInfo を直接作らせず Field にするのは、description / deprecated の付け方（Field.withDescription 等）と
    /// 戻り値の型の遅延（Runner を待つ）を通常のフィールドと共有するため。resolve は呼ばれない。
    ///
    pub def abstractField(name: String, args: List[ArgInfo], out: Out[r, ef]): Field[Unit, ef] =
        makeField(name, args, out, (_context, _src, _args) -> Err("interface field is resolved by the implementing type"))

    ///
    /// スキーマを作る。runner がリゾルバの効果 ef を IO に落とす（graphql-java の DataFetcher から呼ばれる
    /// Flix のクロージャの中でハンドラを走らせる。別スレッドから呼ばれても動く）。
    ///
    pub def make(queryType: ObjectType[Unit, ef], mutationType: Option[ObjectType[Unit, ef]], runner: Runner[ef]): Schema =
        Schema.Schema({ queryType = root(runner, queryType), mutationType = Option.map(root(runner), mutationType) })

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
        let roots = inner#queryType#typeRef :: (inner#mutationType |> Option.map(root -> root#typeRef) |> Option.toList);
        List.foldLeft((state, root) -> Result.flatMap(visit(root), state), Ok((Map.empty(), Nil)), roots)
            |> Result.map(state -> snd(state) |> List.reverse)
            |> Result.flatMap(checkImplements)

    ///
    /// interface の枝（Out.interface の members）に入っている型が ObjectType.implementing でその interface を名乗っているか。
    /// 生成物は生成器が揃えるが、手書きの DSL では片方だけ書けてしまう。
    ///
    /// WhyNot: declBlock のシグネチャ（同名の型の同一判定）に members を含めて済ませないのは、
    /// SDL に出ない情報で「別の中身」と判定すると原因が読めないため。別の検査にして文言を出す。
    ///
    def checkImplements(types: List[TypeDecl]): Result[String, List[TypeDecl]] =
        let interfacesOf = name -> types |> List.findMap(decl -> match decl {
            case TypeDecl.ObjectDecl(object) if object#name == name => Some(object#interfaces)
            case _                                                 => None
        }) |> Option.getWithDefault(Nil);
        let missing = types |> List.flatMap(decl -> match decl {
            case TypeDecl.InterfaceDecl(interface) =>
                interface#members |> List.filter(member -> not List.memberOf(interface#name, interfacesOf(member))) |> List.map(member -> "型 ${member} は interface ${interface#name} の枝ですが implements していません")
            case _ => Nil
        });
        match missing {
            case Nil          => Ok(types)
            case message :: _ => Err(message)
        }

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
    def makeField(name: String, args: List[ArgInfo], out: Out[r, ef], g: Context -> source -> Args -> Result[FieldError, r] \ ef): Field[source, ef] =
        let Out.Out(outInner) = out;
        Field.Field({
            name = name, args = args, description = None, deprecated = None,
            typeRef = outInner#typeRef,
            resolve = (context, src, argMap) -> g(context, src, argMap) |> Result.map(x -> Out.encode(out, context, x))
        })

    ///
    /// ルート型を runner で型消去する。
    ///
    def root(runner: Runner[ef], objectType: ObjectType[Unit, ef]): RootType =
        { name = ObjectType.name(objectType), typeRef = ObjectType.typeRef(runner, objectType) }

    ///
    /// 型宣言の走査状態（名前 → その型のシグネチャ, 訪問順の逆順の一覧）。
    ///
    type alias VisitState = (Map[String, String], List[TypeDecl])

    ///
    /// 型参照を深さ優先で辿り、型宣言を集める。
    ///
    def visit(typeRef: TypeRef, state: VisitState): Result[String, VisitState] =
        match typeRef {
            case TypeRef.Scalar(name)            => if (List.memberOf(name, builtinScalars())) Ok(state) else declare(name, TypeDecl.ScalarDecl(name), state, Ok)
            case TypeRef.ListOf(inner)           => visit(inner, state)
            case TypeRef.Nullable(inner)         => visit(inner, state)
            case TypeRef.Enum(name, description, values) => declare(name, TypeDecl.EnumDecl(name, description, values), state, Ok)
            case TypeRef.InputObject(name, description, fields) =>
                declare(name, TypeDecl.InputDecl(name, description, fields), state, declared ->
                    List.foldLeft((accumulated, field) -> Result.flatMap(visit(field#typeRef), accumulated), Ok(declared), fields))
            case TypeRef.Object(inner) =>
                let fields = (inner#fields)();
                declare(inner#name, TypeDecl.ObjectDecl({ name = inner#name, description = inner#description, interfaces = inner#interfaces, fields = fields }), state, declared ->
                    List.foldLeft((accumulated, field) -> Result.flatMap(visitField(field), accumulated), Ok(declared), fields))
            case TypeRef.Union(inner) =>
                declare(inner#name, TypeDecl.UnionDecl({ name = inner#name, description = inner#description, members = List.map(TypeRef.bareName, inner#members) }), state, declared ->
                    List.foldLeft((accumulated, member) -> Result.flatMap(visit(member), accumulated), Ok(declared), inner#members))
            case TypeRef.Interface(inner) =>
                declare(inner#name, TypeDecl.InterfaceDecl({ name = inner#name, description = inner#description, fields = inner#fields, members = List.map(TypeRef.bareName, inner#members) }), state, declared ->
                    List.foldLeft((accumulated, field) -> Result.flatMap(visitInfo(field), accumulated), Ok(declared), inner#fields)
                        |> Result.flatMap(afterFields -> List.foldLeft((accumulated, member) -> Result.flatMap(visit(member), accumulated), Ok(afterFields), inner#members)))
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
        visitInfo(field#info, state)

    ///
    /// フィールドの情報から引数の型と戻り値の型を辿る。
    ///
    def visitInfo(info: FieldInfo, state: VisitState): Result[String, VisitState] =
        List.foldLeft((accumulated, arg) -> Result.flatMap(visit(arg#typeRef), accumulated), Ok(state), info#args)
            |> Result.flatMap(visit(info#typeRef))

    ///
    /// schema { query: ... mutation: ... } のブロック。
    ///
    def schemaBlock(inner: { queryType = RootType, mutationType = Option[RootType] }): String =
        let mutationLine = inner#mutationType |> Option.map(m -> "\n  mutation: ${m#name}") |> Option.getWithDefault("");
        "schema {\n  query: ${inner#queryType#name}${mutationLine}\n}"

    ///
    /// type / enum / input / union / interface の宣言ブロック。
    ///
    def declBlock(decl: TypeDecl): String = match decl {
        case TypeDecl.InputDecl(name, description, fields) =>
            let body = fields |> List.map(field -> "  ${argText(field)}") |> List.join("\n");
            "${typeDescription(description)}input ${name} {\n${body}\n}"
        case TypeDecl.ObjectDecl(inner) =>
            let body = inner#fields |> List.map(field -> fieldLine(field#info)) |> List.join("\n");
            let implements = if (List.isEmpty(inner#interfaces)) "" else " implements " + List.join(" & ", inner#interfaces);
            "${typeDescription(inner#description)}type ${inner#name}${implements} {\n${body}\n}"
        case TypeDecl.UnionDecl(inner) =>
            "${typeDescription(inner#description)}union ${inner#name} = ${List.join(" | ", inner#members)}"
        case TypeDecl.InterfaceDecl(inner) =>
            let body = inner#fields |> List.map(fieldLine) |> List.join("\n");
            "${typeDescription(inner#description)}interface ${inner#name} {\n${body}\n}"
        case TypeDecl.EnumDecl(name, description, values) =>
            let body = values |> List.map(enumValueLine) |> List.join("\n");
            "${typeDescription(description)}enum ${name} {\n${body}\n}"
        case TypeDecl.ScalarDecl(name) => "scalar ${name}"
    }

    ///
    /// GraphQL が最初から持つスカラー。SDL に宣言しない。
    ///
    pub def builtinScalars(): List[String] = "Int" :: "Float" :: "String" :: "Boolean" :: "ID" :: Nil

    ///
    /// 型の description。あれば宣言の直前の行に出す。
    ///
    def typeDescription(description: Option[String]): String =
        description |> Option.map(text -> "${stringLiteral(text)}\n") |> Option.getWithDefault("")

    ///
    /// enum 値 1 行。フィールドと同じく description は直前の行、deprecated は末尾。
    ///
    def enumValueLine(value: EnumValueInfo): String =
        let description = value#description |> Option.map(text -> "  ${stringLiteral(text)}\n") |> Option.getWithDefault("");
        "${description}  ${value#name}${deprecatedText(value#deprecated)}"

    ///
    /// @deprecated の末尾表記。無ければ空。
    ///
    def deprecatedText(deprecated: Option[Deprecation]): String =
        deprecated |> Option.map(deprecation -> match deprecation {
            case Deprecation.Reason(text) => " @deprecated(reason: ${stringLiteral(text)})"
            case Deprecation.NoReason     => " @deprecated"
        }) |> Option.getWithDefault("")

    ///
    /// フィールド 1 行。description があれば直前の行に、deprecated があれば末尾に付く。
    ///
    /// WhyNot: description を """ """ のブロック文字列で出さないのは、本文に """ が入ると
    /// エスケープが要り、通常の文字列リテラル（JSON と同じエスケープ）なら JsonValue に任せられるため。
    ///
    def fieldLine(info: FieldInfo): String =
        let description = info#description |> Option.map(text -> "  ${stringLiteral(text)}\n") |> Option.getWithDefault("");
        "${description}  ${info#name}${argsBlock(info#args)}: ${TypeRef.toSdl(info#typeRef)}${deprecatedText(info#deprecated)}"

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
