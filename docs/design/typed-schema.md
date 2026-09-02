# 設計: スキーマとリゾルバの型安全化

状態: 実装済み（2026-09-02）。その後 [sdl-first-codegen.md](sdl-first-codegen.md) で、この DSL は
生成物の中に閉じ込め、人は SDL とリゾルバのレコードを書く形に変えた。レビューの結論は「案 B に条件付き賛成」で、条件は反映して実装した。
実装との差分: Context は graphQLContext ではなく source に相乗りさせて箱詰めする（決定事項 8 を修正）。
`make schema` はコマンドライン引数ではなく環境変数 FLIX_GRAPHQL_COMMAND で切り替える（flix run が引数を受けないため）。

## 目的

今の設計は schema-first で、`("Query", "add")` の文字列でリゾルバを登録し、
引数と戻り値は untyped の `Value`（JSON 相当）で受け渡す。ズレは起動時検証でしか
分からず、引数のデコードは各リゾルバが手書きしている。

目標は Scala の Caliban と同等の性質: **スキーマとリゾルバのズレが構造上あり得ず、
引数・戻り値・親オブジェクト（source）が Flix の型で扱える**こと。
ただし型安全性だけを追わず、開発者負担・拡張性・コードのエレガントさも同じ重みで見る。

## 評価軸

| 軸 | 見る物 |
|---|---|
| 型安全性 | 何がコンパイルで落ち、何が起動時、何が実行時に残るか |
| 開発者負担 | フィールドを 1 つ足すときに触る場所の数と行数。学習コスト |
| 拡張性 | source と context の導入、Mutation、ネスト、List / Option / enum / input 型、Subscription、DataLoader |
| エレガントさ | 読んで意図が分かるか。ボイラープレートと魔法の量 |
| Flix での実現性 | 型クラスの自動導出が無い、macro が無い、effect が Java コールバックをまたげない、という制約の下で書けるか |

## 案 A: Schema 駆動の codegen（SDL → Flix を生成）

`schema.graphql` を正とし、外部スクリプトで `Generated.flix` を吐く。生成物は
フィールドごとの引数レコード（`{ a = Int32, b = Int32 }`）とそのデコーダ、
（型名, フィールド名）の定数、戻り値のエンコーダ。

- 型安全性: 引数の型は通る。**登録漏れ・登録先の間違いは残る**。戻り値は `Value` のまま。
- 開発者負担: SDL 編集 → 生成 → 実装の 3 段。生成忘れが新しいズレの源になる。生成器を別言語で書くので、リポジトリに 2 つ目の言語が入る。
- 拡張性: SDL に書ける物は全部扱える。source は「親の型の生成レコード」で渡せる。
- エレガントさ: 生成物を読む必要が出る。手書き側は薄い。
- Flix での実現性: 問題なし。

## 案 B: Code-first の型付き DSL（Flix の値からスキーマを導く）

スキーマを Flix の値として組み立て、SDL と DataFetcher の両方をその値から作る。
`schema.graphql` は出力物になる。

### 部品

```flix
/// scalar / enum / input 型: Flix の値 <-> Value の相互変換と GraphQL の型名
pub enum GqlCodec[a] { case GqlCodec({ typeRef = TypeRef, encode = a -> Value, decode = Value -> Result[String, a] }) }

/// ID scalar。String と型で区別する（取り違えをコンパイルで落とすため）
pub enum Id { case Id(String) }

/// 引数 1 つ。名前と Codec。description / default は withDescription 等で後付け
pub enum Arg[a] { case Arg({ name = String, codec = GqlCodec[a], description = Option[String], default = Option[Value] }) }

/// object 型。名前と、フィールド一覧の thunk（相互再帰を許すため）
pub enum ObjectType[a] { case ObjectType({ name = String, fields = Unit -> List[Field[a]] }) }

/// フィールドの戻り値の型記述。scalar は Value に潰し、object は Flix 値のまま子へ渡す
pub enum Out[a] {
    case Scalar(GqlCodec[a])
    case Obj(ObjectType[a])
    case ListOf(Out[b])      // a = List[b]
    case Nullable(Out[b])    // a = Option[b]
}

/// フィールド。source は親の Flix 型。resolve は引数のデコードから戻り値の箱詰めまでを閉じた関数
pub enum Field[source] {
    case Field({ name = String, typeRef = TypeRef, args = List[ArgDef], description = Option[String], deprecated = Option[String],
                 resolve = Context -> source -> Args -> Result[String, Object] \ IO })
}

pub def field0(name: String, out: Out[r], f: Context -> source -> Result[String, r] \ IO): Field[source]
pub def field1(name: String, a: Arg[a], out: Out[r], f: Context -> source -> a -> Result[String, r] \ IO): Field[source]
pub def field2(name: String, a: Arg[a], b: Arg[b], out: Out[r], f: Context -> source -> a -> b -> Result[String, r] \ IO): Field[source]
pub def field3(...)

pub def objectType(name: String, fields: Unit -> List[Field[a]]): ObjectType[a]
pub def schema(queryType: ObjectType[Unit], mutationType: Option[ObjectType[Unit]]): Schema
pub def toSdl(s: Schema): Result[String, String]
```

`Out[a]` の `ListOf` / `Nullable` は GADT 風の書き方になるので、実装では
`Out.list: Out[b] -> Out[List[b]]`、`Out.option: Out[b] -> Out[Option[b]]` の
スマートコンストラクタで型を縛る（enum 自体は内部表現）。

### 使う側

```flix
def queryType(): ObjectType[Unit] =
    objectType("Query", () ->
        field2("add", arg("a", GqlCodec.int32), arg("b", GqlCodec.int32), Out.scalar(GqlCodec.int32),
            (_ctx, _src, a, b) -> Ok(Calc.add(a, b))) ::
        field1("post", arg("id", GqlCodec.id), Out.option(Out.obj(postType())),
            (ctx, _src, id) -> Posts.find(ctx, id)) ::
        Nil)

def postType(): ObjectType[Post] =
    objectType("Post", () ->
        field0("id",     Out.scalar(GqlCodec.id),     (_ctx, post) -> Ok(post#id)) ::
        field0("title",  Out.scalar(GqlCodec.string), (_ctx, post) -> Ok(post#title)) ::
        field0("author", Out.obj(authorType()),       (_ctx, post) -> Authors.find(post#authorId)) ::
        Nil)
```

### 実行時の動き（graphql-java との対応）

- `Out.Scalar` のフィールドは、戻り値を `encode` で `Value` にし、`JavaValue.toObject` で Java に渡す。
- `Out.Obj` のフィールドは、**Flix の値を `unchecked_cast` で `Object` に箱詰めしてそのまま返す**。
  子フィールドの DataFetcher が `env.getSource()` で受け取り、`source` 型に戻す。
  これにより graphql-java の selection に従って子のリゾルバだけが走り、
  要求されていない `Post.author` の IO は起きない。DataLoader もこの遅延の上に乗る。
  （レビュー前の案は object 型を eager に `Value.Obj` へ潰していたため、selection を無視して
  全フィールドの IO が走る構造だった。これが最大の見落としで、修正済み）
- `Out.ListOf` / `Nullable` は上の 2 つを再帰的に適用する（`List` は Java の `List`、`None` は `null`）。
- Context はリクエスト単位で決まる物（userId 等）なので、`buildEngine` 時に閉じ込められない。
  `Graphql.execute(request, context)` で受け、root と各 source を `(Context, 値)` で箱詰めして
  子 DataFetcher が source から取り出す（実装時に graphQLContext 案から変更）。

### SDL 生成

- `TypeRef` を Query → Mutation の順に深さ優先で辿り、object 型は名前で重複排除する。
  fields が thunk なので相互再帰（Post ⇄ Author）で無限再帰しない。
- 同じ名前で中身が違う object 型（別モジュールが `"Post"` を 2 回定義）は `toSdl` が `Err` にする。
- 型名は `TypeRef` からだけ出す。SDL と DataFetcher 登録で文字列を 2 か所に持たない。
  これが introspection と実体を一致させる唯一の前提。
- nullable は `Option[a]` にだけ対応させ、それ以外は `!`。`Out.option(Out.option(...))` は
  `Out.option` が潰す（二重 Option は GraphQL に表現が無い）。

### 評価

- 型安全性: **登録漏れ・名前のズレ・引数の型・戻り値の型・source の型、すべてコンパイルで決まる。**
  SDL とリゾルバは同じ値から出るので、起動時検証（`validateResolvers` / `mergeResolvers`）は消える。
  Caliban に届かないのは 1 点、object 型の Codec を derive できず手書きする所。
- 開発者負担: フィールドを足すのは `field*` を 1 行足すだけ。学習コストは
  `GqlCodec` / `Arg` / `Out` / `Field` / `ObjectType` の 5 概念。
- 拡張性: source は型引数、context は第 1 引数。List / Option は `Out.list` / `Out.option`。
  enum は `GqlCodec.enumOf` で書けて、`TypeRef.Enum` から SDL の `enum` 宣言も出る。
  input 型は `TypeRef.Input` の case、`collectTypes` での宣言の収集、SDL 出力の 3 点を足す必要がある
  （enum で同じ 3 点を通したので道は付いている）。interface / union は `TypeRef` に case を足し、
  `__typename` を決める関数を持たせて graphql-java の `TypeResolver` に渡す。
  Subscription は戻りが `Publisher` になるので `Field` の別コンストラクタ。
- エレガントさ: スキーマの形がそのままコードの形になる。ボイラープレートは object 型の
  `GqlCodec`（input 型として使う場合のみ）と `Out.scalar(GqlCodec.int32)` の記述量。
  後者は `Out.int32` 等の短縮を用意する。

## 案 C: 折衷（SDL は正のまま、Flix 側で型付き登録 + 起動時照合）

SDL を残し、Flix 側は案 B の `field*` で型付きに登録する。起動時に SDL と登録を突き合わせて Err にする。

- 型安全性: 引数と戻り値は型が通るが、SDL との対応は起動時検証のまま。
- 開発者負担: SDL と Flix の両方を編集する。二重管理。
- 存在意義: 「SDL を人が手書きしたい」場合。ただし description / deprecated は案 B の `Field` に載る。

## 比較

| 軸 | A: codegen | B: code-first DSL | C: 折衷 |
|---|---|---|---|
| コンパイル時に落ちる物 | 引数の型 | 登録漏れ、名前、引数、戻り値、source | 引数、戻り値、source |
| 起動時検証 | 要る | **不要** | 要る |
| フィールド追加で触る場所 | SDL、生成、実装 | 実装 1 か所 | SDL、実装 |
| 生成ステップ | 要る（別言語） | 無し | 無し |
| source / context | 生成レコードで可 | 型引数で自然 | 同 B |
| ボイラープレート | 生成物 | input 型の Codec | 同 B + SDL |
| Caliban との距離 | 遠い | 近い（Codec が手書きな点だけ劣る） | 中 |

## Flix での実現性（レビューで実験済み）

実験コードは scratchpad の `flixexp{,2,3,4,5,6}/src/Main.flix`。

| 項目 | 結果 |
|---|---|
| `Field[source]` にクロージャ `Context -> source -> Args -> ... \ IO` を持つ | 通る |
| 引数型の違う `field0/1/2` を同じ `List[Field[Unit]]` に並べる | 通る |
| `Out.option(Out.obj(...))` / `Out.list(...)` の合成 | 通る |
| 純粋なラムダ `(_c,_s,a,b) -> Ok(a+b)` を `\ IO` の引数に渡す | **落ちる（E6218）**。`checked_ecast` で包むか `--Xsubeffecting=lambdas` が要る |
| `f: ... \ ef` にして内側で `checked_ecast` | 落ちる（E6216） |
| `postType()` ⇄ `authorType()` の相互再帰（関数化のみ） | **実行時 StackOverflowError**。fields を thunk にし SDL 走査で dedupe すれば通る |
| `trait Codec[a]` | record 型への instance が書けない。多対一（`Int32` → `Int` / `ID`）も表せない。よって enum で持つ |
| Flix の record / enum を `unchecked_cast` で `Object` に箱詰めして戻す | 通る。`Int32` は CastError なので scalar は `JavaValue` 経由のまま |
| 予約語 | `run` / `query` はレコードフィールド名・引数名に使えない。`resolve` / `queryType` にする |

## 決定事項

1. **案 B を採る。**
2. object 型は eager に `Value` へ潰さず、`Out[a]` で scalar と object を区別し、object は
   Flix 値を Java `Object` に箱詰めして子 DataFetcher に渡す。
3. `objectType(name, () -> fields)` と thunk にし、SDL は `TypeRef` を名前で dedupe しながら辿る。
4. `GqlCodec` は enum（値）。`Id` は newtype。名前は stdlib の `Util.Codec` と衝突させない。
5. `Field` の effect は `\ IO` に固定。effect 付きリゾルバは今までどおり登録時にハンドラで包む。
   （その後 effect 多相に変更。`Field[source, ef]` と `Runner[ef]`。docs/design/sdl-first-codegen.md の「リゾルバの effect 多相」を参照）
6. **純粋リゾルバの書き味は `--Xsubeffecting=lambdas` を `bin/flix` に載せて解決する。**
   experimental フラグだが、無いと全リゾルバに `checked_ecast` が要り、DSL の利点が半減する。
   フラグが将来消えた場合の退路は `checked_ecast` を規約にする事（機械的に直せる）。
7. `Arg` / `Field` に description / default / deprecated の枠を最初から持ち、`withDescription` 等で後付けする。
8. Context は `Graphql.execute(request, context)` で渡す。graphql-java 側では root と各 source を
   `(Context, 値)` のタプルで箱詰めして、子 DataFetcher が source から取り出す。
   graphQLContext を使わないのは、取り出す get がジェネリクスで Flix から型を決めにくいため。
9. エラーは `pub type alias FieldError = String` で始める。`Field` / `ErasedField` / `field0..3` /
   `Arg.decode` の署名は全部この alias に向け、GraphQL のエラーへの変換は `Graphql.toErrorResult` の 1 か所。
   `DataFetcherResult` で返すので message はリゾルバの文言のままで、path と locations が付く
   （例外で投げると graphql-java が "Exception while fetching data" を前置する）。
   extensions が要るときは alias を enum に差し替える。

## 移行の段取り

1. `bin/flix` に `--Xsubeffecting=lambdas` を足す（check / run / test で通るか確認）
2. `src/graphql/GqlCodec.flix`（`int32 / string / bool / float / id / list / option`、`Id`）
3. `src/graphql/Schema.flix`（`TypeRef` / `Arg` / `Out` / `Field` / `ObjectType` / `field0..3` / `objectType` / `schema` / `toSdl`）
4. `Graphql.buildEngine` を `Schema` の値から SDL と DataFetcher を作る形に置き換え、
   `validateResolvers` / `mergeResolvers` / `Resolver` 型を削除。`execute` に `Context` を足す
5. `Calc` と `Counter` を DSL へ移す。`schema.graphql` は `make schema` で出力する物にする
6. `Post` / `Author` の相互参照を固定値で足し、source が型付きで届く事と selection に従って子だけ走る事をテストで確かめる
7. `Context`（`{ userId, roles }`）を通し、認可の入口を作る

## 既知の制限

- **同名オブジェクト型の同一判定は SDL の文字列比較。** `postType()` のように型を関数で作ると
  参照のたびに新しい値ができるので、「同じ定義の再参照」と「別定義の重複」を値の同一性では
  見分けられない。SDL が違えば起動時 Err、SDL が同じなら最初の物を使う。
  同名・同 SDL で source の Flix 型だけが違う 2 定義は検出できない。JVM 上の表現が違えば
  実行時に ClassCastException が errors に出るが、同じ形のレコード同士なら例外にならず
  1 つ目のリゾルバが 2 つ目の値で黙って走る。同名・同 SDL・同 source でリゾルバだけ違う 2 定義も
  2 つ目が捨てられる。規約として「オブジェクト型は 1 つの関数で定義し、参照はその関数を呼ぶ」を守る。
- feature 間で同名フィールドを Query に並べた場合は起動時に graphql-java が Err にする（コンパイルでは落ちない）。

## 見送った物

- arity 関数ではなく引数をレコードの Codec に寄せる案: arity 関数で型推論が素直に通ったので `field0..3` で始める。4 個以上は input 型へ。
  同型の引数が並ぶ（`a`, `b`）のは名前付き `arg("a", ...)` で取り違えを防げるので、プロジェクトの「同型連続はレコード化」規約とは別扱いにする。
- `trait Codec`: 上記の理由で不採用。
