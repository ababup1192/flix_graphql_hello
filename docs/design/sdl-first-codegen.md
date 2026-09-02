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

### 2. リゾルバ一式（生成されたレコード型に合わせる）

```flix
mod CalcResolvers {
    /// Query のうち Calc が担う分
    pub def add(_context: Context, a: Int32, b: Int32): Result[FieldError, Int32] = Ok(Calc.add(a, b))
}

mod AppSchema {
    pub def make(runStore: Counter.StoreRunner): Schema =
        Generated.schema({
            queryRoot    = queryResolvers(runStore),
            mutationRoot = mutationResolvers(runStore),
            post         = postResolvers(),
            author       = authorResolvers()
        })

    /// 型ごとに注釈付きで作る（規約。型エラーをこの型の中に閉じ込めるため）
    def queryResolvers(runStore: Counter.StoreRunner): Generated.QueryResolvers = {
        add     = (context, a, b) -> CalcResolvers.add(context, a, b),
        post    = (_context, id) -> Ok(Post.find(id)),
        counter = _context -> runStore(() -> CounterStore.load())
    }

    def postResolvers(): Generated.PostResolvers = {
        id     = (_context, post) -> Ok(post#id),
        title  = (_context, post) -> Ok(post#title),
        author = (_context, post) -> Post.findAuthor(post#authorId) |> Option.toOk("author not found")
    }
}
```

**規約 1: レコードの値は必ずラムダで書く。** `add = CalcResolvers.add` のように純粋な def を
そのまま置くと、`--Xsubeffecting=lambdas` はラムダにしか効かないので `\ IO` に広がらず
コンパイルエラー（E6218）になる。ラムダで包めば通る。

**規約 2: 型ごとに `def xxxResolvers(): Generated.XxxResolvers` を書き、注釈を付ける。**
1 つのレコードに全部書くと、型が 1 つ違うだけで `Resolvers` 全体（100 フィールドで 148 KB）が
エラーにダンプされる。型ごとに分ければその型の分だけになる。それでも「どのフィールドか」は
出ないので、Expected と Actual を見比べる（README に手順を書く）。

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

    /// type Query のリゾルバ一式
    pub type alias QueryResolvers = {
        add     = Context -> Int32 -> Int32 -> Result[FieldError, Int32] \ IO,
        post    = Context -> Id -> Result[FieldError, Option[Post]] \ IO,
        counter = Context -> Result[FieldError, Int32] \ IO
    }

    /// type Post のリゾルバ一式。第 2 引数が source
    pub type alias PostResolvers = {
        id     = Context -> Post -> Result[FieldError, Id] \ IO,
        title  = Context -> Post -> Result[FieldError, String] \ IO,
        author = Context -> Post -> Result[FieldError, Author] \ IO
    }

    /// 全型のリゾルバ。1 つでも欠けるとコンパイルエラー
    pub type alias Resolvers = {
        queryRoot = QueryResolvers, mutationRoot = MutationResolvers, post = PostResolvers, author = AuthorResolvers
    }

    pub def schema(resolvers: Resolvers): Schema =
        Schema.make(queryType(resolvers), Some(mutationType(resolvers)))

    def queryType(resolvers: Resolvers): ObjectType[Unit] =
        Schema.objectType("Query", () ->
            {
                let arg0 = Schema.arg("a", GqlCodec.int32());
                let arg1 = Schema.arg("b", GqlCodec.int32());
                Schema.fieldRaw("add", Arg.info(arg0) :: Arg.info(arg1) :: Nil, Out.int32(), (context, _root, args) ->
                    forM (v0 <- Arg.decode(arg0, args); v1 <- Arg.decode(arg1, args);
                          r  <- (resolvers#queryRoot#add)(context, v0, v1)) yield r)
            } ::
            ...)

    def postType(resolvers: Resolvers): ObjectType[Post] =
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
| リゾルバで `CounterStore` を剥がし忘れ | effect が `\ IO` に収まらない |
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
pub def fieldRaw(name: String, args: List[ArgInfo], out: Out[r], f: Context -> source -> Args -> Result[FieldError, r] \ IO): Field[source]
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
| object 型の description、enum 値の description | DSL に無い。**今回は黙って落とす**。DSL に足したら生成器も追随 |
| object 型・enum・enum 値の directive（enum 値の `@deprecated` を含む） | DSL に無いので Err（黙って落とさない） |
| `schema { query: X mutation: Y }` ブロック | ルート型名として読む。無ければ `Query` / `Mutation` |
| input 型、interface、union、Subscription、custom scalar、その他の directive、`extend` | **生成器がエラー**（未対応を黙って通さない） |
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
