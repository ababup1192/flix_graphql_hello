# ログの試用レポート（2026-09-08）

ログの設置（`docs/logging.md` v1）が一通り終わった所で、MCP（`claude -p` に `scripts/mcp-trial/prompt.txt` の 13 シチュエーション）と手の curl で叩き、
stdout に出た行を読んだ結果。`CMS_LOG_LEVEL=info`、`CMS_AUTH=dev`、`version` は `dev`。ソースは直していない（提案まで）。

## 全体像

- 起動から終了まで **231 行**、全部 JSON（`bin/flix run` が出すコンパイラの平文は `listening` より前だけ。本番の fat jar では出ない）
- severity: **info 229 / warn 2 / error 0 / debug 0**。warn は Origin 違いの 403 と Webhook の再試行
- message: `request` 141（200: 119、400: 7、405: 4、404: 4、202: 4、413: 1、403: 1）、`mcp tools/call` 88、`job done` 1、`job retry` 1、`listening` 1
- `/health` は 1 行も出ていない（info では出ない。応答ヘッダの `X-Request-Id` は返る）
- 出たキー: 一覧（`docs/logging.md`）に無い物は無し。`user.id` / `api_key.name` / `exception.*` / `error.code` / `entity` は今回 1 行も出ていない（リゾルバの中の行は DB の失敗だけなので）
- MCP のツール別: create_entry 19 ok / 5 error、get_entry 12 / 1、publish 9 / 2、search_entries 7、impact 6、publish_check 5、update_entry 4 / 2、diff_entry 4、whoami 3、unpublish 2 / 1、preview_url 2、delete_entry 1 / 1、restore_version 1、list_types 1

## 個人情報・秘密の検査

grep で見た物: `dev@localhost`（CMS_BOOTSTRAP_OWNER）、鍵の値（`cms_` + 43 字）、`cmspat_`、`Bearer`、`Detail:`、pepper（`dev-pepper`）、MinIO の secret、entry の題（`S1 公開してすぐ取り消し` など）、300 KB の本文（`Lorem ipsum`）、Webhook の URL（`127.0.0.1:9/hook`）、`expectedVersion`、`"fields"`。

**サーバの行には 1 つも入っていない。** 唯一の一致は `make run` が echo した環境変数の行（コンパイラの前の平文。fat jar では出ない）。
43 KB の本文を持つ create_entry / get_entry も `http.request.body.size: 43630` / `http.response.body.size: 43726` の数字だけ。MCP の引数は `id` しか残らない。

## シチュエーションごとに出た行

MCP の tools/call は毎回 **2 行**（`mcp tools/call` と `request`。同じ `request.id`）。表では tools/call 1 回 = 2 行として数える。

| # | シチュエーション | 出た行 | 評価 |
|---|---|---|---|
| 0 | `claude` が繋ぐ（2 サーバ） | サーバごとに `request` 400 → 200（initialize）→ 202（notifications/initialized）→ **405（GET /mcp）** → 200（tools/list）。`mcp.*` は無し | 400 は `MCP-Protocol-Version` の不一致（curl で再現。170 バイトの応答で一致）だが、行に理由が無い。405 は SSE を試す GET で、`credential.kind` も `project` も付かない（ルート表に届く前）。どちらも「接続のたびに出る正常な 4xx」なので info で良いが、**理由の属性が無いので 400 の原因を行から追えない** |
| 1 | 公開 → 取り消し → 公開 | whoami ×2、list_types、create_entry、publish_check / impact / diff_entry、publish、impact、unpublish、publish。全部 `mcp.outcome: ok`、`id` は create 以外に付く | 妥当。create_entry の行に作った entry の `id` が無い（引数に無いので）。追跡は次の publish_check から |
| 2 | 参照のある記事 | publish → `mcp.outcome: error` + `request` に `graphql.error_codes: ["INVALID"]`。withDependencies で publish ok。著者の unpublish → error + INVALID | 妥当。ただし INVALID の中身（`violations` の何か）は行に無い |
| 3 | 10 件作って探す | create_entry ×10、publish ×4、search_entries ×4（duration 140〜300 ms） | 妥当。search_entries は絞りの条件も件数も行に無い（引数は残さない方針。件数だけは欲しい） |
| 4 | 直して戻す | update_entry、diff_entry、publish、restore_version | 妥当 |
| 5 | 競合 | get_entry ×2、update_entry ok、update_entry error + `CONFLICT`、get_entry、update_entry ok | 妥当。CONFLICT の `expectedVersion` / `actualVersion` は行に無い（要らない） |
| 6 | 読み取り専用の鍵 | create_entry error + `FORBIDDEN`、publish error + `FORBIDDEN`、get_entry ok、preview_url ok | **どの鍵か分からない。** `credential.kind` は editor も reader も `api-key`。`api_key.name` はリゾルバの中の行にしか付かず、今は DB の失敗の行しか無いので、事実上一度も出ない |
| 7 | 消したい | impact、delete_entry ok、その後の get_entry は `mcp.outcome: error` だが `request` に `graphql.error_codes` が **無い**（GraphQL は `data: null` で返り、NOT_FOUND は MCP 側が作るため） | MCP の行に `error.code` が無いので、`mcp.outcome: error` の理由が request の行にも無い場合がある |
| 8〜11 | 画像・プレビュー・予約・巨大本文 | preview_url ok ×2、create_entry（body 43630 バイト）、get_entry（応答 43726 バイト） | 妥当。本文は出ない |
| 12〜13 | 値の形・要約の上限 | create_entry error + `INVALID` ×5、update_entry error + `INVALID` | 妥当。INVALID の field は行に無い（要らない） |
| 手 | 間違った API キー（`X-Api-Key: cms_wrong…`） | **HTTP 200、info**、`credential.kind: api-key`、`graphql.error_codes: ["FORBIDDEN"]` | **401 にならない。** 知らない鍵は匿名に落ちて FORBIDDEN になり、行は「権限の無い正しい鍵」と区別できない。/mcp でも同じ（whoami が `ANONYMOUS` を返し `mcp.outcome: ok`）。総当たりが info の 200 に埋もれる |
| 手 | 死んだ PAT（`Bearer cmspat_deadbeef`） | /admin/graphql: **HTTP 200、info**、`credential.kind: pat`、`graphql.error_codes: ["UNAUTHENTICATED"]` | deploy/README は「死んだ PAT は 401」と言うが、それは /mcp だけ。GraphQL の経路は 200 + UNAUTHENTICATED で severity は info。401 と同じ扱い（warn）が要る |
| 手 | 無い entry（NOT_FOUND） | 200、info、`graphql.operation.name: DeleteMissing`、`graphql.error_codes: ["NOT_FOUND"]` | 妥当。`entity` / `id` は request の行には無い（業務エラーの行が出ないので） |
| 手 | `X-Request-Id: trial-notfound-001` | `request.id: "trial-notfound-001"`、応答ヘッダにも同じ値 | 妥当 |
| 手 | 65 字の `X-Request-Id` | 捨てられて ULID（`01M1ZJMVMWFDYVKGAJH7776HB6`）。行もヘッダも ULID | 妥当 |
| 手 | `/health` | 行は出ない。ヘッダ `X-Request-Id` は返る | 妥当 |
| 手 | `GET /nope` | 404、info、`credential.kind` / `project` 無し | 妥当（ルート表の前） |
| 手 | 2 MB の本文 | **413、info、`http.request.method: "-"`、`url.path: "-"`、`request.id` 無し**（`onServed` の経路） | method と path はヘッダを読んだ後に分かるはずなので `-` は惜しい。request.id が無いので応答ヘッダとも突き合わせられない |
| 手 | Origin 違いの `/mcp` | **403、warn**、`credential.kind: api-key` | severity は妥当。Origin の値（ホストだけで良い）が無いので、DNS rebinding の試みか管理画面の設定漏れかが分からない |
| 手 | `MCP-Protocol-Version: 2025-11-25` | 400、info | 理由の属性が無い（0 と同じ） |
| 手 | 壊れた JSON | 400、info | 理由の属性が無い |
| 手 | プレビュートークンで `/mcp` | 400、info、`credential.kind: preview` | 妥当 |
| 手 | 無いプロジェクト `/p/nosuch/admin/graphql` | 404、info、`project: nosuch` | 妥当 |
| 手 | 予約公開（過去の時刻） | `job done`、info、`job.kind: schedule`、`job.id`（ULID）、`id`（entry）、`detail: publish e01619631a48` | 妥当。**`project` が無い** |
| 手 | Webhook（受け手が落ちている） | `job retry`、warn、`job.kind: webhook`、`http.response.status_code: 0`、`detail: HTTP 0 IoError(ConnectionFailed, java.net.ConnectException)` | severity は妥当。**`project` も webhook の id も無い**ので、どの受け手が落ちているか行から分からない。`status_code: 0` は「繋がらなかった」の印としては読みにくい |

### 行の実例

```json
{"time":"2026-09-08T03:40:13.373Z","severity":"info","message":"mcp tools/call","credential.kind":"api-key","duration_ms":29,"http.request.method":"POST","id":"32778237421c","mcp.outcome":"error","mcp.tool":"publish","request.id":"01M1ZHM7N013G9DMDQ1B5C2GX5","service":"cms","url.path":"/mcp","version":"dev"}
{"time":"2026-09-08T03:40:13.373Z","severity":"info","message":"request","credential.kind":"api-key","duration_ms":29,"graphql.error_codes":["INVALID"],"graphql.operation.type":"mutation","http.request.body.size":194,"http.request.method":"POST","http.response.body.size":405,"http.response.status_code":200,"project":"default","request.id":"01M1ZHM7N013G9DMDQ1B5C2GX5","service":"cms","url.path":"/mcp","version":"dev"}
{"time":"2026-09-08T03:39:42.756Z","severity":"info","message":"request","duration_ms":0,"http.request.body.size":0,"http.request.method":"GET","http.response.body.size":48,"http.response.status_code":405,"request.id":"01M1ZHK9S3682ZGD8C4BDMKAWX","service":"cms","url.path":"/mcp","version":"dev"}
{"time":"2026-09-08T03:57:03.019Z","severity":"info","message":"request","credential.kind":"api-key","duration_ms":6,"graphql.error_codes":["FORBIDDEN"],"graphql.operation.type":"query","http.request.body.size":38,"http.request.method":"POST","http.response.body.size":228,"http.response.status_code":200,"project":"default","request.id":"trial-badkey","service":"cms","url.path":"/admin/graphql","version":"dev"}
{"time":"2026-09-08T03:57:27.883Z","severity":"info","message":"request","credential.kind":"pat","duration_ms":12,"graphql.error_codes":["UNAUTHENTICATED"],"graphql.operation.type":"query","http.request.body.size":38,"http.request.method":"POST","http.response.body.size":237,"http.response.status_code":200,"project":"default","request.id":"trial-deadpat","service":"cms","url.path":"/admin/graphql","version":"dev"}
{"time":"2026-09-08T03:56:46.786Z","severity":"warn","message":"request","credential.kind":"api-key","duration_ms":0,"http.request.body.size":40,"http.request.method":"POST","http.response.body.size":108,"http.response.status_code":403,"project":"default","request.id":"trial-origin","service":"cms","url.path":"/mcp","version":"dev"}
{"time":"2026-09-08T03:57:24.540Z","severity":"info","message":"request","duration_ms":0,"http.request.body.size":0,"http.request.method":"-","http.response.body.size":0,"http.response.status_code":413,"service":"cms","url.path":"-","version":"dev"}
{"time":"2026-09-08T03:58:25.713Z","severity":"info","message":"job done","detail":"publish e01619631a48","id":"e01619631a48","job.id":"01M1ZJNJ46S1M1HV7BE25Q9W6J","job.kind":"schedule","job.outcome":"done","service":"cms","version":"dev"}
{"time":"2026-09-08T03:58:25.753Z","severity":"warn","message":"job retry","detail":"HTTP 0 IoError(ConnectionFailed, java.net.ConnectException)","http.response.status_code":0,"job.id":"01M1ZJNJDC2W2F8DQ3APC1ZNRB","job.kind":"webhook","job.outcome":"retry","service":"cms","version":"dev"}
```

## severity は妥当か

- 2xx / 4xx = info、403 = warn、Webhook の再試行 = warn は読んでいて違和感が無い
- **認証の失敗が info に埋もれる**のが問題。知らない API キー（200 + FORBIDDEN）と死んだ PAT（200 + UNAUTHENTICATED）は HTTP は 200 なので `responseSeverity` が info にする。docs/logging.md の「401 / 403 は warn」の意図（総当たりと設定漏れを拾う）が GraphQL の経路では効いていない
- error は 1 行も出なかった（DB もワーカーも健全だったので当然）。`exception.*` の形は今回見られていない

## 足りない属性・多すぎる行・読みにくい所

1. **誰の鍵か分からない**（`api_key.name` / `user.id` がリクエストの行に無い）。reader と editor の FORBIDDEN が同じに見える。監査（誰が publish したか）にも使えない
2. **tools/call が 2 行**（`mcp tools/call` + `request`）。同じ request.id・同じ duration で情報が分かれている。`mcp` の行には `project` が無く、`request` の行には `mcp.tool` が無い。Loki で「どのツールが遅いか」を見るのに 2 行を join できない
3. **4xx に理由が無い**（400 の protocol version / 壊れた JSON、403 の Origin、405）。MCP の接続のたびに 400 と 405 が 1 つずつ出るので、集計で「400 が多い」に見えて原因が追えない
4. **`mcp.outcome: error` の理由が無い**。GraphQL の errors から来る物は request の行の `graphql.error_codes` で分かるが、MCP 側が作る NOT_FOUND（消した entry の get_entry）は両方の行に code が無い
5. **ワーカーの行に `project` が無い**。Webhook の行には webhook の id も無い。「どのプロジェクトのどの受け手が落ちているか」が行から分からない（`job.id` から DB を引くしかない）
6. **413 の行が `-`**（method / path / request.id 無し）
7. `graphql.operation.name` が MCP の全リクエストで無い（McpTools の query が無名）。管理 API でも `setup.sh` のような無名の操作では付かない。MCP は `mcp.tool` で足りるが、request の行だけ見る時は名前があると読みやすい
8. Webhook の `http.response.status_code: 0` は「繋がらなかった」の意味だが、集計で 0 が混ざる。`detail` の `IoError(ConnectionFailed, java.net.ConnectException)` は Flix の enum の文字列で人向けでない
9. `create_entry` の行に作った entry の `id` が無い（引数に無いから）。結果から取れば付く

## 直す提案（優先順）

1. **認証の失敗を warn に**（今すぐ）。`graphql.error_codes` に `UNAUTHENTICATED` があれば warn、知らない API キー / 見つからない PAT は `credential.kind` を `invalid` にして warn（RequestIdentity が匿名に落とす所で印を残す）。`responseSeverity` は status だけでなく `extra` の error_codes も見る。合わせて deploy/README の「死んだ PAT は 401」を GraphQL の経路（200 + UNAUTHENTICATED）と分けて書く
2. **主体の印をリクエストの行に**。Runner が解決した `resolved#log`（`user.id` / `api_key.name`）を Context に積むだけでなく `extra` にも返す（graphql-java のコールバックの外に持ち出す口が要る。`Graphql.executeWith` の応答に載せるか、Context の Ref に書く）。docs/logging.md の「付く行」も「リクエストの行」に広げる
3. **MCP の行を request の行に畳む**。`logMcpCall` を消し、`mcp.tool` / `mcp.outcome` / `id` を `extra` に積む（tools/call の 1 リクエスト = 1 行）。`docs/logging.md` の「リクエストは 1 行」の方針と揃う。`mcp.outcome: error` の時は `error.code`（isError の content の `code`）も乗せる
4. **4xx の理由を `error.code` / `error.message` に**。`mcpPrecheck` と `executeBody` の 400 / 403 / 415、Router の 404 / 405 で `errorResponse` を作る所から理由を `extra` に積む。403 は Origin のホストも（`origin` キーを表に足す）
5. **ワーカーの行に `project`（slug）と webhook の id**。`JobLog.write` の呼び手が `claimed#projectId` を持っているので slug に引いて渡す。Webhook は `webhook.id`（表に足す）、繋がらなかった物は `status_code` を付けず `error.message` に
6. **413 / 431 の行に method / path**。HttpServer はヘッダを読んだ後で Content-Length を見ているので `unreadable` に method / path を渡せる。request.id はヘッダにあれば拾える
7. McpTools の query / mutation に名前を付ける（`graphql.operation.name` が乗る。graphql-java のエラーの `path` も読みやすくなる）
8. `create_entry` / `update_entry` の MCP の行に結果の `id` を乗せる（`callSummary` が `result.structuredContent.id` を見る）

## 実験のメモ

- 1 回目の `claude -p` はシチュエーション 10 の途中（03:42:42 の unpublish の後）で 9 分無反応（CPU 0%）になったので止め、`--continue` で 11〜13 と report.md を書かせた。MCP の行は 88、tools/call の error は 12
- SIGTERM で止めると最後に `jobs drained`（info）が 1 行。`jobs stopping` は出ず（`stopping` の判定が周の頭にしか無い）、「listen をやめた」の行も無いので、止めた事が行から分かりにくい（提案 9: `shutdown` の 1 行）
- `scripts/mcp-trial/README.md` の手順どおり。設定ファイルの鍵は実験の後に消し、`docker compose down -v` で DB も消した
