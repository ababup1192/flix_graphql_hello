# flix_graphql_hello

Flix で書いた GraphQL サーバの最小構成。GraphQL の実行には Java の graphql-java を
Java interop で使い、Flix 側は代数的 effect でそれを境界に閉じ込めている。
スキーマは `schema.graphql`（SDL）が正で、そこから型付きの Flix コードを生成する。
人が書くのは SDL と、生成されたレコード型に合わせたリゾルバだけで、
スキーマとリゾルバのズレ（不足・余分・型違い）はコンパイルで落ちる。
HTTP サーバは `java.net.ServerSocket` の上に手書きした最小の HTTP/1.1 で、
Mutation の例として SQLite に置いたカウンタを持つ。

## 使い方

Flix コンパイラは flix_game_engine の devbox が持つ jar を借りる（`bin/flix` が解決する）。
JDK が PATH に要る。

```bash
make run       # サーバ起動（初回は Maven 依存の取得で時間がかかる）
make query     # 起動中のサーバへサンプルのクエリと mutation を投げる
make generate  # schema.graphql から src/generated/GeneratedSchema.flix を作り直す
make check     # 型検査
make test      # テスト（graphql-java も SQLite も使うが、HTTP サーバは起動しない）
```

`bin/flix` は `--Xsubeffecting=lambdas` を付けて呼ぶ（純粋なリゾルバのラムダをそのまま `\ IO` の関数型に置くため）。
VS Code の Flix 拡張にも同じフラグが要り、`.vscode/settings.json` の `flix.extraFlixArgs` で渡している。
フラグが効く前の診断が残っていたら「Developer: Reload Window」で読み直す。

起動すると `http://localhost:8080/graphql` で待ち受ける。カウンタはカレントディレクトリの
`counter.db` に保存され、再起動しても値が残る。リポジトリのルートで起動する。

### リクエストの形

GraphQL over HTTP の POST 形式。`query` は必須、`variables` と `operationName` は省略できる。

```bash
curl -s -X POST localhost:8080/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query": "query($a: Int!) { add(a: $a, b: 2) fibonacci(n: 10) counter }", "variables": {"a": 40}}'
# {"data":{"add":42,"counter":0,"fibonacci":55}}

curl -s -X POST localhost:8080/graphql \
  -d '{"query": "{ post(id: \"p1\") { title author { name posts { id } } } }"}'
# {"data":{"post":{"author":{"name":"abab","posts":[{"id":"p1"},{"id":"p2"}]},"title":"Flix で GraphQL"}}}

curl -s -X POST localhost:8080/graphql -d '{"query": "mutation { increment(by: 3) }"}'
# {"data":{"increment":3}}
```

エラーは GraphQL 仕様どおり `errors[].message` で返る。graphql-java が付ける
`locations` や `extensions` もそのまま通す。リゾルバが `Err("...")` を返すと、その文字列がそのまま
`message` になり、`path` と `locations` が付く（ステータスは 200 のまま）。

| 状況 | ステータス |
|---|---|
| 正常（GraphQL のエラーを含む） | 200 |
| JSON が壊れている / `query` が無い / `variables` がオブジェクトでない | 400 |
| `/graphql` 以外のパス | 404 |
| `/graphql` への POST 以外 | 405（`Allow: POST` 付き） |
| Content-Length が 1 MiB を超える | 413 |
| ヘッダ 1 行が 8 KiB を超える（リクエスト行も含む） / ヘッダが 100 行を超える | 431 |
| リクエスト行が壊れている / Content-Length が数字でない | 400 |
| 接続の処理中に例外が起きた（read のタイムアウト、レスポンス変換の失敗など） | 500（ボディ無し） |

## スキーマの書き方

### 1. `schema.graphql` を書く

```graphql
type Query {
  add(a: Int!, b: Int!): Int!
  post(id: ID!): Post
}

type Post {
  id: ID!
  title: String!
  author: Author!
}
```

対応しているのは `type`、`enum`、`schema { }` ブロック、組み込みスカラー（`Int / Float / String / Boolean / ID`）、
リスト、nullable、description、`@deprecated`、引数の既定値。`input` / `interface` / `union` /
`subscription` / custom scalar / `extend` / それ以外の directive は生成器がエラーにする。
Query / Mutation から届かない型、大文字始まりのフィールド名、小文字始まりの型名も生成器が止める（Flix の識別子にならないため）。

### 2. `make generate` で生成する

`src/generated/GeneratedSchema.flix` ができる。中身は型ごとのリゾルバのレコード型と、それを graphql-java に
配線するコードで、人は読まない。

```flix
pub type alias PostResolvers = {
    id     = Context -> Post -> Result[FieldError, Id] \ IO,
    title  = Context -> Post -> Result[FieldError, String] \ IO,
    author = Context -> Post -> Result[FieldError, Author] \ IO
}
```

`enum` は Flix の enum と Codec ごと生成される（`enum Status { IN_PROGRESS }` → `Generated.Status.InProgress`）。

### 3. 生成されたレコード型に合わせてリゾルバを書く

```flix
pub def post(): Generated.PostResolvers = {
    id     = (_context, post) -> Ok(post#id),
    title  = (_context, post) -> Ok(post#title),
    author = (_context, post) -> Post.findAuthor(post#authorId) |> Option.toOk("author not found")
}
```

SDL の `type Post` に対応する Flix の型 `Post` は人が定義する（トップレベルの `pub type alias` か `pub enum`。
名前を揃える）。SDL に無いフィールドを持ってよい。

最後に `src/app/AppSchema.flix` で全部を `Generated.schema({ queryRoot = ..., post = ..., ... })` に渡す。

### コンパイルで落ちる物

| ズレ | エラー |
|---|---|
| SDL にフィールドを足したがリゾルバが無い | レコードのラベル不足（Missing label） |
| SDL から消したのにリゾルバが残っている | レコードのラベル余分（Extra label） |
| 引数の型・個数、戻り値の型が SDL と違う | 関数型の不一致 |
| ある型のリゾルバ一式を丸ごと書き忘れ | `Resolvers` のラベル不足 |
| `type Post` に対応する Flix の `Post` が無い | 未定義の型 |
| リゾルバで `CounterStore` などの effect を剥がし忘れ | effect が `\ IO` に収まらない |
| `make generate` し忘れ、または古い生成器で作った生成物 | テスト `testSchemaGeneratedIsUpToDate` が落ち、`make run` も起動を拒否する |

### 書き方の決まり

- **レコードの値は必ずラムダで書く。** `add = CalcResolvers.add` のように純粋な def をそのまま置くと、
  サブエフェクトはラムダにしか効かないので `\ IO` に広がらずコンパイルエラーになる。
- **型ごとに注釈付きの関数で作る**（`def post(): Generated.PostResolvers`）。1 つのレコードに全部書くと、
  型が 1 つ違うだけでレコード全体がエラーにダンプされる。型ごとに分ければその型の分だけになる。
  それでも「どのフィールドか」は出ないので、エラーの Expected と Actual を上から見比べる。
- SDL の名前が Flix の予約語（`from` `run` `query` など）のときは、生成物のラベルは末尾に `_` が付く（`from_`）。

## アーキテクチャ

```
schema.graphql ──(make generate / schemagen)──▶ src/generated/GeneratedSchema.flix ──▶ Schema（Field / ObjectType / Out）
                                                          ▲                                       │
                                        AppSchema（リゾルバのレコード）                   Graphql.buildEngine ──▶ graphql-java

HTTP (socket)          純粋な HTTP 解析        ルーティング          GraphQL 実行 effect       graphql-java
HttpServer.listen ──▶ Http.parse* / render ──▶ Server.handle ──▶ eff Graphql.execute ──▶ Graphql.runWithEngine
                                                    │                                          │
                                              JsonValue                                  JavaValue
                                          (Value <-> JSON)                          (Value / Boxed <-> Java Object)
                                                                                           │
                                                                                   eff CounterStore ──▶ SqliteCounter (JDBC)
```

### 1. SDL が正、Flix コードは生成物

生成器 `schemagen/` は別プロジェクト（Flix + graphql-java のパーサ）。本体と分けているのは、
生成物が壊れていると本体がコンパイルできず、コンパイルできないと生成し直せない、という循環を避けるため。
生成物には SDL と生成器バージョンの SHA-256 が埋まり、テストと起動時に `schema.graphql` と照合する。

生成物の中身は `src/graphql/Schema.flix` の型付き DSL（`Schema.fieldRaw` / `Out` / `GqlCodec` / `objectType`）。
この DSL は人が直接書くこともできる（テストではそうしている）。DSL 自体の設計は
[docs/design/typed-schema.md](docs/design/typed-schema.md)、生成の設計は
[docs/design/sdl-first-codegen.md](docs/design/sdl-first-codegen.md)。

オブジェクト型は `Value.Obj` に潰さず、Flix の値を `(Context, 値)` で箱詰めして graphql-java の source として渡す。
クエリで選ばれた子フィールドのリゾルバだけが走る（graphql-java の流儀どおり。DataLoader もこの上に乗る）。

リゾルバの effect は `IO` に固定している。リゾルバは graphql-java の Java コールバックの中で呼ばれ、
そこから Flix のハンドラへは戻れないため。他の effect を使う物はリゾルバを作る時点でハンドラで包む（`Counter` を参照）。

### 2. GraphQL の実行は代数的 effect

```flix
pub eff Graphql {
    def execute(request: GraphqlRequest, context: Context): GraphqlResponse
}
```

ルーティング（`Server`）はこの effect だけに依存し、graphql-java を知らない。
本物のハンドラは `Graphql.runWithEngine(engine, f)` で、`main` が起動時に 1 回だけ
`Graphql.buildEngine(schema)` でエンジンを組み立て、接続ごとに使い回す。
テストでは `test/graphql/GraphqlFake.flix` の偽ハンドラに差し替えるので、エンジン無しでルーティングを検証できる。

`Context` はリクエスト単位の情報（`userId`）で、全リゾルバの第 1 引数に届く。JWT 検証を入れるまでは `Context.anonymous()`。

### 3. Java のオブジェクトはリゾルバに出さない

スカラーと引数は JSON 相当の enum `Value`（`Null / Bool / Int / Float / Str / List / Obj`）で持ち、
オブジェクト型の値は `JavaValue.Boxed` で不透明に箱詰めして graphql-java の source として往復させる。
`Value` と Java の値の変換は `JavaValue` に、JSON との変換は `JsonValue` に閉じている。

エラーメッセージの言語は 2 種類に分ける。クライアントに返る文字列（リゾルバの `Err`、
`Server` の 400 ボディ）は英語、起動時に運用者が読む文字列（`buildEngine` の `Err`、`Main` の出力、生成器の出力）は日本語。

### 4. 保存先も effect で分離（SQLite はハンドラの 1 つ）

Mutation の例 `Counter` は、値の読み書きを `CounterStore` effect として宣言し、
JDBC はハンドラ `SqliteCounter.runWithSqlite` に閉じている。

```flix
pub eff CounterStore {
    def load(): Result[String, Int32]
    def increment(by: Int32): Result[String, Int32]
}
```

`Counter.counter(runStore, context)` はハンドラを外から受ける。本番は `SqliteCounter.runWithSqlite`、
テストは `CounterFake.runWithMemory`（メモリ上の `Ref`）を渡すので、リゾルバの検証に SQLite は要らない。

SQLite 側は `SqliteCounter.open` で `Database`（JDBC の URL）を作り、テーブル 1 行に値を置く。
Flix 側に可変状態を持たず、並行アクセスの直列化も SQLite のロックに任せる。
sqlite-jdbc の `Connection` はスレッドセーフではないので、呼び出しごとに開いて閉じる。
Flix は Maven の jar を独自のクラスローダで読むため `DriverManager` の自動登録が効かず、
`org.sqlite.JDBC` を直接呼んでいる。

### 5. HTTP サーバは最小

`HttpServer.listen(port, handle)` は接続ごとに軽量スレッドを `spawn` し、
ログは 1 本のチャネルに集約して順に出す。GraphQL のことは知らない。

対応範囲は意図的に狭い。

- 1 接続 1 リクエスト（常に `Connection: close`）。keep-alive 非対応
- 接続ごとに軽量スレッドを 1 本 spawn する。同時接続数の上限は無い
- ボディの長さは `Content-Length` だけで決める。chunked 非対応。無ければ空ボディ
- ボディは 1 MiB まで（413）、ヘッダは 100 行・1 行 8 KiB まで（どちらも 431）
- 読み取りのタイムアウトは 1 回の read ごとに 10 秒。1 回の read が 10 秒止まると 500 を返して閉じる
- ボディはバイト単位で読んでから UTF-8 に戻す。サロゲートペア（絵文字）も `Content-Length` どおりに読める
- 接続スレッド内の例外はログに流し、500（ボディ無し）を返してソケットを閉じる

## フィールドを足す

1. `schema.graphql` にフィールドを足す
2. `make generate`
3. `make check` が落ちる場所（ラベル不足）にリゾルバを書く。外部に触るなら `CounterStore` のように
   effect を宣言し、リゾルバを作る時点でハンドラで包む

## ディレクトリ

```
schema.graphql           SDL（正。人が書く）
schemagen/               生成器（別プロジェクト）。SdlReader（graphql-java の AST を読む）、Emit（Flix コードを組む）
src/
  Main.flix              起動（生成物の照合、SQLite を開く、エンジン組み立て、listen）
  generated/
    GeneratedSchema.flix 生成物（make generate。手で編集しない）
  graphql/               GraphQL の実行と graphql-java との境界
    Value.flix           GraphQL の値（JSON 相当の enum）
    JsonValue.flix       Value <-> JSON 文字列
    JavaValue.flix       Value <-> Java Object、Flix の値の箱詰め（Boxed）
    GqlCodec.flix        スカラー・enum の Codec、Id
    Schema.flix          Context / TypeRef / Arg / Out / Field / ObjectType / Schema、field0..3 / fieldRaw、toSdl
    GeneratedCheck.flix  生成物に埋まった SDL 本文・生成器バージョンと schema.graphql の照合
    Graphql.flix         eff Graphql、buildEngine / runWithEngine
  http/                  HTTP/1.1 サーバ（GraphQL を知らない）
    Http.flix            解析と組み立て（純粋関数）
    HttpServer.flix      ソケット、接続ごとのスレッド、ログ
  app/                   HTTP と GraphQL をつなぐ層
    Server.flix          HttpRequest -> GraphqlRequest -> レスポンス JSON
    AppSchema.flix       Generated.Resolvers に各 feature のリゾルバを当てはめる
  features/              リゾルバの実装
    calc/                Calc（純粋な計算）
    post/                Post（固定データ）、PostResolvers（type Post / Author のリゾルバ）
    counter/             CounterStore（eff）、Counter（Query.counter / Mutation.increment）、SqliteCounter（JDBC）
test/                    src と同じ構成。偽ハンドラ（*Fake.flix）と GraphqlTestKit もここ
docs/design/             設計メモ（typed-schema.md: DSL、sdl-first-codegen.md: 生成）
```

## テストの方針

- `Server` / `Http` / `JsonValue` / `GqlCodec` / `Schema.toSdl` / `Counter` はエンジン無し・ソケット無し・DB 無しで検証する
- graphql-java との境界（source の受け渡し、selection に従った子の実行、Context の到達、errors の形、値の変換）は
  `TestGraphqlJava*` で本物のエンジンを使って検証する。アプリのスキーマは `GraphqlTestKit.appSchema`（カウンタはメモリ上）
- `SqliteCounter` のハンドラ本体だけを一時ファイルの SQLite で検証する
- 生成器は `schemagen/test/` で SDL → 生成物の断片を検証する（`cd schemagen && ../bin/flix test`）
- HTTP の読み取りは `ByteArrayInputStream` で検証する

Flix の書き方の決まりは [docs/flix-conventions.md](docs/flix-conventions.md)、
コードの流儀は [AGENTS.md](AGENTS.md) を参照。
