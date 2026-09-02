# flix_graphql_hello

Flix で書いた GraphQL サーバの最小構成。GraphQL の実行には Java の graphql-java を
Java interop で使い、Flix 側は代数的 effect でそれを境界に閉じ込めている。
HTTP サーバは `java.net.ServerSocket` の上に手書きした最小の HTTP/1.1 で、
Mutation の例として SQLite に置いたカウンタを持つ。

## 使い方

Flix コンパイラは flix_game_engine の devbox が持つ jar を借りる（`bin/flix` が解決する）。
JDK が PATH に要る。

```bash
make run     # サーバ起動（初回は Maven 依存の取得で時間がかかる）
make query   # 起動中のサーバへサンプルのクエリと mutation を投げる
make check   # 型検査
make test    # テスト（graphql-java も SQLite も使うが、HTTP サーバは起動しない）
```

起動すると `http://localhost:8080/graphql` で待ち受ける。カウンタはカレントディレクトリの
`counter.db` に保存され、再起動しても値が残る。スキーマ `src/schema.graphql` も `counter.db` と
同じくカレントディレクトリからの相対パスで読むので、リポジトリのルートで起動する。

### リクエストの形

GraphQL over HTTP の POST 形式。`query` は必須、`variables` と `operationName` は省略できる。

```bash
curl -s -X POST localhost:8080/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query": "query($a: Int!) { add(a: $a, b: 2) fibonacci(n: 10) counter }", "variables": {"a": 40}}'
# {"data":{"add":42,"counter":0,"fibonacci":55}}

curl -s -X POST localhost:8080/graphql -d '{"query": "mutation { increment(by: 3) }"}'
# {"data":{"increment":3}}
```

エラーは GraphQL 仕様どおり `errors[].message` で返る。graphql-java が付ける
`locations` や `extensions` もそのまま通す。リゾルバが `Err` を返した場合や例外を投げた場合も
同じく `errors[]` に入り、ステータスは 200 のまま。

```bash
curl -s -X POST localhost:8080/graphql -d '{"query": "{ nope }"}'
# {"data":null,"errors":[{"extensions":{...},"locations":[...],"message":"Validation error ..."}]}
```

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

### スキーマ

`src/schema.graphql`

```graphql
type Query {
  add(a: Int!, b: Int!): Int!
  fibonacci(n: Int!): Int!
  counter: Int!
}

type Mutation {
  increment(by: Int!): Int!
}
```

## アーキテクチャ

```
HTTP (socket)          純粋な HTTP 解析        ルーティング          GraphQL 実行 effect       graphql-java
HttpServer.listen ──▶ Http.parse* / render ──▶ Server.handle ──▶ eff Graphql.execute ──▶ Graphql.runWithEngine
                                                    │                                          │
                                              JsonValue                                  JavaValue
                                          (Value <-> JSON)                          (Value <-> Java Object)
                                                                                           │
                                                                                     Resolver (Flix 関数)
                                                                                    CalcResolvers / Counter
                                                                                           │
                                                                                   eff CounterStore ──▶ SqliteCounter (JDBC)
```

### 1. GraphQL の実行は代数的 effect

```flix
pub eff Graphql {
    def execute(request: GraphqlRequest): GraphqlResponse
}
```

ルーティング（`Server`）はこの effect だけに依存し、graphql-java を知らない。
本物のハンドラは `Graphql.runWithEngine(engine, f)` で、`main` が起動時に 1 回だけ
`Graphql.buildEngine(schema)` でエンジンを組み立て、接続ごとに使い回す。
テストでは `test/GraphqlFake.flix` の偽ハンドラ（受け取ったリクエストをそのまま返す /
固定のレスポンスを返す）に差し替えるので、エンジン無しでルーティングを検証できる。

### 2. Java のオブジェクトはリゾルバに出さない

GraphQL の値は JSON 相当の enum `Value`（`Null / Bool / Int / Float / Str / List / Obj`）で持つ。
リゾルバは「引数 Map を受けて `Value` を返す」Flix の関数で、`Err` を返すと GraphQL のエラーになる。

```flix
pub type alias Args     = Map[String, Value]
pub type alias Resolver = Args -> Result[String, Value] \ IO
pub type alias Schema   = { sdl = String, resolvers = Map[(String, String), Resolver] }
```

`Value` と Java の `Integer / Double / Boolean / String / Map / List` の変換は
`JavaValue` に、`Value` と JSON 文字列の変換は `JsonValue`（標準ライブラリの `Util.Json` を使う）に閉じている。

リゾルバは graphql-java の Java コールバックの中で呼ばれるので、そこから Flix のハンドラへは
戻れない。そのため effect は `IO` だけを許す。純粋な計算は effect 無しで書き、登録時に
`checked_ecast` で広げる（`CalcResolvers.resolvers` を参照）。

エラーメッセージの言語は 2 種類に分ける。クライアントに返る文字列（リゾルバの `Err`、
`Server` の 400 ボディ）は英語、起動時に運用者が読む文字列（`buildEngine` /
`mergeResolvers` の `Err`、`Main` の出力）は日本語。

### 3. スキーマとリゾルバの食い違いは起動時に落とす

`Graphql.buildEngine` は SDL が壊れていれば `Err`、リゾルバの登録先がスキーマに無い、
または Query / Mutation のフィールドにリゾルバが無い場合も `Err` にする。
graphql-java の既定では未登録フィールドが黙って `null` になるので、それを防いでいる。

### 4. 保存先も effect で分離（SQLite はハンドラの 1 つ）

Mutation の例 `Counter` は、値の読み書きを `CounterStore` effect として宣言し、
リゾルバはその effect だけに依存する。JDBC はハンドラ `SqliteCounter.runWithSqlite` に閉じている。

```flix
pub eff CounterStore {
    def load(): Result[String, Int32]
    def increment(by: Int32): Result[String, Int32]
}

pub def incrementResolver(args: Args): Result[String, Value] \ CounterStore = ...
```

リゾルバは graphql-java の Java コールバックの中で呼ばれるので、`main` で噛ませたハンドラには
戻れない。そのため `Counter.resolvers(database)` がリゾルバを登録する時点で 1 つずつ
`runWithSqlite` で包み、effect の発行と処理をコールバックの内側で完結させる。
`Resolver` の型（`\ IO`）はこれで変わらない。

テストでは `test/features/counter/CounterFake.flix` のメモリ上のハンドラ（`runWithMemory` /
`runWithBroken`）に差し替えるので、リゾルバの検証に SQLite は要らない。

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
- 読み取りのタイムアウトは 1 回の read ごとに 10 秒。1 回の read が 10 秒止まると 500 を返して閉じる（リクエスト全体の合計時間ではない）
- ボディはバイト単位で読んでから UTF-8 に戻す。サロゲートペア（絵文字）も `Content-Length` どおりに読める
- 接続スレッド内の例外はログに流し、500（ボディ無し）を返してソケットを閉じる。ログにはメソッドと制御文字を除いたパスだけを出す

## リゾルバを足す

1. `src/schema.graphql` にフィールドを足す
2. `src/features/<機能>/` にリゾルバを書く。外部に触るなら `CounterStore` のように effect を宣言し、リゾルバは effect だけに依存させる
3. `Args -> Result[String, Value] \ IO` になるようハンドラで包み、`("型名", "フィールド名")` をキーにして Map に登録する
4. `src/Main.flix` の `Graphql.mergeResolvers` に渡すリストへ、その Map を加える

登録漏れ・名前の食い違い・キーの重複は `make run` の起動時にエラーで分かり、
プロセスは終了コード 1 で止まる。

## ディレクトリ

役割ごとに分けている。`test/` は `src/` と同じ構成で、偽ハンドラ（`*Fake.flix`）もそこに置く。

```
src/
  Main.flix              起動（スキーマ読み込み、エンジン組み立て、listen）
  schema.graphql         SDL
  graphql/               GraphQL の実行と graphql-java との境界
    Value.flix           GraphQL の値（JSON 相当の enum）
    JsonValue.flix       Value <-> JSON 文字列
    JavaValue.flix       Value <-> Java Object
    Graphql.flix         eff Graphql、Resolver / Schema、buildEngine / runWithEngine / mergeResolvers
  http/                  HTTP/1.1 サーバ（GraphQL を知らない）
    Http.flix            解析と組み立て（純粋関数）
    HttpServer.flix      ソケット、接続ごとのスレッド、ログ
  app/                   HTTP と GraphQL をつなぐ層
    Server.flix          HttpRequest -> GraphqlRequest -> レスポンス JSON
  features/              スキーマのフィールドごとの実装
    calc/
      Calc.flix          純粋な計算
      CalcResolvers.flix Query.add / Query.fibonacci
    counter/
      CounterStore.flix  eff CounterStore（保存先の抽象）
      Counter.flix       Query.counter / Mutation.increment（effect だけに依存）
      SqliteCounter.flix CounterStore の SQLite ハンドラ（JDBC はここだけ）
test/
  graphql/               GraphqlFake（Graphql effect の偽ハンドラ）、TestGraphqlJava（本物のエンジン）ほか
  http/                  TestHttp、TestHttpServer
  app/                   TestServer
  features/calc/         TestCalc、TestCalcResolvers
  features/counter/      CounterFake（メモリ上のハンドラ）、TestCounter、TestSqliteCounter
```

## テストの方針

- `Server` / `Http` / `JsonValue` / `CalcResolvers` / `Counter` はエンジン無し・ソケット無し・DB 無しで検証する
- graphql-java との境界（`JavaValue`、リゾルバの配線、errors の形）は `TestGraphqlJava` で本物のエンジンを使って検証する
- `Counter` のリゾルバはメモリ上の偽ハンドラで検証し、`SqliteCounter` のハンドラ本体だけを一時ファイルの SQLite で検証する
- HTTP の読み取り（行長・行数の上限、`Content-Length` どおりのバイト読み、413 / 400 / 431 の分岐、500 の理由句）は `ByteArrayInputStream` で検証する

Flix の書き方の決まりは [docs/flix-conventions.md](docs/flix-conventions.md)、
コードの流儀は [AGENTS.md](AGENTS.md) を参照。
