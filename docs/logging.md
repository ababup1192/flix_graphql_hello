# ログ（v1）

ログは stdout に 1 行 1 JSON。呼ぶ側は `Log` effect（`src/log`）、出力先は `Main` が組む `Sink`（`CMS_LOG_LEVEL` で絞る → `service` / `version` を足す → JSON）。
キーの名前は OpenTelemetry の semantic conventions に合わせる（後で OTLP を出す時に変換表が要らない）。

**キーを足す時はこの表に 1 行足す。** `make check` の `scripts/check-log-keys.sh` が、src の `Log.Fields.str("…"` などの literal をここと突き合わせ、
表に無いキーがあれば落ちる。email・URL のクエリ・生の鍵やトークンをキーにしない（秘密は境界で決める）。

## 行の形

```json
{"time":"2026-09-08T02:53:20.123Z","severity":"info","message":"request","service":"cms","version":"3f2a1c9",
 "request.id":"01J9ZK3Q8R6S4T2V1W0X9Y8Z7A","http.request.method":"POST","url.path":"/admin/graphql",
 "http.response.status_code":200,"duration_ms":12,"http.request.body.size":120,"http.response.body.size":340,
 "credential.kind":"pat","project":"default","graphql.operation.type":"mutation","graphql.operation.name":"Publish","graphql.error_codes":["NOT_FOUND"]}
```

- `time` は UTC の ms 固定（`.000Z` も出す）、`severity` は `trace` / `debug` / `info` / `warn` / `error` / `fatal`、`message` は人が読む短い文
- 文字列の制御文字は落とす（log injection）。URL のクエリ文字列は出さない（プレビュートークンが入りうる）
- リクエストは 1 行。失敗の中身（`graphql.error_codes`、`exception.*`）はその行の属性にする（Loki は行を join できない）

## キーの一覧

| キー | 型 | 付く行 | 出所 |
|---|---|---|---|
| `service` | string | 全行 | Sink（`cms` 固定） |
| `version` | string | 全行 | Sink（`CMS_VERSION`。イメージの git の sha） |
| `request.id` | string | リクエストの span | `X-Request-Id` を受ける（64 字以内・`[A-Za-z0-9_-]`。外れたら捨てる）。無ければ ULID。応答ヘッダ `X-Request-Id` で必ず返し、INTERNAL のエラーの時だけ GraphQL の `extensions.requestId` にも入れる |
| `cf.ray` | string | リクエストの span | Cloudflare の `CF-Ray` があれば |
| `http.request.method` | string | リクエストの span | |
| `url.path` | string | リクエストの span | クエリ文字列と制御文字を落とした後 |
| `http.response.status_code` | int | リクエストの行、Webhook の行 | |
| `duration_ms` | int | リクエストの行 | ソケットの読み書きを含まない |
| `http.request.body.size` | int | リクエストの行 | UTF-8 のバイト数 |
| `http.response.body.size` | int | リクエストの行 | UTF-8 のバイト数 |
| `project` | string | リクエストの行、リゾルバの中の行 | プロジェクト slug（パス・Host・既定） |
| `credential.kind` | string | リクエストの行、リゾルバの中の行 | `jwt` / `api-key` / `pat` / `preview` / `anonymous` / `invalid`。ヘッダから読んだ種類。Runner が知らない鍵・合わないプレビュートークン・死んだ PAT を `invalid` に上書きする |
| `user.id` | string | リクエストの行、リゾルバの中の行 | 本人の public_id（email は出さない） |
| `api_key.name` | string | リクエストの行、リゾルバの中の行 | 鍵の名前（鍵は出さない） |
| `graphql.operation.type` | string | リクエストの行 | `query` / `mutation` / `subscription` |
| `graphql.operation.name` | string | リクエストの行 | operationName か文書の操作の名前。無ければ付かない |
| `graphql.error_codes` | string[] | リクエストの行 | `errors[].extensions.code` の一覧（重複無し）。graphql-java の検証エラーは `classification`。業務エラーの率がこれで見える |
| `exception.type` | string | Error の行 | `Log.exception` |
| `exception.message` | string | Error の行 | 200 字。`Detail:` 以降は落とす（PG が行の値を入れるため） |
| `exception.stacktrace` | string | Error の行 | Flix の frame だけ 8 つ |
| `error.code` | string | 業務エラーの行、リゾルバの失敗の行、4xx のリクエストの行、MCP の error の行 | 業務エラーは GraphQL の `extensions.code` と同じ文字列。4xx は短い固定の語（`no_route` / `method_not_allowed` / `unsupported_media_type` / `bad_json` / `bad_request` / `jobs_token` / `no_project` / `unavailable`、MCP の `origin` / `protocol_version` / `preview_token` / `unauthenticated`）。MCP の tools/call が isError なら content の `code` |
| `error.message` | string | 起動の失敗、ワーカーの失敗、リゾルバの失敗、4xx のリクエストの行 | 人が読む文。4xx は応答本文と同じ文 |
| `origin` | string | 403 のリクエストの行（MCP） | 断った `Origin` の scheme + host（パスやクエリは無い） |
| `entity` | string | 業務エラーの行 | `extensions.entity` と同じ |
| `id` | string | 業務エラーの行、予約公開の行、MCP のリクエストの行、プレビューの span | entry の id など。連番は出さない。MCP は引数の id、無ければ結果の id（create_entry で作った物） |
| `job.kind` | string | ワーカーの行 | `schedule` / `webhook` |
| `job.id` | string | ワーカーの行 | 予約の id、配信の ULID（`X-Cms-Delivery` と同じ。受け手のログと突き合わせる相関 id） |
| `job.outcome` | string | ワーカーの行 | `done` / `failed` / `retry` / `delivered` |
| `detail` | string | ワーカーの行 | `publish e_x`、`HTTP 500 …` など |
| `mcp.tool` | string | リクエストの行（`POST /mcp` の tools/call） | ツール名。引数は残さない。MCP の行は別に出さない（1 リクエスト 1 行） |
| `mcp.outcome` | string | リクエストの行（`POST /mcp` の tools/call） | `ok` / `error`（isError。理由は `error.code`） |
| `server.address` | string | 起動の行 | bind したアドレス |
| `server.port` | int | 起動の行 | |
| `migration.version` | string | 起動の行 | `CMS_MIGRATE=apply` で当てた migration |
| `db.user` | string | 起動の行 | 所有者で繋ぐ時の警告 |

## severity の決め

| severity | 何を |
|---|---|
| error | 5xx、handle の例外、Webhook の最後の失敗、予約公開の失敗、リゾルバの DB の失敗（INTERNAL）、ワーカーの 1 周の失敗 |
| warn | 401 / 403、知らない鍵・死んだ PAT（HTTP は 200 でも `credential.kind: invalid` か `graphql.error_codes` に `UNAUTHENTICATED`）、限界の 503、Webhook の再試行、jobs off、所有者で DB に繋ぐ |
| info | 2xx / 4xx のリクエストの行（404 / 400 はユーザーの正常な失敗。MCP の tools/call もこの行）、job の done / delivered、起動 |
| debug | `/health` の 2xx（外形監視で 1 日 1.4k 行。集計を汚さない） |
| fatal | 起動の失敗（この後 exit 1）、OutOfMemoryError |

`CMS_LOG_LEVEL`（既定 `info`）より軽い行は出ない。

## 出る場所と span

- リクエスト: 接続のスレッドの入口（`Main.dispatch`）で `Log.runWith(sink)` を入れ直し、`request.id` / `cf.ray` / method / path の span を張る。
  リクエストの行は処理の後に `Main.serveRequest` が出す。Route の handler と 404 / 405 の分岐は `Observe` effect（`Observe.note`）で属性（`mcp.*`、4xx の `error.code` / `error.message`）を積み、`serveRequest` が `extra` に受ける。HttpServer が見た失敗（handle の例外、読めない 400 / 413 / 431、混雑の 503、書けなかった）は `onServed` から別に出る（request.id は無い）
- リゾルバの中: Runner が `deps#log` で入れ直し（graphql-java の Java コールバックの中なので dispatch の handler は届かない）、Context の span に `user.id` / `api_key.name` を足す。今出るのは DB の失敗（`field failed`）だけ。
  同じ属性（と検証に落ちた印）は Context の `observe` でリクエストの行にも戻す（Ref を閉じ込めた関数の値。Java のコールバックの中から effect は届かない）
- ワーカー: `BackgroundJobs.runForever` が周ごとに入れ直す。外部トリガー `POST /jobs/tick` はリクエストの span の中で出る
- 起動: `main` が全体を包む。`CMS_MODE=import-microcms` のまとめは Log でなく stdout の平文（コマンドの出力）

## Loki

ラベルは `service` だけ。`severity` は JSON から拾う。`request.id` / `url.path` / `project` をラベルにしない（ストリームが無限に増える）。
JSON でない行（OOM の平文など）は `__error__ != ""` で拾う。
