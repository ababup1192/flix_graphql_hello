# 動かし方（VPS 1 台・セルフホスト）

Hetzner や自宅のサーバに Docker と docker compose があれば、この 4 手順で動く。ラズパイ（arm64）も同じ。

```bash
git clone https://github.com/ababup1192/flix_graphql_hello.git && cd flix_graphql_hello/deploy
cp .env.example .env          # POSTGRES_PASSWORD / MINIO_ROOT_PASSWORD / ASSET_PUBLIC_URL を入れる
docker compose up -d          # cms が起動時に migrations/ を当てる
curl -s localhost:8080/health # {"status":"ok","version":"..."}
```

外へ出す入口は 2 通り。

- **Cloudflare Tunnel（おすすめ。ポートを開けない）**: cloudflared をこの VPS に入れ、`cms.example.com → http://localhost:8080`、`assets.example.com → http://localhost:9000` の 2 本を向ける。`ASSET_PUBLIC_URL=https://assets.example.com/cms`
- **Caddy**: `docker compose --profile caddy up -d`。`CMS_DOMAIN` と `ASSET_DOMAIN` の DNS をこの VPS に向ければ TLS は自動

## テナント分離（RLS）

プロジェクトの中身の表（content_types / content_fields / entries / entry_versions / entry_links / assets）と auth の表（memberships / invitations / api_keys）には PostgreSQL の RLS が掛かっている。
リクエストの Tx の先頭で `app.project_id` の印を置き、policy はその印と一致する行しか見せない（印が無ければ 0 行）。
`CMS_DB_APP_PASSWORD` を入れると所有者でないロール `cms_app` で繋ぎ、SQL インジェクションや生 SQL があっても他のプロジェクトの行は出ない。

## プレビュー（下書きを公開前のサイトで見る）

管理 API の `createPreviewToken(entryId)` が `pv_...` のトークンと、型の `previewUrl` から組んだ url（`?preview=<token>` 付き）を返す。
サイトはその token を `X-Preview-Token` ヘッダに付けてコンテンツ API に `stage: DRAFT` で問い合わせる。読めるのはその entry と参照先の下書きだけで、一覧の下書きや他の entry は読めない。
既定 1 時間、最長 1 日で切れる。無状態（表を持たない）なので、鍵（`CMS_API_KEY_PEPPER`）を回せば全部無効になる。

## CI 用の API キー（WRITE）と自分の Personal Access Token（PAT）

人の代わりに叩く身元は 2 種類。**プロジェクトの API キー**（CI やビルド。`X-Api-Key`）と、**自分の PAT**（CLI やスクリプト。`Authorization: Bearer cmspat_...`）。
どちらも生の値は発行した応答でしか見えず、DB には `CMS_API_KEY_PEPPER` を混ぜたハッシュだけ置く。

**CI 用の API キー**は owner が管理 API で作る。`scope: WRITE` に役割を付けると、その役割の範囲で管理 API の mutation を叩ける（entry の作成・公開、型の編集など）。
メンバー・鍵・プロジェクトの管理は owner の役割の鍵でもできない（鍵で鍵やメンバーを作る道を作らない）。`expiresAt`（未来の時刻だけ）を付けるとその時刻で切れ、`apiKeys` の `lastUsedAt` に最後に管理 API で使った時刻（1 分の粒度）が出る。
**API キーの発行はログインした本人（管理画面か、ログインの JWT を付けた curl）から。** PAT や API キーからは作れない（漏れた PAT を失効すれば、それで作られた物は無い）。鍵が書いた版の author は `api-key:<鍵の名前>`。

```bash
# owner がログインの JWT で発行。key はこの応答でしか見えない
curl -s -X POST https://cms.example.com/p/blog/admin/graphql -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
  -d '{"query": "mutation { createApiKey(name: \"github-actions\", scope: WRITE, role: EDITOR, expiresAt: \"2027-01-01T00:00:00Z\") { id key expiresAt } }"}'

# CI からはその鍵を X-Api-Key で渡す
curl -s -X POST https://cms.example.com/p/blog/admin/graphql -H "X-Api-Key: $CMS_API_KEY" -H 'Content-Type: application/json' \
  -d '{"query": "mutation { publishEntry(id: \"post-1\") { stage } }"}'
```

**自分の PAT**は Account API（`/account/graphql`）でログインの JWT から作る（PAT から PAT は作れない）。本人の役割で動き（プロジェクトごとに違ってよい）、`scope: READ` なら読むだけ（自分の me / 組織 / PAT の一覧は読める）。
`scope: WRITE` ならメンバー管理まで本人と同じにできるが、API キーと PAT の発行だけはできない。期限は必須（`ttlDays`。既定 90 日、最長 365 日）。
`me { personalAccessTokens { ... } }` で自分の分だけ見え、`revokePersonalAccessToken(id)` で失効できる（他人の物は見えない・失効できない）。
失効した PAT や期限切れの PAT で叩くと `認証に失敗しました: PAT は失効しています` のように断られる（黙って匿名にはならない）。

```bash
# ログインの JWT で 1 回だけ発行
curl -s -X POST https://cms.example.com/account/graphql -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
  -d '{"query": "mutation { createPersonalAccessToken(name: \"laptop\", scope: WRITE, ttlDays: 30) { token expiresAt } }"}'

# 以後は Authorization: Bearer cmspat_... で管理 API と Account API を自分として叩ける
curl -s -X POST https://cms.example.com/p/blog/admin/graphql -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
  -d '{"query": "{ me { email roles } }"}'
```

`CMS_AUTH_HEADER` が `Cf-Access-Jwt-Assertion` の環境でも、PAT は `Authorization` から読む（`cmspat_` で始まる Bearer だけ。それ以外の Bearer はログインの JWT として検証する）。`Bearer` の scheme は大文字小文字を問わない。

`CMS_API_KEY_PEPPER` を回すと、API キーと PAT は全部再発行になる（行の pepper_id は解決に使っていない）。

## MCP サーバ（AI エージェントから読み書き）

`POST /mcp`（プロジェクトを選ぶなら `/p/{プロジェクト slug}/mcp`）が MCP サーバ。管理 API のエンジンへの GraphQL クライアントとして動くので、
身元・権限・業務エラーの分類は管理 API と同じ（`X-Api-Key` の WRITE の鍵か、`Authorization: Bearer cmspat_...` の PAT。無ければ匿名で、公開中の読み取りだけ）。
喋るのは legacy（MCP 2025-06-18 の形。`initialize` の握手、セッション無し、`tools` だけ。resources / prompts は無い）。modern（server/discover）は v2。

```bash
# Claude Code に繋ぐ（鍵は createApiKey の scope: WRITE、PAT なら --header "Authorization: Bearer cmspat_..."）
claude mcp add --transport http cms http://127.0.0.1:8080/mcp --header "X-Api-Key: $CMS_API_KEY"

# 繋がったか（tools/list が 15 件返る）
claude mcp list

# 手で叩く
curl -s -X POST http://127.0.0.1:8080/mcp -H 'Content-Type: application/json' -H "X-Api-Key: $CMS_API_KEY" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
curl -s -X POST http://127.0.0.1:8080/mcp -H 'Content-Type: application/json' -H "X-Api-Key: $CMS_API_KEY" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_entry","arguments":{"type":"blogs","fields":{"title":"Hello","body":"# 見出し\n\n本文"}}}}'
```

ツール（15）: `list_types` / `get_type(apiId)` / `search_entries(type, search, first, skip, stage)` / `get_entry(id, stage, format)` / `diff_entry(id, from, to)` /
`create_entry(type, fields)` / `update_entry(id, fields, expectedVersion)` / `publish_check(id)` / `impact(id, action)` / `publish(id, withDependencies)` / `unpublish(id)` /
`delete_entry(id)`（ゴミ箱へ。戻せる） / `restore_version(id, versionId, expectedVersion)`（versionId は `get_entry` の `versions`） / `preview_url(id)` / `whoami()`（身元と使える権限）。
RICH_TEXT のフィールドは Markdown の文字列で書け、`get_entry` の `format`（markdown / text / html / doc）で読み方を選ぶ。
本文の書き方（GFM + callout / details / 数式 / `asset:` / `entry:` の方言の要約）は `create_entry` / `update_entry` の description に載っている（エージェントはそれを読んで書く）。
説明（description）は仕様として扱う: `publish` の前に `publish_check` と `impact(id, PUBLISH)` と `diff_entry` を、`unpublish` の前に `impact(id, UNPUBLISH)` を、`delete_entry` の前に `impact(id, DELETE)` を呼ぶ。
`tools/list` は主体が呼べる物に絞らない（全部出す。呼べなければ `FORBIDDEN` が返る。`whoami` で先に確かめられる）。

業務エラー（FORBIDDEN / NOT_FOUND / CONFLICT / INVALID …）は全部 `tools/call` の result に `isError: true` で、`content[0].text` に
[error-codes.md](../docs/design/error-codes.md) の `extensions`（code / message / violations / entity / id / expectedVersion / actualVersion）がそのまま JSON で入る。
protocol error は JSON-RPC の -32700 / -32600 / -32601 / -32602 だけ。壊れたログインの JWT と死んだ PAT は `/mcp` では HTTP 401（`WWW-Authenticate: Bearer error="invalid_token"`。
GraphQL の経路（`/admin/graphql` など）では 200 で `errors[].extensions.code` が `UNAUTHENTICATED`。どちらもログは warn）、
Origin ヘッダが付いていて `CMS_CORS_ORIGINS` に無ければ 403（無ければ通す。CLI は Origin を付けない）、プレビュートークンは 400。
`content[0].text` が 256 KB を超えたら本文だけ切って `structuredContent.truncated: true` が付く。
`tools/call` はリクエストの行（`{"message":"request","url.path":"/mcp","mcp.tool":…,"mcp.outcome":"ok","id":…,"credential.kind":"api-key","duration_ms":…,"request.id":…}`）に乗ってログに出る（1 リクエスト 1 行。`mcp.outcome` が `error` なら `error.code` も）。引数は残さない（キーは [docs/logging.md](../docs/logging.md)）。

## CDN に乗せる（GET）

コンテンツ API は `GET /graphql?query=...&variables=...` でも読める（mutation は 405）。鍵もプレビュートークンも無い問い合わせで errors が無ければ
`Cache-Control: public, max-age=60, s-maxage=60, stale-while-revalidate=60`（秒数は `CMS_CACHE_MAX_AGE`）が付くので、Cloudflare などの CDN がそのまま溜める。
鍵やトークン付きの応答は `private, no-store` で、共有キャッシュには入らない。公開サイトのビルドや SWR の fetch は GET を使い、書く操作と下書きは POST を使う。

## 予約公開とバックグラウンドワーカー

予約公開（`schedulePublish` / `scheduleUnpublish`）と Webhook の配信は、業務の Tx と同じ DB に仕事の行を積み（outbox）、
プロセス内のバックグラウンドワーカーが 2 秒ごとに拾って実行する。拾う SQL は `FOR UPDATE SKIP LOCKED` なので、複数台で動かしても同じ仕事は 1 台にしか渡らない。
実行中にプロセスが落ちた仕事は 10 分後に拾い直す（公開は冪等。Webhook は受け手が `X-Cms-Delivery` で重複を捨てる）。終わった記録は 30 日で消す。

`/health` の `jobs` にワーカーの最終実行時刻（`lastTickAt`）と、待ち・失敗の件数（`pendingSchedules` / `failedSchedules` / `pendingDeliveries` / `failedDeliveries`。数えられなければ -1）が出る。
`lastTickAt` が 30 秒より古ければ `/health` 自身が 503 と `"reason": "jobs stalled"` を返す（`CMS_JOBS=off` の時は見ない）。`failedDeliveries` が増えていれば受け手が落ちている。仕事 1 件ごとに `{"message":"job delivered","job.kind":"webhook","job.id":...,"job.outcome":"delivered","detail":"HTTP 200",...}` の 1 行 JSON もログに出る（`job.id` は `X-Cms-Delivery` と同じ）。

SIGTERM / SIGINT を受けると次の順で止まる（下の「停止と終了コード」）。

保険として、外の cron から同じ処理を呼べる（`CMS_JOBS_TOKEN` を設定した時だけ）。同時に呼ばれても二重にはならない。

```bash
# systemd timer / cron から 1 分ごと
curl -fsS -X POST -H "X-Jobs-Token: $CMS_JOBS_TOKEN" http://127.0.0.1:8080/jobs/tick
```

Cloudflare Cron Triggers なら Worker から同じ POST を送る。`CMS_JOBS=off` にすればプロセス内のワーカーは回らず、外部トリガー（か同じイメージを別に立てた worker）だけで回せる。

デプロイ時の注意: migration は列を足す変更に留める（旧版が動いている間に列を消さない）。別プロセスの worker を立てる時は、アプリを先に上げて migration を当ててから worker を上げる。

## Webhook の受け方

公開・取り下げ・削除・型の変更で、登録した URL に JSON を POST する（管理 API の `createWebhook`。secret はその応答でしか見えない）。

```
POST <url>
Content-Type: application/json
X-Cms-Event: entry.published            # entry.unpublished / entry.deleted / schema.changed
X-Cms-Delivery: 01J...                  # 配信の id（再送でも同じ）。重複の見分けに使う
X-Cms-Timestamp: 1725700000             # UNIX 秒
X-Cms-Signature: sha256=<hex>           # HMAC-SHA256(secret, "<timestamp>.<body>")

{"event":"entry.published","project":"default","entry":{"id":"e1","type":"blogs"}}
```

受け手は同じ計算で署名を照合し、timestamp が古すぎれば捨てる。照合の見本は `scripts/webhook-receiver.py`（`python3 scripts/webhook-receiver.py secret.txt received.log` で 127.0.0.1:9999 に立つ）。中身は入っていないので、必要ならコンテンツ API で読む。
2xx 以外なら 1 分 → 5 分 → 30 分 → 2 時間の後に送り直し、5 回目で失敗になる（管理 API の `webhookDeliveries` で見え、`redeliverWebhook` で送り直せる）。
本文の `at` は積んだ時刻（ISO 8601）。同じ Webhook 宛の配信は積んだ順に 1 件ずつ送る（前の物が再試行待ちなら次も待つ）ので、受け手には順に届く。届いた順を信じない受け手は `at` か `X-Cms-Delivery`（ULID。時刻順）で並べ直せる。

## 更新

```bash
docker compose pull && docker compose up -d
```

新しいイメージが未適用の migration を持っていれば、起動時に advisory lock を取って順に当てる。2 台以上が同時に上がっても 1 台だけが当て、他は待ってから起動する。適用済みのファイルが書き換わっていれば起動しない（`checksum` の不一致）。

## バックアップ

`backup` サービスが毎晩 `pg_dump` を `./backups/` に置き、7 日分残す。外へ逃がすなら rclone で R2 へ同期する。

```bash
rclone sync ./backups r2:cms-backups   # cron で毎晩
```

戻す時:

```bash
gunzip -c backups/cms-20260907-0300.sql.gz | docker compose exec -T postgres psql -U cms cms
```

## ログと監視

cms のログは 1 行 1 JSON。`docker compose logs -f cms` で見られる。`time` / `severity` / `message` の 3 つに、OpenTelemetry の名前の属性が付く（キーの一覧は [docs/logging.md](../docs/logging.md)）。

```json
{"time":"2026-09-07T12:00:00.123Z","severity":"info","message":"request","service":"cms","version":"a1b2c3d","request.id":"01J7X0Q3M5N8R9S1T2V4W6Y8Z0","http.request.method":"POST","url.path":"/admin/graphql","http.response.status_code":200,"duration_ms":12,"project":"blog","credential.kind":"api-key"}
```

`CMS_LOG_LEVEL`（既定 `info`）を `debug` にすると `/health` の行も出る（外形監視の分で溢れるので普段は出さない）。
compose の `logging` は `json-file` の `non-blocking`。docker daemon が詰まってもリクエストは止まらない（代わりにバッファ 4m を超えた行は落ちる）。

### request id

- リクエストの `X-Request-Id` をそのまま使う（無ければ cms が ULID で作る）
- 応答ヘッダ `X-Request-Id` で返る
- 500 系の GraphQL のエラーは `errors[].extensions.requestId` に同じ値が入る
- 問い合わせにはこの値を添える。`{service="cms"} | json | request_id="01J..."` で 1 リクエストの行が全部引ける

Grafana Cloud（無料枠）へ送るなら `.env` に `GRAFANA_*` を入れて `docker compose --profile alloy up -d`。ラベルは `service` だけ（`| json` で属性を引く。属性をラベルにするとストリームが増えて無料枠の上限に当たる）。外形監視は Better Stack や UptimeRobot で `/health` を叩く。

### アラートの例（LogQL）

```logql
# 5 分で severity=error が 3 行を超えた
sum(count_over_time({service="cms"} | json | severity="error" [5m])) > 3

# 5xx の率が 1 % を超えた
sum(rate({service="cms"} | json | message="request" | http_response_status_code >= 500 [5m]))
  / sum(rate({service="cms"} | json | message="request" [5m])) > 0.01

# JSON でない行（OOM のスタックトレースや JVM の平文はこれで拾う）
sum(count_over_time({service="cms"} | json | __error__ != "" [5m])) > 0
```

4 本目は Loki でなく外形監視: `/health` が 503 と `"reason": "jobs stalled"` / `"watch stalled"` を返していればワーカーか見張りが止まっている（Better Stack や UptimeRobot が status で拾う）。

`/health` の `connections` は `{"active": 今つないでいる数, "max": CMS_MAX_CONNECTIONS}`。active が max に張り付いていれば 503 が出ている。

### DB の接続プール

`/health` の `pool` は DB の接続プールの数字（HTTP の `connections` とは別）で、`{"active": 借りている数, "idle": 空き, "waiting": 借りるのを待っているスレッド, "total": 開いている接続, "max": 上限}`。
`waiting` が 0 より大きい状態が続けば枯渇していて、`active` が `max` に張り付いたまま `waiting` も減らないなら接続が返っていない（漏れ）。
リクエストの行にも、待ちが出ている時だけ `db.pool.waiting` / `db.pool.active` が付く。

DB の失敗の行（`message: "field failed"`）には `error.kind` が付く。`deadlock` はロックの競合。接続を借りる段の失敗は sqlfx 0.3.1 が
その時の `pool` の数字と例外の cause で 2 つに分ける。

- `connectionLost` … **DB に届いていない**（停止・DSN・ネットワーク）。プールは空いているのに接続が作れなかった時、または cause に `java.net.ConnectException` / `java.net.SocketTimeoutException` / SQLState が `08` で始まる `PSQLException` がある時
- `timeout` … **借り待ちの上限**。プールが満杯（`active >= max`）で空きを待ち切った。DB は生きている見込みで、遅い SQL か接続の漏れを疑う。SQL の実行中の `statement_timeout` も同じ `timeout`

`connectionLost` は `/health` の `pool.total` が 0 に落ちる形と、`timeout` は `pool.waiting` が伸びる形と揃う。
一時的な失敗で呼び直した時は、リクエストの行に `db.retries`（1〜2）が付く。

`CMS_DB_LEAK_DETECTION_SECONDS` を入れると HikariCP が「借りたまま返らない接続」を見張るが、**警告の行は出ない**（cms は HikariCP の SLF4J を `slf4j-nop` で黙らせている。出すと Flix のテストが標準エラーで落ちるため）。
気付き方は `/health` の `pool.active` が張り付く事の方で、しきい値の設定は将来 SLF4J の束縛を差し替えた時のために置いてある。

### 停止と終了コード

SIGTERM / SIGINT を受けると、この順で止まる。

1. `shutting down` の行を出す
2. listen（待ち受けのソケット）を閉じる。新しい接続はここで受けなくなる（前段は他の台へ回す）
3. 処理中の接続が全部閉じるのを待つ（最長 `CMS_SHUTDOWN_TIMEOUT_SECONDS`。既定 20 秒）
4. 新しい仕事を拾うのをやめ、実行中の 1 周が終わるのを同じ期限まで待って `jobs drained`
5. 全部間に合えば**終了コード 0**。どれかが間に合わなければ warn の `shutdown timed out`（`shutdown.connections` / `shutdown.in_tick` に何が残ったか）を出して**終了コード 2**

| 終了コード | 意味 |
|---|---|
| 0 | 綺麗に停止した（接続も仕事も片付いた） |
| 1 | 起動に失敗した（`startup failed`） |
| 2 | 停止の drain が間に合わなかった（`shutdown timed out`） |
| 3 | 壊れて落ちた。自己回復（`self-heal: exiting`。下）、main スレッドが致命的な例外で死んだ（`main thread died`）、`-XX:+ExitOnOutOfMemoryError` の JVM が OutOfMemoryError で落ちた（`Terminating due to java.lang.OutOfMemoryError`）の 3 通り |

DB が止まっている最中の停止は、tick が DB 待ちで詰まって期限に間に合わず **2 になり得る**（`shutdown.in_tick: true`）。
「綺麗に止まれなかった」事実なのでこれで正しい。0 で止めたいなら `stop_grace_period` を `CMS_DB_TIMEOUT_SECONDS` より長くする。

compose の `stop_grace_period` は `CMS_SHUTDOWN_TIMEOUT_SECONDS` より長くする（既定なら 30s 以上）。短いと Docker が SIGKILL を送り、drain の途中で切れる。

keep-alive の idle の接続も枠を占めるので、前段（Caddy）が接続を使い回している時は 3 で最長 15 秒（`idleTimeoutMs`）残りうる。
`CMS_SHUTDOWN_TIMEOUT_SECONDS` はそれより長くしておく。

### 自己回復（自分で終わって再起動させる）

OOM のような事故の後、プロセスは生きているのに接続プールだけが壊れ、PostgreSQL が健在でも `/health` が 503 を返し続ける事がある（実験 1 回目の S5。2 分観測して戻らなかった）。
プールを作り直す口が無いので、cms は**自分で終わって、コンテナに起こし直させる**。見張りは仕事の周とは別のスレッドで 2 秒ごとに回り（仕事の周が DB 待ちで伸びても粒度は変わらない）、
**`/health` を叩かれた時にも同じ判断が 1 回進む**（見張りのスレッドが OOM で死んでも、リクエストのスレッドは生きているので評価が止まらない）。次の 4 つがそろった時だけ終わる。

1. 起動から `CMS_SELF_HEAL_WARMUP_SECONDS`（既定 300 秒）経っている（起動直後の DB 待ちで落ちない）
2. プール経由の ping が `CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS`（既定 90 秒）以上続けて失敗している
3. その間に、**プールを通さない新しい接続**では DB に届いた（DB 自体が落ちている時は終わらない。終わっても直らないため）
4. プロセスごとの jitter（0 秒から `CMS_SELF_HEAL_JITTER_SECONDS`。既定 10 秒）も過ぎている（複数台が同じ時刻に落ちない）

終わる時は `{"severity":"error","message":"self-heal: exiting","reason":...,"db.pool.active":...}` を出し、停止（SIGTERM）と同じ drain をしてから**終了コード 3**。
compose の `restart: unless-stopped` が起こし直す。`CMS_SELF_HEAL=off` で止められる。

OOM で JVM 自身が落ちる時（`-XX:+ExitOnOutOfMemoryError`）の最後の行 `Terminating due to java.lang.OutOfMemoryError` は **JSON ではない**（JVM が出す物で、アプリ側では塞げない）。
その時の終了コードは **3**（OpenJDK 23.0.1 で実測。この旗を付けないと `Exception in thread "main"` で 1 になる）。
収集器は終了コード 3 と、その直前の行で判断する（LogQL なら `__error__ != ""` で拾う）。

旗を付けない環境（手元で jar を直に起動する時など）でも main スレッドが死んだ時に 1 にならないよう、cms は `listen` を Throwable で受け、
`{"severity":"fatal","message":"main thread died","exception.type":...}` を出して 3 で終わる。drain はしない（JVM が壊れている時で、DB の呼び出しも同じ理由で詰まるため）。

見張りのスレッド自体が止まった時は、`/health` が 503 と `"reason": "watch stalled"` を返す（最後に回ってから 30 秒より古い時）。
リクエストの行には `jobs.stalled_ms` / `watch.stalled_ms` が付く。

**`/health` は DB が落ちている時に `CMS_DB_BORROW_TIMEOUT_SECONDS` ぶん（既定 2 秒）＋ プールを通さない接続を 1 本試すぶんだけ返らない。**
ping は 1 回だけ打ち、その結果を自己回復の判断と応答の両方で使う（2 回打っていた頃は倍の 10 秒級だった）。
接続を借りる所で待つので、ping の前に `SET LOCAL statement_timeout` を置いても効かない。もっと短くしたいなら `CMS_DB_BORROW_TIMEOUT_SECONDS=1` にする。
Dockerfile の `HEALTHCHECK --timeout=3s` には収まらない事があるので、余裕を見るなら `--timeout` を伸ばす。

予約公開と再起動: プロセスが落ちた時に実行中だった仕事は失われないが、`claimed_at` の回復で拾い直すのは 10 分後になる（その分だけ公開が遅れる）。

## keep-alive と同時接続

cms は HTTP/1.1 の keep-alive を受ける（1 接続で 100 リクエストまで、次のリクエストを 15 秒待つ）。Caddy は cms との接続を使い回すので、Caddy と cms の間は張り直しの往復が消える。
同時接続の上限（`CMS_MAX_CONNECTIONS`）は Caddy から見た接続数で、keep-alive の接続は idle の間も枠を占める。Caddy の `reverse_proxy` に `transport http { keepalive_idle_conns N }` を書くなら N は上限より小さくする。

## クラウド版（R2）にする時

compose の `minio` / `minio-init` を消し、`ASSET_*` を R2 の値にする。

```
ASSET_ENDPOINT=https://<accountId>.r2.cloudflarestorage.com
ASSET_BUCKET=cms
ASSET_ACCESS_KEY=...
ASSET_SECRET_KEY=...
ASSET_REGION=auto
ASSET_PUBLIC_URL=https://assets.example.com
```

## 環境変数

| 名前 | 意味 | 既定 |
|---|---|---|
| `CMS_DSN` / `CMS_DB_USER` / `CMS_DB_PASSWORD` | PostgreSQL。表の所有者（migration に使う） | 必須 / cms / cms |
| `CMS_DB_APP_USER` / `CMS_DB_APP_PASSWORD` | リクエストに使うロール。起動時に所有者が作り、表の読み書きだけ許す（RLS が効く）。PASSWORD が無ければ所有者で繋ぐ | cms_app / 無し |
| `CMS_DB_TIMEOUT_SECONDS` | 接続ごとに DB 側で効かせる時間の上限（秒）。`idle_in_transaction_session_timeout` / `statement_timeout` / `lock_timeout` を同じ値にする（pgjdbc の `options` で接続時に付ける）。アプリの不具合で Tx が開いたままでも DB 側が切る。0 で無効。`CMS_DSN` に `options=` を書いた時はそちらが優先 | 30 |
| `CMS_DB_LEAK_DETECTION_SECONDS` | 借りたまま返らない接続を HikariCP が見張るまでの秒数。0 で無効。警告の行は出ない（`slf4j-nop`。上の「DB の接続プール」） | 0 |
| `CMS_DB_MAX_CONNECTIONS` | 接続プールが同時に開く接続の上限。PostgreSQL の `max_connections` を台数で割った数より小さくする | 10 |
| `CMS_DB_BORROW_TIMEOUT_SECONDS` | 接続を借りるのを待つ上限。DbRunner が 3 回まで再試行するので、1 リクエストの最悪はこの 3 倍 + backoff（0〜0.6 秒） | 2 |
| `CMS_MIGRATE` | `apply`（起動時に当てる）か `check`（未適用なら起動しない） | イメージは apply、手元は check |
| `CMS_CORS_ORIGINS` | 許すオリジン（カンマ区切り） | 無し |
| `CMS_VERSION` | `/health` に出す版 | イメージのビルド時に git の sha |
| `ASSET_ENDPOINT` ほか | asset の置き先。無ければ asset の機能だけ使えない | 無し |
| `CMS_AUTH` | `jwks`（発行元の JWT を検証）/ `dev`（`X-Dev-User` を信じる。`CMS_VERSION=dev` の時だけ）/ `none`（管理 API を閉じる） | none |
| `CMS_AUTH_ISSUER` / `CMS_AUTH_JWKS_URL` / `CMS_AUTH_AUDIENCE` | jwks の時に必須。Cloudflare Access なら `https://<team>.cloudflareaccess.com`、`.../cdn-cgi/access/certs`、アプリの AUD | 無し |
| `CMS_AUTH_HEADER` | JWT のヘッダ名。Clerk 等は `Authorization` | Cf-Access-Jwt-Assertion |
| `CMS_BOOTSTRAP_OWNER` | 最初の owner の email。その初回ログインを既定の組織の owner にする | 無し |
| `CMS_DEFAULT_PROJECT` | プロジェクト slug 無しの `/graphql` / `/admin/graphql` が向くプロジェクト slug。空にするとプロジェクト slug 無しは 404（クラウド版） | default |
| `CMS_SIGNUP` | `open`（ログインした人は誰でも組織を作れる）/ `closed`（既定の組織の owner だけ） | open |
| `CMS_JOBS` | `on` ならプロセス内のバックグラウンドワーカー（予約公開と Webhook の配信）を回す。`off` は外部トリガーか別の worker で回す時 | on |
| `CMS_JOBS_TOKEN` | `POST /jobs/tick`（外部トリガー）を許す `X-Jobs-Token` の値。無ければその口は閉じる | 無し |
| `CMS_JOBS_DRAIN_SECONDS` | 自己回復（exit 3）で実行中の仕事を待つ秒数 | 15 |
| `CMS_SHUTDOWN_TIMEOUT_SECONDS` | SIGTERM で HTTP の接続と実行中の仕事を待つ秒数。超えたら `shutdown timed out` と終了コード 2。compose の `stop_grace_period` はこれより長くする | 20 |
| `CMS_SELF_HEAL` | `on` / `off`。接続プールが壊れたまま戻らない時に自分で終わって再起動させる（下の「自己回復」） | on |
| `CMS_SELF_HEAL_MIN_UNHEALTHY_SECONDS` | プール経由で DB に届かない状態がこれだけ続いたら終わる | 90 |
| `CMS_SELF_HEAL_WARMUP_SECONDS` | 起動からこれだけは自己回復を見送る（起動直後の DB 待ちで落ちないため） | 300 |
| `CMS_SELF_HEAL_JITTER_SECONDS` | 終わる時刻をプロセスごとにずらす上乗せの上限（0 秒からこの値の間で 1 回引く） | 10 |
| `CMS_CACHE_MAX_AGE` | コンテンツ API の GET で、鍵もトークンも無い応答に付ける `Cache-Control` の秒数（CDN 用）。0 で no-store | 60 |
| `CMS_MAX_CONNECTIONS` | HTTP の同時接続の上限。超えた接続は `503` と `Retry-After: 1` で断る（待ち行列は無い）。今の数は `/health` の `connections` | 256 |
| `CMS_LOG_LEVEL` | ログの最低 severity（`debug` / `info` / `warn` / `error`）。`debug` で `/health` の行も出る | info |
| `CMS_BASE_DOMAIN` | `{プロジェクト slug}.{base}` の Host でプロジェクトを選ぶ。無ければ `/p/{プロジェクト slug}/` だけ | 無し |
| `CMS_API_KEY_PEPPER` / `CMS_API_KEY_PEPPER_ID` | API キーと PAT のハッシュ、プレビュートークンの署名に混ぜる秘密と版。無ければ鍵と PAT を発行できない | 無し / v1 |
| `JAVA_OPTS` | JVM の引数。`ExitOnOutOfMemoryError` は OutOfMemoryError で（スレッド 1 本でなく）プロセスごと落として docker に再起動させる | `-Xss32m -XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError` |
