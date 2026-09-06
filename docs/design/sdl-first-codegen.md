# 設計: SDL を正にして、Flix の型付きスキーマを生成する

状態: 実装済み（2026-09-02）。レビューの結論は「条件付き賛成」で、条件（予約語、純粋 def の参照、
エラーの読みにくさ）は反映して実装した。実装との差分: `schema { }` ブロックが無いときの Mutation は
`type Mutation` が定義されているときだけ既定にする。実装後のレビュー（70 点）で見つかった穴を反映済み:
Float の既定値は `toPlainString`、フィールド名は小文字始まり・型名は大文字始まりを生成器が検査、
ルートから届かない型は Err、`subscription` と `@deprecated` 以外の directive と `extend` は Err、
生成器バージョンの照合は本体側の `GeneratedCheck.expectedGeneratorVersion` で行う。
再レビュー（79 点）の反映: 型・enum・enum 値の directive と `extend schema` も Err、`type Subscription` は
「未対応」と伝える、`ObjectType` など生成物が裸で使う名前を禁止、ハッシュをやめて SDL 本文を生成物に埋める
（`SdlHash` の複製を廃止）、`Option[Option[String]]` を `Deprecation` enum にする。
前段の設計は [typed-schema.md](typed-schema.md)（実装済み）。

## 目的

typed-schema で「スキーマとリゾルバのズレがコンパイルで落ちる」は達成した。
残った問題は、人が書く `queryFields()` が SDL と 1 対 1 に読めないこと。

```flix
field2("add", arg("a", GqlCodec.int32()), arg("b", GqlCodec.int32()), Out.int32(),
    (_context, _root, a, b) -> Ok(Calc.add(a, b))) ::
```

型を 2 回書き、`field2` / `::` / `Out.option(Out.obj(…))` という Flix の都合が表に出て、
`type Query` の全体像が 1 か所に無い。Flix には macro も型クラスの自動導出も無いので、
DSL を SDL に似せるには上限がある。

そこで **人が読み書きするのは SDL とリゾルバ本体だけ** にし、typed-schema の DSL は
生成物の中に閉じ込める。ズレの検出はコンパイラに任せたまま、書く物を減らす。

## 人が書く物

### 1. `schema.graphql`（正）

```graphql
type Query {
  add(a: Int!, b: Int!): Int!
  post(id: ID!): Post
  counter: Int!
}

type Post {
  id: ID!
  title: String!
  author: Author!
}

type Mutation {
  increment(by: Int!): Int!
}
```

### 2. リゾルバ（`make scaffold` の雛形にフィールドごとの関数を書く）

```flix
/// リゾルバが使う効果の和（利用側の規約。Resolvers[ef] の ef はレコード全体で 1 つ）
pub type alias AppEff = CounterStore

/// src/sample/resolvers/PostResolvers.flix。make scaffold が作り、人が所有する
mod PostResolvers {
    /// Post.author
    pub def author(): Generated.PostAuthorResolver[AppEff] =
        (_context, post) -> Post.findAuthor(post#authorId) |> Option.toOk("author not found")

    /// type Post のリゾルバ一式。id / title / status は既定リゾルバが source の同名ラベルを返す
    pub def resolvers(): Generated.PostResolvers[AppEff] =
        { +author = author() | Generated.postDefaults() }
}

mod AppSchema {
    /// runApp が AppEff を IO に落とす。ハンドラを渡すのはここ 1 回
    pub def make(runApp: Runner[AppEff]): Schema =
        Generated.schema({
            queryRoot    = QueryResolvers.resolvers(),
            mutationRoot = MutationResolvers.resolvers(),
            post         = PostResolvers.resolvers(),
            author       = AuthorResolvers.resolvers()
        }, runApp)
}
```

**規約 1: 効果が `AppEff` と一致しない def はラムダで包む。** `add = CalcResolvers.add` のように純粋な def を
そのまま置くと、`--Xsubeffecting=lambdas` はラムダにしか効かないので `\ AppEff` に広がらず
コンパイルエラー（E6218）になる。ラムダで包めば通る。効果がちょうど `AppEff` の def は参照のままで通る。

**規約 2: フィールドごとに `def author(): Generated.PostAuthorResolver[AppEff]` を書き、注釈を付ける。**
レコードに直接ラムダを書くと、型が 1 つ違うだけで `Resolvers` 全体（100 フィールドで 148 KB）が
エラーにダンプされ「どのフィールドか」が出ない。フィールドごとの関数なら、エラーはその関数の行に出る。
`make scaffold` の雛形はこの形。

### 3. オブジェクト型の Flix 側の型（source）

SDL の `type Post` に対応する Flix の型 `Post` を人が定義する。名前を揃えるのが規約で、
生成物は `Post` という名前で参照するだけ。無ければ「未定義の型」でコンパイルエラー。

```flix
pub type alias Post = { id = Id, title = String, authorId = Id }
```

SDL に無いフィールド（`authorId`）を持ってよい。生成物は SDL にあるフィールドのリゾルバしか要求しない。

**規約 3: トップレベルの `pub type alias`（または `pub enum`）で定義する。** `mod` の中に置くと
生成物から解決できない。

**禁止する SDL の型名:** 生成物が使う Flix の名前と衝突する `Schema` `Context` `Field` `Out` `Value`
`Id` `Arg` `Option` `Result` `List` `Map` `Unit` `Generated`。生成器がエラーにする。

## 生成する物（`src/generated/GeneratedSchema.flix`）

生成物は typed-schema の DSL（`Schema.field*` / `Out` / `GqlCodec` / `objectType`）で書かれた
普通の Flix コードで、人は読まない。

```flix
/// このファイルは schema.graphql から生成した物。手で編集しない。
mod Generated {

    /// 生成元の SDL 本文。テストと起動時に schema.graphql と照合する
    pub def sdlText(): String = "…"

    /// Query.add
    pub type alias QueryAddResolver[ef: Eff] = Context -> Int32 -> Int32 -> Result[FieldError, Int32] \ ef
    /// Post.author
    pub type alias PostAuthorResolver[ef: Eff] = Context -> Post -> Result[FieldError, Author] \ ef

    /// type Query のリゾルバ一式。ef はリゾルバの効果
    pub type alias QueryResolvers[ef: Eff] = { add = QueryAddResolver[ef], post = QueryPostResolver[ef], counter = QueryCounterResolver[ef] }

    /// type Post のリゾルバ一式。第 2 引数が source
    pub type alias PostResolvers[ef: Eff] = { id = PostIdResolver[ef], title = PostTitleResolver[ef], author = PostAuthorResolver[ef] }

    /// type Post の既定リゾルバ。source の同名ラベルをそのまま返す。author は含まない
    pub def postDefaults(): {
        id    = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef,
        title = Context -> { title = String | r1 } -> Result[FieldError, String] \ ef
    } = { id = (_context, src) -> Ok(src#id), title = (_context, src) -> Ok(src#title) }

    /// 全型のリゾルバ。1 つでも欠けるとコンパイルエラー。ef は全リゾルバで共有する 1 つの効果
    pub type alias Resolvers[ef: Eff] = {
        queryRoot = QueryResolvers[ef], mutationRoot = MutationResolvers[ef], post = PostResolvers[ef], author = AuthorResolvers[ef]
    }

    /// runner が ef を IO に落とす
    pub def schema(resolvers: Resolvers[ef], runner: Runner[ef]): Schema =
        Schema.make(queryType(resolvers), Some(mutationType(resolvers)), runner)

    def queryType(resolvers: Resolvers[ef]): ObjectType[Unit, ef] =
        Schema.objectType("Query", () ->
            {
                let arg0 = Schema.arg("a", GqlCodec.int32());
                let arg1 = Schema.arg("b", GqlCodec.int32());
                Schema.fieldRaw("add", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.int32(), (context, _root, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args);
                          r  <- (resolvers#queryRoot#add)(context, v0, v1)) yield r)
            } ::
            ...)

    def postType(resolvers: Resolvers[ef]): ObjectType[Post, ef] =
        Schema.objectType("Post", () ->
            Schema.field0("author", Out.obj(authorType(resolvers)), (context, post) -> (resolvers#post#author)(context, post)) :: ...)
}
```

- ルート型のリゾルバは source（`Unit`）を受けない。生成物が `_root` を捨てる
- `Resolvers` のルートのラベルは `queryRoot` / `mutationRoot` の固定名。`query` は Flix の予約語で
  レコードのラベルに使えない（実験で確認）
- 相互参照（Post ⇄ Author）は typed-schema と同じく thunk で解決する。全型のリゾルバを
  1 つの `Resolvers` レコードで持ち回るので、`postType` から `authorType` を呼べる
- description / deprecated / 引数の既定値は SDL から読んで生成物に載せる（`Field.withDescription` 等）
- enum は Flix の `enum` と `GqlCodec.enumOf` を **生成する**（`enum Color { case Red case Blue }`、
  `RED` → `Red` の名前変換は先頭大文字・残り小文字）。人は生成された enum を使う

### 識別子のエスケープ

SDL のフィールド名・型名・引数名が Flix の予約語（`from` `run` `select` `where` `project`
`force` `into` `type` `query` など 43 語。一覧は flix_game_engine の `bin/lint-rules/flix-reserved.json`）
の時は、生成器が末尾に `_` を付ける（`from` → `from_`）。レコードのラベルにも関数の引数にも効く事を
実験で確認した。生成物の中のラムダ引数名は生成器が `arg0, arg1, …` と機械的に付け、SDL 名と衝突させない。

## コンパイルで落ちる物

| ズレ | 何で落ちるか |
|---|---|
| SDL にフィールドを足したがリゾルバが無い | レコードのフィールド不足 |
| SDL から消したのにリゾルバが残っている | レコードの余分なフィールド |
| 引数の型・個数、戻り値の型が SDL と違う | 関数型の不一致 |
| ある型のリゾルバ一式を丸ごと書き忘れ | `Resolvers` のフィールド不足 |
| SDL の `type Post` に対応する Flix の `Post` が無い | 未定義の型 |
| リゾルバが `AppEff` に無い effect を使う | effect が `\ AppEff` に収まらない |
| source の型に既定リゾルバが要るラベルが無い（Option の有無も含む） | `resolvers()` の行で `( )` と `( title = String | r0 )` の不一致 |
| 生成し忘れ（SDL だけ変えた） | テスト `sdlText` の不一致。加えて `main` が起動時に照合し、不一致なら起動を拒否 |

「足りない」だけでなく「余っている」も落ちるのが、生成物が関数を名前で呼びに行く方式との差。

## 生成器

### 置き場: 別プロジェクト `schemagen/`

```
schemagen/
  flix.toml        graphql-java だけに依存
  src/Main.flix    SDL を読み、GeneratedSchema.flix を書く
```

**WhyNot: 本体と同じプロジェクトに入れないのは**、生成物が壊れていると本体がコンパイルできず、
コンパイルできないと生成し直せない、という循環を避けるため。別プロジェクトなら
生成物の状態に関係なく `make generate` が動く。`bin/flix` は cwd を変えて使い回す。

### 入力の読み方

graphql-java の `graphql.parser.Parser.parseDocument(sdl)` で `Document` を得て、
`getDefinitions()`（`List[Definition]`）を `Class.isInstance` で
`ObjectTypeDefinition` / `EnumTypeDefinition` に振り分ける。

**WhyNot: `SchemaParser` → `TypeDefinitionRegistry` を使わないのは**、`getType` の戻りが
`Optional<TypeDefinition<?>>` で Flix から型を決めにくいため（typed-schema でも同じ理由で
`GraphQLSchema` 側を使った）。`Document.getDefinitions()` は具象の `List` で受けられる。

### 型の対応

| SDL | Flix の型 | 引数の Codec | 戻り値の Out |
|---|---|---|---|
| `Int` | `Int32` | `GqlCodec.int32()` | `Out.int32()` |
| `Float` | `Float64` | `GqlCodec.float64()` | `Out.float64()` |
| `String` | `String` | `GqlCodec.string()` | `Out.string()` |
| `Boolean` | `Bool` | `GqlCodec.bool()` | `Out.bool()` |
| `ID` | `Id` | `GqlCodec.id()` | `Out.id()` |
| `enum E` | 生成した `E` | 生成した `eCodec()` | `Out.scalar(eCodec())` |
| `type T` | 人が定義した `T` | （引数には使えない） | `Out.obj(tType(resolvers))` |
| `[X]` | `List[X]` | `GqlCodec.list(…)` | `Out.list(…)` |
| nullable | `Option[X]` | `GqlCodec.option(…)` | `Out.option(…)` |

`T!`（non-null）が既定で、`!` が無ければ `Option` に包む。SDL の書き方と Flix の書き方で
nullable の既定が逆なので、生成器がここを吸収する。

### 引数の個数

DSL の `field0..3` は 3 個まで。生成器は個数に関係なく書けるよう、`Schema` に
「引数を `Args` のまま受け、生成物側でデコードする」`fieldRaw` を足し、**生成器は個数に関係なく
常に `fieldRaw` を使う**（生成器のコードパスを 1 本にする）。

```flix
pub def fieldRaw(name: String, args: List[ArgInfo], out: Out[r, ef], f: Context -> source -> Args -> Result[FieldError, r] \ ef): Field[source, ef]
```

生成物は `let a = Schema.arg(...)` を束ねてから `Arg.info(a) :: …` と `Arg.decode(a, args)` を
`forM` で並べる。`field0..3` は人が DSL を直接書く時のために残す。

### enum の名前変換

SDL の値名を `_` で区切り、各区切りを先頭大文字・残り小文字にする（`RED` → `Red`、
`IN_PROGRESS` → `InProgress`、`HTTP_2` → `Http2`）。変換後に衝突する（`AB` と `Ab`）、
先頭が数字になる、のどちらも生成器がエラーにする。SDL 名への戻し（`toName`）は生成物に
match を吐く（`case Color.Red => "RED"`）。

### DSL に無い SDL の要素

| 要素 | 扱い |
|---|---|
| フィールド・引数の description、`@deprecated`（reason 無しも）、引数の既定値 | 生成物に載せる。既定値は AST の `Value` を `Value` へ変換し `Arg.withDefaultValue(value: Value)` に渡す。reason 無しは `Field.deprecate` |
| object / enum / input 型の description、enum 値の description と `@deprecated` | 生成物に載せる（`ObjectType.withDescription`、`GqlCodec.describe` / `describeValue` / `deprecateValue`）。enum 値の description は `case` の doc コメントにもなる |
| object 型・enum・input・enum 値の directive（enum 値の `@deprecated` 以外） | DSL に無いので Err（黙って落とさない） |
| `schema { query: X mutation: Y }` ブロック | ルート型名として読む。無ければ `Query` / `Mutation` |
| input 型 | レコード型の別名と `GqlCodec.inputObject` の Codec。フィールドは引数と同じ `Arg` で組み `Arg.decodeField` で取り出す（エラー文が `argument 'input' must be PostInput!: field 'status' must be …` とつながる）。オブジェクト型の参照・input 同士の循環・戻り値での使用・空の input は Err |
| union、interface | 枝（実装型）ごとの case を持つ Flix の enum と `Out.union` / `Out.interface`。TypeResolver は箱に付けた型名のタグで解決する。詳細は「union と interface（段 4）」 |
| Subscription、custom scalar、その他の directive、`extend`、interface の implements | **生成器がエラー**（未対応を黙って通さない） |
| ルート型から届かない型 | **生成器がエラー**（生成物の未使用関数で本体が落ちるより、SDL の書き間違いとして止める） |
| 大文字始まりのフィールド名・引数名、小文字始まりの型名 | **生成器がエラー**（Flix の識別子の決まりに合わない） |

### 実装メモ（Flix からの graphql-java）

- `List<Definition>` は `JList[Definition[Object]]`、`getDefaultValue()` は `Value[Object]` と
  型引数を付けないと E3692 で落ちる
- `Description` は null になり得るので `Objects.isNull` で判定
- `@deprecated` は `Directive.getArguments()` から `reason` を読む
- 既定値の文字列化は `AstPrinter.printAstCompact`

### 生成器のテスト

本体側から生成器は呼べないので、`schemagen/test/` に「SDL → 生成物のスナップショット」テストを
置く。小さな SDL（scalar、enum、nullable、list、相互参照、既定値、description、予約語）ごとに
期待する Flix ソースを比較する。

## 生成し忘れの検出

生成物に、改行を LF に正規化した SDL 本文を `Generated.sdlText()` として、生成器の版を
`Generated.generatorVersion()` として埋める。本体の `GeneratedCheck.check` が `schema.graphql` の本文との
一致と、本体が期待する版 `GeneratedCheck.expectedGeneratorVersion()` との一致を見る（生成物に埋まった版で
自分を検証すると、生成器を直しても再生成が要求されないため）。生成器の `Emit.generatorVersion` と一緒に上げる。
テストと `main` の起動時の両方で照合し、不一致なら日本語のメッセージを出して終了コード 1 で止まる。
当初は SHA-256 を埋めていたが、本体と生成器で同じ計算を 2 か所に持つ事になるので本文の埋め込みに変えた。

typed-schema の `testSchemaFileIsUpToDate`（DSL → SDL の向き）は役目が逆になるので消す。
`generated/schema.graphql` と `make schema` も消し、`schema.graphql` はリポジトリ直下に置く。

## 評価

- 型安全性: typed-schema と同じ物がコンパイルで落ちる。加えて「余っているリゾルバ」も落ちる
- 開発者負担: 人が書くのは SDL とレコード。`field*` / `arg` / `Out` / `::` は人のコードから消える。
  フィールド追加は「SDL に 1 行、レコードに 1 行、`make generate`」
- 拡張性: 生成器は SDL の構文ごとに DSL の呼び出しを 1 つ吐くだけなので、DSL 側に機能が
  入れば生成器の対応は薄い。enum を最初から入れるのは、生成物として一番割に合うため
- エレガントさ: レコードの `{ add = …, post = … }` は SDL の `type Query { add … post … }` と
  並びが揃う。生成物は読まない前提なので長くてよい
- Flix での実現性: 生成物は今の DSL で書ける事を typed-schema で確かめ済み。
  要検証は (1) `Parser.parseDocument` と `Document.getDefinitions()` の Flix からの扱い、
  (2) `Resolvers` のような入れ子レコードの型エイリアスと `resolvers#query#add` の呼び出し、
  (3) 大きなレコード型でのコンパイル時間

## 移行の段取り

1. `Schema.fieldRaw` を足す
2. `schemagen/` を作り、`schema.graphql` → `src/generated/GeneratedSchema.flix` を吐く
3. `AppSchema.make` を `Generated.schema({ … })` に置き換え、`CalcFields` / `PostFields` /
   `Counter.queryFields` を「リゾルバ関数」に薄くする
4. `generated/schema.graphql` と `make schema` を消し、`sdlHash` のテストを足す
5. README と docs/design/typed-schema.md の状態を更新する

## レビューで決めた事

- 生成物は `src/generated/` に置いてコミットする。Flix は `src/` 以下しか見ないのでここしかなく、
  差分がレビューで見える
- 生成器は別プロジェクト `schemagen/`。同居させると壊れた生成物で生成器も動かなくなる循環が
  本当に起きる。`make generate` は `cd schemagen && ../bin/flix run`。入出力は `../schema.graphql` と
  `../src/generated/GeneratedSchema.flix` の固定パス
- `Resolvers` は入れ子レコード 1 つ。型のリゾルバ一式を丸ごと書き忘れた事が「ラベル不足」で出て、
  型が増えても `schema` の署名が変わらない。ただし規約 2（型ごとに注釈付きの def）とセット
- リゾルバの純粋 def は `--Xsubeffecting=mod-defs` を足せば参照できるが、フラグ依存を増やさず
  規約 1（ラムダで包む）で行く

## リゾルバの effect 多相（段 0）

生成物のリゾルバ型は `\ IO` 固定ではなく効果変数 `ef` を持つ。実装側は `AppEff`（効果の和の別名）で
全リゾルバを書き、`Generated.schema(resolvers, runner)` に `Runner[AppEff]` を 1 回渡す。

- `Runner[ef] = (Unit -> Result[FieldError, JavaValue.Boxed] \ ef + IO) -> Result[FieldError, JavaValue.Boxed] \ IO`。
  戻り型を箱に固定するのは、型別名が自由な型変数を持てず rank-2 型も無いため
  （`(Unit -> a \ ef) -> a \ IO` は `Undefined type variable 'a'`）
- 効果変数は `Field[source, ef]` / `ObjectType[a, ef]` / `Out[a, ef]` に通し、`TypeRef` には通さない。
  `Out` の `typeRef` は `Runner[ef] -> TypeRef` の遅延で持ち、`Schema.make(query, mutation, runner)` が
  型消去する時に確定する。`TypeRef` に通すと `ArgInfo` / `FieldInfo` / `GqlCodec` まで変数が広がる
- `ef` はレコード全体で 1 つ。`PostResolvers[CounterStore]` と `AuthorResolvers[Clock]` は
  `Resolvers[CounterStore + Clock]` に入らない（subeffecting は型の付いた値には効かない）。
  利用側は `AppEff` 1 つで書く
- ハンドラは graphql-java のコールバック（別スレッドを含む）の中で走る。SqliteCounter は
  呼び出しごとに Connection を開くのでスレッドの心配は無い

## 書き味（段 1）

- **既定リゾルバ** `Generated.postDefaults()`。引数が無くスカラー・enum・そのリストを返すフィールドの分だけ、
  source の同名ラベルを返すレコードを生成する。source の型は `{ id = Id | r0 }` の行変数で開いており、
  `PostResolvers[ef]` と合わせた時に残りのラベルに決まる。効果も `\ ef` の自由変数で、利用側の `AppEff` に決まる。
  ルート型と、素通しのフィールドが無い型には作らない
- **フィールド単位の別名** `Generated.PostAuthorResolver[ef: Eff]`。`XResolvers` のレコード型はこの別名で組む。
  利用側がフィールドごとの関数に注釈すると、型違いのエラーがその関数の行に出る。名前の末尾に `Resolver` を
  付けるのは `Post.status` → `PostStatus` が enum と衝突するため。型名が生成する別名と衝突する SDL と、
  別名が重複する SDL（`Post.authorName` と `PostAuthor.name`）は生成器が Err にする
- **雛形** `make scaffold [TYPE=X] [DEFAULTS=no]`。`src/sample/resolvers/XResolvers.flix` に、素通しでないフィールドの
  空の関数と `{ +author = author() | Generated.postDefaults() }` の `resolvers()` を書く。既にあるファイルは
  触らない（人が所有する）。`DEFAULTS=no` は source が enum の型向けで、全フィールドを空の関数にする。
  `flix run` はプログラム引数を受け取れないので、モードと型名は環境変数で渡す
- 型が 1 つだけ既定を上書きしたいときは `{ id = …, +author = … | Generated.postDefaults() }` の更新構文

## input 型（段 2）

- DSL: `TypeRef.InputObject(name, description, List[ArgInfo])` と `TypeDecl.InputDecl`。`collectTypes` は引数の型も辿るので
  input はルート型から引数経由で届く。SDL 出力は `input X { … }` で、各行は引数と同じ `argText`
- `GqlCodec.inputObject(name, infos, build)`。decode は `Value.Obj` のときだけ `build(fields)`、それ以外は
  `expected X`。encode は `Value.Null`（input は引数専用で Flix の値から戻す場面が無い。既定値は
  `Arg.withDefaultValue` で Value のまま渡す）
- 生成物: `pub type alias PostInput = { … }` と `postInputCodec()`。フィールドは `Schema.arg` で組み、
  `forM` に `Arg.decodeField` を並べてレコードにする。ネストした input は Codec の呼び出しで再帰する
- 生成器の検査: input 内のオブジェクト型参照、input 同士の循環（Flix のレコードの別名は再帰できない）、
  input を戻り値に使う、フィールドの無い input、はどれも Err。禁止名・大小文字・到達性は object と同じ規則
- 引数の既定値にオブジェクトリテラルを書くのは未対応（`対応していない既定値です: ObjectValue`）。対応するなら
  `Schema.literal` がオブジェクトの中の enum 値を引用符付きで出す問題も一緒に直す（TypeRef で型付きにする）
- graphql-java は input のフィールドの型を validation で検査するので、`decodeField` の Err が実行時に
  出るのは Int → Float のように graphql-java が通す変換だけ。エラー文の形は `TestGqlCodec` で確かめる

## 説明と deprecated を型に載せる（段 3）

- `TypeRef.Object / Enum / InputObject` が description を持ち、enum の値は `EnumValueInfo`（名前・description・deprecated）。
  `TypeDecl` も同じ形で、SDL 出力は型の直前の行に description、enum 値はフィールドと同じ書式
- DSL: `ObjectType.withDescription`、`GqlCodec.describe`（enum / input）、`GqlCodec.describeValue` / `deprecateValue`。
  値は SDL 名でなく Flix の値で受ける（存在しない case はコンパイルで落ち、名前の打ち間違いが素通りしない）
- 生成器: enum 値の `@deprecated` を Err から外した。他の directive は引き続き Err

## union と interface（段 4）

- Flix 側の表現は枝（実装型）ごとの case を持つ enum（`pub enum SearchResult { case Post(Post) case Author(Author) }`）。
  trait にしないのは、生成物が trait と instance を吐くと利用側の型ごとに instance を書かせる事になるため
- DSL: `TypeRef.Union` / `TypeRef.Interface`（レコード）、`TypeDecl.UnionDecl` / `InterfaceDecl`、`Out.union(name, members, encode)`、
  `Out.interface(name, fields, members, encode)`、`Out.member(objectType)`（型消去した枝の参照）、`Out.taggedObj`、
  `Schema.abstractField`（interface のフィールドの形だけ。resolve は呼ばれない）、`ObjectType.implementing`
- 型名の届け方: `Out.taggedObj` が `JavaValue.tag(型名, 箱)` で `SimpleImmutableEntry` に包む。`Field.erase` の unbox が
  `untag` で剥がし、`Graphql.typeResolver` がタグを読んで `getObjectType(型名)` を返す。入れ物に Flix の enum を使わないのは
  Java 側から instanceof で見分けるのに JVM のクラス名が決まっていないため
- TypeResolver の登録: `GraphQLCodeRegistry.typeResolver` は graphql-java 22 の SchemaTypeChecker が見ないので不可。
  `RuntimeWiring.Builder.type` は `type` が Flix の予約語で呼べず、`WiringFactory` の無名クラスは Flix 0.75.3 の
  オーバーロード解決の内部エラーになる。`TypeRuntimeWiring` を作って MethodHandle で `type` を呼ぶ
- interface の宣言はそれを返すフィールドから辿って SDL に出す（オブジェクト側の `implements` は名前だけ）。
  そのため、どのフィールドの型にも使われない union / interface は生成器が Err にする。実装型は interface から
  members として辿るので、フィールドから届かなくても到達扱い
- 生成器の検査: union の枝はオブジェクト型で重複なし、interface は実装型が 1 つ以上、実装型が interface の全フィールドを
  同じ名前・型・引数で持つ（description と既定値は問わない）、implements 先が interface、union / interface は引数に使えない

## レビューの実験結果（要点）

| 項目 | 結果 |
|---|---|
| `Parser.parse` → `Document.getDefinitions()` から object / enum / field / 引数 / 型 / description / `@deprecated` / 既定値 / input を読む | 通る |
| 入れ子レコード alias と `(resolvers#queryRoot#add)(…)`、純粋ラムダの配置、実行 | 通る |
| ラベル不足 / 余分 / effect 漏れ / 未定義型 | それぞれ読めるエラーで落ちる |
| 型違い・引数個数違い | 落ちるが `Resolvers` 全体をダンプ（規約 2 で緩和） |
| `query` ラベル | パースエラー（`queryRoot` に変更） |
| 純粋 def の参照 | E6218（規約 1 で回避） |
| 5 型 × 20 フィールドの check | 4.5 秒。本体の 4.0 秒と実質差なし |
| 相互参照の thunk 内呼び出し | 通る。往復クエリも実行できた |
