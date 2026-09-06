# flix_graphql_hello

Flix と PostgreSQL で書く headless CMS の API サーバ。GraphQL の実行には Java の graphql-java を
Java interop で使い、Flix 側は代数的 effect でそれを境界に閉じ込めている。DB 層は sqlfx（GitHub の release から取る）。

API は 2 つある。

- `/admin/graphql`: 管理 API。content type とフィールドの定義を読み書きする。スキーマは `admin.graphql`（SDL）が正で、
  そこから型付きの Flix コードを生成する。人が書くのは SDL と、生成されたレコード型に合わせたリゾルバだけで、
  スキーマとリゾルバのズレはコンパイルで落ちる
- `/graphql`: 今は graphql-java を試した見本（`schema.graphql`。add / fibonacci / 固定の Post / SQLite のカウンタ）。
  コンテンツ API（型の定義から実行時に組む）に置き換わる予定

HTTP サーバは `java.net.ServerSocket` の上に手書きした最小の HTTP/1.1。設計と作る順番は
[docs/design/cms-spec](https://claude.ai/code/artifact/bdc58ed6-4ee0-45bf-9282-a842a0fcc988) にある。

## 使い方

Flix コンパイラは flix_game_engine の devbox が持つ jar を借りる（`bin/flix` が解決する）。
JDK と Docker が要る。DB 層は [sqlfx](https://github.com/ababup1192/sqlfx) で、`flix.toml` の `[dependencies]` から GitHub の release を取る。

```bash
make db-up     # PostgreSQL 16 を docker compose で起動
make migrate   # migrations/ を当てる（初回と、migration を足した時）
make run       # サーバ起動（CMS_DSN 等は Makefile が渡す。初回は Maven 依存の取得で時間がかかる）
make query     # 起動中のサーバへ /health とサンプルのクエリと mutation を投げる
make generate  # schema.graphql / admin.graphql から src/generated/ を作り直す
make gen       # migrations/ と queries/*.q から src/generated/sql/ を作り直す（sqlfx の生成器。flix_db 側で動く）
make check     # 型検査
make test      # DB 無しのテスト（test/Pg を除く）
make test-pg   # コンテナを立てて実 PostgreSQL 込みで全部回し、止める
make db-down   # PostgreSQL を止めてデータを消す
```

`bin/flix` は `--Xsubeffecting=lambdas` を付けて呼ぶ（純粋なリゾルバのラムダをそのまま `\ AppEff` の関数型に置くため）。
VS Code の Flix 拡張にも同じフラグが要り、`.vscode/settings.json` の `flix.extraFlixArgs` で渡している。
フラグが効く前の診断が残っていたら「Developer: Reload Window」で読み直す。

### 環境変数

| 変数 | 意味 |
|---|---|
| `CMS_DSN` | `jdbc:postgresql://host:port/db`。必須。起動時に SELECT 1 が通らなければ終了コード 1 |
| `CMS_DB_USER` / `CMS_DB_PASSWORD` | 省略時は `cms` |
| `CMS_CORS_ORIGINS` | 許すオリジンのカンマ区切り（`https://admin.example.com`）。`*` で全部。省略時は CORS ヘッダを付けない |

起動すると `http://localhost:8080/admin/graphql`（管理 API）と `/graphql`（見本）で待ち受け、`GET /health` が DB に届けば `{"status":"ok"}`、
届かなければ 503 を返す。起動時に migrations が全部当たっているかも確かめ、未適用なら終了コード 1（`make migrate`）。

### 管理 API の例

```bash
curl -s -X POST localhost:8080/admin/graphql -H 'Content-Type: application/json' \
  -d '{"query": "mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id singular plural } }"}'
# {"data":{"createContentType":{"id":"1","plural":"blogs","singular":"Blog"}}}

curl -s -X POST localhost:8080/admin/graphql -H 'Content-Type: application/json' \
  -d '{"query": "mutation { addField(typeId: \"1\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true, config: { maxLength: 120 } }) { id position } }"}'

curl -s -X POST localhost:8080/admin/graphql -d '{"query": "{ contentTypes { apiId singular fields { apiId kind required config { maxLength } } } }"}'
```

名前の規則（lowerCamel の apiId、予約名、他の型との衝突）に合わない入力は `errors[].message` に理由が並ぶ。

カウンタはカレントディレクトリの `counter.db`（SQLite）に保存され、再起動しても値が残る。リポジトリのルートで起動する。

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

### 落とし穴

- graphql-java 22 の good-faith introspection: 1 つのクエリに `__type` や `__schema` を複数並べると
  「This request is not asking for introspection in good faith」で data が null になる。GraphiQL は問題ないが、
  自前のクライアントは introspection を 1 つずつ投げる。

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

対応しているのは `type`、`enum`、`input`、`union`、`interface`、`schema { }` ブロック、組み込みスカラー
（`Int / Float / String / Boolean / ID`）、リスト、nullable、description（型・フィールド・引数・enum 値）、
`@deprecated`（フィールド・enum 値）、引数と input フィールドの既定値。enum 値の description は生成された `case` の
doc コメントにもなる。`subscription` / custom scalar / `extend` / それ以外の directive / interface が interface を implements する形は
生成器がエラーにする。

`input` は Flix のレコード型の別名と Codec になる（`input PostInput { title: String!  status: PostStatus = DRAFT }`
→ `Generated.PostInput = { title = String, status = Option[PostStatus] }`）。リゾルバには `input#title` で届く。
input の中にオブジェクト型を書く、input 同士を循環させる、input を戻り値にする、のどれも生成器が止める
（循環は Flix のレコード型の別名が再帰できないため）。

`union` と `interface` は枝（実装型）ごとの case を持つ Flix の enum になり、リゾルバはその enum に包んで返す
（`Generated.SearchResult.Post(post)`）。`__typename` と inline fragment は graphql-java が処理し、枝のリゾルバは
通常のオブジェクト型と同じ経路で動く。interface のフィールドは実装型が持つので、interface 自身にリゾルバは無い。
生成器は、実装型が interface の全フィールドを同じ型で持つか、union の枝がオブジェクト型か、union / interface が
どこかのフィールドの型に使われているか（implements だけでは SDL に宣言が出ない）を検査する。

引数の既定値にオブジェクトリテラル
（`input: PostInput = {title: "x"}`）を書くのは未対応で、生成器が止める（input のフィールド側の既定値は使える）。
Query / Mutation から届かない型、大文字始まりのフィールド名、小文字始まりの型名も生成器が止める（Flix の識別子にならないため）。

### 2. `make generate` で生成する

`src/generated/graphql/GeneratedSchema.flix` ができる。中身は型ごとのリゾルバのレコード型と、それを graphql-java に
配線するコードで、人は読まない。

```flix
/// Post.author
pub type alias PostAuthorResolver[ef: Eff] = Context -> Post -> Result[FieldError, Author] \ ef

/// type Post のリゾルバ一式
pub type alias PostResolvers[ef: Eff] = { id = PostIdResolver[ef], title = PostTitleResolver[ef], author = PostAuthorResolver[ef] }

/// type Post の既定リゾルバ。source の同名ラベルをそのまま返す。author は含まない
pub def postDefaults(): { id = Context -> { id = Id | r0 } -> Result[FieldError, Id] \ ef, title = … } = …
```

`ef` はリゾルバが使う効果で、実装側が決める（`\ IO` に固定していない）。既定リゾルバは引数が無く
スカラー・enum・そのリストを返すフィールドの分だけ作られ、source の型は行変数で開いている
（`Post` が SDL に無いラベルを持ってよい）。

`enum` は Flix の enum と Codec ごと生成される（`enum Status { IN_PROGRESS }` → `Generated.Status.InProgress`）。

### 3. `make scaffold` で雛形を作り、リゾルバを書く

```bash
make scaffold                 # 全型。src/sample/resolvers/XResolvers.flix を書く（既にあるファイルは触らない）
make scaffold TYPE=Post       # 1 型だけ
make scaffold DEFAULTS=no     # 既定リゾルバを使わず全フィールドを吐く（source が enum の型向け）
```

`src/sample/resolvers/PostResolvers.flix` は人が所有するファイルで、gqlgen の resolver.go に当たる。
フィールドごとの関数と、それを既定リゾルバに足すレコードが入っている。

```flix
mod PostResolvers {
    /// Post.author
    pub def author(): Generated.PostAuthorResolver[AppEff] =
        (_context, post) -> Post.findAuthor(post#authorId) |> Option.toOk("author not found")

    /// type Post のリゾルバ一式
    pub def resolvers(): Generated.PostResolvers[AppEff] =
        { +author = author() | Generated.postDefaults() }
}
```

`id` / `title` / `status` は書かない（既定リゾルバが source の同名ラベルを返す）。既定を上書きしたい
フィールドは `{ id = …, +author = … | Generated.postDefaults() }` のように更新構文で置き換える。

SDL の `type Post` に対応する Flix の型 `Post` は人が定義する（トップレベルの `pub type alias` か `pub enum`。
名前を揃える）。SDL に無いフィールドを持ってよい。`Post` が enum なら既定リゾルバは使えないので
`DEFAULTS=no` で全フィールドを書く。

`AppEff` は `src/app/AppEff.flix` にある、このサーバのリゾルバが使う効果の和（今は `CounterStore`）。
リゾルバは `counter = context -> Counter.counter(context)` のように `\ CounterStore` のまま書け、
純粋な物は `ef` に吸収される。効果を足すときは `AppEff` に `+` でつなぐ。

最後に `src/app/AppSchema.flix` で全部を `Generated.schema({ queryRoot = QueryResolvers.resolvers(), post = PostResolvers.resolvers(), ... }, runApp)` に渡す。
`runApp: Runner[AppEff]` は `AppEff` を IO に落とすハンドラで、本番は `SqliteCounter.runWithSqlite`、
テストは `CounterFake.runWithMemory`。ハンドラを渡すのはここ 1 回だけ。

### コンパイルで落ちる物

| ズレ | エラー |
|---|---|
| SDL にフィールドを足したがリゾルバが無い | レコードのラベル不足。エラーの 1 行目に足りないラベル名が出る |
| SDL から消したのにリゾルバが残っている | レコードのラベル余分（Extra label） |
| 引数の型・個数、戻り値の型が SDL と違う | 関数型の不一致。フィールドごとの関数（`def author(): Generated.PostAuthorResolver[AppEff]`）の行に出る |
| ある型のリゾルバ一式を丸ごと書き忘れ | `Resolvers` のラベル不足 |
| `type Post` に対応する Flix の `Post` が無い | 未定義の型 |
| リゾルバが `AppEff` に無い effect を使う | `Unexpected effect 'Clock' in function declared as {'CounterStore'}`（別名は展開されて出る。`AppEff` に足すか、ハンドラで包む） |
| source の型（`Post`）に既定リゾルバが要るラベルが無い、または Option の有無が違う | `resolvers()` の行で `( )` と `( title = String \| r0 )` の不一致。「source に無い」とは出ないので、ラベル名を見て `Post` を直す |
| `make generate` し忘れ、または古い生成器で作った生成物 | テスト `testSchemaGeneratedIsUpToDate` が落ち、`make run` も起動を拒否する |

### 書き方の決まり

- **効果が `AppEff` と一致しない def はラムダで包む。** `add = CalcResolvers.add` のように純粋な def をそのまま置くと、
  サブエフェクトはラムダにしか効かないので `\ AppEff` に広がらずコンパイルエラーになる。
  効果がちょうど `AppEff` の def は参照のままで通る。
- **効果は `AppEff` 1 つで書く。** 型ごとに `PostResolvers[CounterStore]` と `AuthorResolvers[Clock]` のように
  別の効果を書くと、`Resolvers[ef]` の `ef` はレコード全体で 1 つなので合わない。
- **フィールドごとに注釈付きの関数で書く**（`def author(): Generated.PostAuthorResolver[AppEff]`）。レコードに
  直接ラムダを書くと、型が 1 つ違うだけでレコード全体がエラーにダンプされ「どのフィールドか」が出ない。
  `make scaffold` の雛形はこの形になっている。
- SDL の名前が Flix の予約語（`from` `run` `query` など）のときは、生成物のラベルは末尾に `_` が付く（`from_`）。

## アーキテクチャ

```
schema.graphql ──(make generate / schemagen)──▶ src/generated/graphql/GeneratedSchema.flix ──▶ Schema（Field / ObjectType / Out）
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

リゾルバの effect は型変数 `ef`（`Field[source, ef]` / `ObjectType[a, ef]` / `Out[a, ef]`）で、実装側が決める。
リゾルバは graphql-java の Java コールバックの中で呼ばれ、そこから `main` のハンドラへは戻れないので、
`Schema.make(query, mutation, runner)` が受け取った `Runner[ef]` をコールバックのクロージャの中で走らせて IO に落とす。
ハンドラは別スレッドから呼ばれても動く。`Runner` の戻り型が箱（`JavaValue.Boxed`）に固定なのは、
型別名が自由な型変数を持てず rank-2 型も無いため。

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

`Counter.counter(context)` は `\ CounterStore` のまま書く。ハンドラは `AppSchema.make(runApp)` に 1 回渡す。
本番は `SqliteCounter.runWithSqlite`、テストは `CounterFake.runWithMemory`（メモリ上の `Ref`）なので、
リゾルバの検証に SQLite は要らない。

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
3. `make check` が落ちる場所（`XResolvers` のラベル不足）に、`src/sample/resolvers/XResolvers.flix` のフィールド関数を足す。
   素通しのフィールドなら既定リゾルバが拾うので何も書かない。新しい型なら `make scaffold TYPE=X` で雛形を作る。
   外部に触るなら `CounterStore` のように effect を宣言して `AppEff` に足し、ハンドラを `main` の `runApp` に重ねる

## ディレクトリ

```
schema.graphql           SDL（正。人が書く）
schemagen/               生成器（別プロジェクト）。SdlReader（graphql-java の AST を読む）、Emit（生成物を組む）、Scaffold（雛形を組む）
src/
  Main.flix              起動（生成物の照合、SQLite を開く、エンジン組み立て、listen）
  generated/
    GeneratedSchema.flix 生成物（make generate。手で編集しない）
  graphql/               GraphQL の実行と graphql-java との境界
    Value.flix           GraphQL の値（JSON 相当の enum）
    JsonValue.flix       Value <-> JSON 文字列
    JavaValue.flix       Value <-> Java Object、Flix の値の箱詰め（Boxed）
    GqlCodec.flix        スカラー・enum・input の Codec、Id
    Schema.flix          Context / TypeRef / Arg / Out / Field / ObjectType / Schema、field0..3 / fieldRaw、toSdl
    GeneratedCheck.flix  生成物に埋まった SDL 本文・生成器バージョンと schema.graphql の照合
    Graphql.flix         eff Graphql、buildEngine / runWithEngine
  http/                  HTTP/1.1 サーバ（GraphQL を知らない）
    Http.flix            解析と組み立て（純粋関数）
    HttpServer.flix      ソケット、接続ごとのスレッド、ログ
  app/                   HTTP と GraphQL をつなぐ層
    Server.flix          HttpRequest -> GraphqlRequest -> レスポンス JSON
    AppSchema.flix       Generated.Resolvers に src/sample/resolvers/ の型ごとのリゾルバを当てはめる
    AppEff.flix          リゾルバが使う効果の和（Runner を渡す単位）
  resolvers/             型ごとのリゾルバ（make scaffold の雛形に実装を書いた物。人が所有する）
    QueryResolvers.flix / MutationResolvers.flix / PostResolvers.flix / AuthorResolvers.flix
  features/              リゾルバから呼ぶロジックとデータ
    calc/                Calc（純粋な計算）
    post/                Post（固定データ）
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
