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
| `http.response.status_code` | int | リクエストの行、Webhook の行 | Webhook は応答があった物だけ（繋がらなかった物は `error.message`。0 は出さない） |
| `duration_ms` | int | リクエストの行 | ソケットの読み書きを含まない |
| `http.request.body.size` | int | リクエストの行 | UTF-8 のバイト数 |
| `http.response.body.size` | int | リクエストの行 | UTF-8 のバイト数 |
| `project` | string | リクエストの行、リゾルバの中の行、ワーカーの行 | プロジェクト slug（パス・Host・既定。ワーカーは拾った行の project_id から） |
| `credential.kind` | string | リクエストの行、リゾルバの中の行 | `jwt` / `api-key` / `pat` / `preview` / `anonymous` / `invalid`。ヘッダから読んだ種類。認証（`Main.runRoute`）が知らない鍵・合わないプレビュートークン・死んだ PAT・壊れたログインの JWT を `invalid` に上書きする。鍵の時は理由が `error.code`（`api_key_unknown` / `api_key_expired` / `api_key_revoked`）に付く（HTTP は 200 のまま） |
| `user.id` | string | リクエストの行、リゾルバの中の行 | 本人の public_id（email は出さない）。認証（リクエストに 1 回）が決め、リゾルバの span にも写す |
| `api_key.name` | string | リクエストの行、リゾルバの中の行 | 鍵の名前（鍵は出さない） |
| `graphql.operation.type` | string | リクエストの行 | `query` / `mutation` / `subscription` |
| `graphql.operation.name` | string | リクエストの行 | operationName か文書の操作の名前。無ければ付かない |
| `graphql.error_codes` | string[] | リクエストの行 | `errors[].extensions.code` の一覧（重複無し）。graphql-java の検証エラーは `classification`。認証に落ちたリクエスト（path 無しの 1 件）もここ。業務エラーの率がこれで見える |
| `exception.type` | string | Error の行 | `LogFields.exception`。graphql-java が包む `CompletionException` は剥がして中の例外の型 |
| `exception.message` | string | Error の行 | 200 字。`Detail:` 以降は落とす（PG が行の値を入れるため） |
| `exception.stacktrace` | string | Error の行 | Flix の frame だけ 8 つ |
| `error.code` | string | 業務エラーの行、リゾルバの失敗の行、4xx / 503 のリクエストの行、MCP の error の行、鍵が検証に落ちた行 | 業務エラーと認証の断り（MCP の 401）は GraphQL の `extensions.code` と同じ綴り（`UNAUTHENTICATED` / `REQUIRES_LOGIN` / `FORBIDDEN`）。4xx / 503 は短い固定の語（`no_route` / `method_not_allowed` / `unsupported_media_type` / `bad_json` / `bad_request` / `jobs_token` / `no_project` / `unavailable`、MCP の `origin` / `protocol_version` / `preview_token`）。鍵が検証に落ちた 200 の行は `api_key_unknown` / `api_key_expired` / `api_key_revoked`。MCP の tools/call が isError なら content の `code` |
| `error.message` | string | 起動の失敗、ワーカーの失敗、リゾルバの失敗、4xx のリクエストの行、繋がらなかった Webhook の行 | 人が読む文。4xx は応答本文と同じ文、Webhook は「接続できませんでした: java.net.ConnectException」のような文 |
| `error.kind` | string | リゾルバの失敗の行、DB に届かなかった 503 のリクエストの行 | DB の失敗の種類（sqlfx の TransientDbErr の名前 `deadlock` / `timeout` / `connectionLost` と、失敗した SQL の後の COMMIT が弾かれた `rollback`）。再試行で枯渇した物は最後の失敗の種類。「DB が落ちた」と「DB が遅い」を読み分ける。制約違反などには付かない |
| `db.retries` | int | リクエストの行 | 一時的な失敗で呼び直した回数。1 以上の時だけ。リクエストの中の Tx 全部（認証と版を読む Tx を含む）の和。DB が落ちている時の 503 の行にも付く |
| `db.statements` | int | リクエストの行 | そのリクエストで出した SQL の数（fetch / execute / executeReturning を 1 と数える。RLS の印と認証の SQL を含む）。Tx ごとに DbRunner が observe で戻し（認証の Tx も Runner の Tx も）、受ける側（`LogFields.mergeCounts`）が足す。上限は `test/Pg/TestQueryBudgetPg` |
| `db.transactions` | int | リクエストの行 | そのリクエストで張った Tx の数。読むだけの文書は認証の 1 つ + リクエストの Tx 1 つ（接続を借りた時だけ）。mutation を含む文書は認証の 1 つ + ルートフィールドと入れ子のフィールドの数（`DbRunner.transact` を呼んだ回数。SQL を出さなかった物も数える） |
| `db.tx.outcome` | string | リクエストの行（読むだけの文書） | リクエストの Tx の結末。`committed` / `rolled_back`（DB の失敗で Broken。残りのフィールドは INTERNAL）/ `none`（SQL を出さなかった。接続を借りていない） |
| `db.tx.held_ms` | int | リクエストの行（読むだけの文書で接続を借りた物） | 接続を借りてから COMMIT / ROLLBACK して返すまでのミリ秒。応答の書き出しは含まない。プールの本数の目安に使う（`deploy/README.md`） |
| `db.pool.waiting` | int | リクエストの行 | DB の接続プールを借りるのを待っているスレッドの数。Tx を張る前（認証と版を読む Tx、Runner の Tx）に読み、1 以上の時だけ。同じリクエストの中では一番大きい値（304 の道のように Runner を通らない物にも付く） |
| `db.pool.active` | int | リクエストの行、`self-heal: exiting` の行 | 借りられている接続の数。リクエストの行には `db.pool.waiting` が付く時だけ |
| `db.pool.idle` | int | `self-heal: exiting` の行 | 空いている接続の数 |
| `db.pool.total` | int | `self-heal: exiting` の行 | 開いている接続の数（active + idle） |
| `db.pool.max` | int | `self-heal: exiting` の行 | プールの上限 |
| `jobs.stalled_ms` | int | `/health` のリクエストの行 | 仕事の周が最後に回ってからの経過。上限（30 秒）を超えて 503 にした時だけ |
| `watch.stalled_ms` | int | `/health` のリクエストの行 | 自己回復の見張りの周が最後に回ってからの経過。上限（30 秒）を超えて 503 にした時だけ |
| `reason` | string | `self-heal: exiting` の行、`/health` の 503 のリクエストの行 | 自分で終わると決めた理由（何 ms 届かなかったか）。`/health` は応答の `db`（DB に届かない理由）か `reason`（`jobs stalled` / `watch stalled`）と同じ文 |
| `origin` | string | 403 のリクエストの行（MCP） | 断った `Origin` の scheme + host（パスやクエリは無い） |
| `entity` | string | 業務エラーの行 | `extensions.entity` と同じ |
| `id` | string | 業務エラーの行、予約公開の行、MCP のリクエストの行、プレビューの span | entry の id など。連番は出さない。MCP は引数の id、無ければ結果の id（create_entry で作った物） |
| `job.kind` | string | ワーカーの行 | `schedule` / `webhook` / `cdn_purge` |
| `job.id` | string | ワーカーの行 | 予約の id、配信の ULID（`X-Cms-Delivery` と同じ。受け手のログと突き合わせる相関 id） |
| `job.outcome` | string | ワーカーの行 | `done` / `failed` / `retry` / `delivered` |
| `detail` | string | ワーカーの行 | `publish e_x`、`HTTP 500`、`接続できませんでした: …` など |
| `webhook.id` | string | Webhook の行 | Webhook の public_id（管理 API の `Webhook.id`）。消えた Webhook の行には無い |
| `cache.status` | string | リクエストの行（コンテンツ API の `GET /graphql` で認証が通った物） | `hit`（If-None-Match が ETag に合って 304。GraphQL は実行しない）/ `miss`（匿名で 200）/ `bypass`（鍵やトークン付き。no-store） |
| `mcp.tool` | string | リクエストの行（`POST /mcp` の tools/call） | ツール名。引数は残さない。MCP の行は別に出さない（1 リクエスト 1 行） |
| `mcp.outcome` | string | リクエストの行（`POST /mcp` の tools/call） | `ok` / `error`（isError。理由は `error.code`） |
| `server.address` | string | 起動の行 | bind したアドレス |
| `server.port` | int | 起動の行 | |
| `migration.version` | string | 起動の行 | `CMS_MIGRATE=apply` で当てた migration |
| `db.user` | string | 起動の行 | 所有者で繋ぐ時の警告 |
| `shutdown.connections` | int | `shutdown timed out` の行 | 期限までに閉じなかった HTTP の接続の数 |
| `shutdown.in_tick` | bool | `shutdown timed out` の行 | 仕事の 1 周が途中のままだったか |

## severity の決め

| severity | 何を |
|---|---|
| error | 5xx、handle の例外、Webhook の最後の失敗、予約公開の失敗、リゾルバの DB の失敗（INTERNAL）、ワーカーの 1 周の失敗 |
| warn | 停止の待ち切れ（`shutdown timed out`。この後 exit 2）、401 / 403、知らない鍵・死んだ PAT（HTTP は 200 でも `credential.kind: invalid` か `graphql.error_codes` に `UNAUTHENTICATED`）、限界の 503、Webhook の再試行、jobs off、所有者で DB に繋ぐ |
| info | 2xx / 4xx のリクエストの行（404 / 400 はユーザーの正常な失敗。MCP の tools/call もこの行）、job の done / delivered、起動（`listening`）、停止（SIGTERM / SIGINT の `shutting down` → `jobs drained`） |
| debug | `/health` の 2xx（外形監視で 1 日 1.4k 行。集計を汚さない） |
| fatal | 起動の失敗（この後 exit 1）、OutOfMemoryError |

`CMS_LOG_LEVEL`（既定 `info`）より軽い行は出ない。

## 出る場所と span

- リクエスト: 接続のスレッドの入口（`Main.dispatch`）で `Log.runWith(sink)` を入れ直し、`request.id` / `cf.ray` / method / path の span を張る。
  リクエストの行は処理の後に `Main.serveRequest` が出す。Route の handler と 404 / 405 の分岐は `Observe` effect（`Observe.note`）で属性（`mcp.*`、4xx の `error.code` / `error.message`）を積み、`serveRequest` が `extra` に受ける。処理が JVM の例外で抜けた物も `Main.dispatch` が同じ span と `extra` で出す（500、`exception.*` は包みを剥がした例外）。HttpServer が見た失敗（読めない 400 / 413 / 431、混雑の 503、書けなかった）は `onServed` から別に出る（413 / 431 はヘッダまで読めているので method / path と、`X-Request-Id` があれば `request.id` が付く。ULID は作らない）
- リゾルバの中: Runner が `deps#log` で入れ直す（graphql-java の Java コールバックの中なので dispatch の handler は届かない）。span は `Main.runRoute` が request の span に `credential.kind` / `project` と認証の属性（`user.id` / `api_key.name` / 検証に落ちた印）を merge した物。今出るのは DB の失敗（`field failed`）だけ。
  Runner が数えた SQL と Tx の数は Context の `observe` でリクエストの行に戻す（Ref を閉じ込めた関数の値。Java のコールバックの中から effect は届かない）
- ワーカー: `BackgroundJobs.runForever` が周ごとに入れ直す。外部トリガー `POST /jobs/tick` はリクエストの span の中で出る
- 自己回復: プールが壊れたまま戻らないと決まったら `self-heal: exiting`（error。`reason` とプールの数字）を出し、停止と同じ drain をして終了コード 3 で終わる。
  その後の `Terminating due to java.lang.OutOfMemoryError` のような JVM の平文は JSON にできないので、収集器は終了コードとこの行で判断する
- 起動: `main` が全体を包む。`CMS_MODE=import-microcms` のまとめは Log でなく stdout の平文（コマンドの出力）
- 停止: SIGTERM / SIGINT の handler（`Shutdown.stop`）が `shutting down` を出してから listen を閉じ、HTTP の接続が引けるのを待ち、実行中の 1 周を待って `jobs drained`（上限を超えれば warn の `jobs drain timed out`）。
  期限（`CMS_SHUTDOWN_TIMEOUT_SECONDS`）までに片付かなければ warn の `shutdown timed out`（`shutdown.connections` / `shutdown.in_tick`）を出して終了コード 2、全部片付けば 0

## Loki

ラベルは `service` だけ。`severity` は JSON から拾う。`request.id` / `url.path` / `project` をラベルにしない（ストリームが無限に増える）。
JSON でない行（OOM の平文など）は `__error__ != ""` で拾う。
