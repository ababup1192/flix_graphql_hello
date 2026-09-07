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

## CDN に乗せる（GET）

コンテンツ API は `GET /graphql?query=...&variables=...` でも読める（mutation は 405）。鍵もプレビュートークンも無い問い合わせで errors が無ければ
`Cache-Control: public, max-age=60, s-maxage=60, stale-while-revalidate=60`（秒数は `CMS_CACHE_MAX_AGE`）が付くので、Cloudflare などの CDN がそのまま溜める。
鍵やトークン付きの応答は `private, no-store` で、共有キャッシュには入らない。公開サイトのビルドや SWR の fetch は GET を使い、書く操作と下書きは POST を使う。

## 予約公開とバックグラウンドワーカー

予約公開（`schedulePublish` / `scheduleUnpublish`）と Webhook の配信は、業務の Tx と同じ DB に仕事の行を積み（outbox）、
プロセス内のバックグラウンドワーカーが 2 秒ごとに拾って実行する。拾う SQL は `FOR UPDATE SKIP LOCKED` なので、複数台で動かしても同じ仕事は 1 台にしか渡らない。
実行中にプロセスが落ちた仕事は 10 分後に拾い直す（公開は冪等。Webhook は受け手が `X-Cms-Delivery` で重複を捨てる）。終わった記録は 30 日で消す。

`/health` の `jobs` にワーカーの最終実行時刻（`lastTickAt`）と、待ち・失敗の件数（`pendingSchedules` / `failedSchedules` / `pendingDeliveries` / `failedDeliveries`。数えられなければ -1）が出る。
外形監視で `lastTickAt` が古ければワーカーが止まっている。`failedDeliveries` が増えていれば受け手が落ちている。仕事 1 件ごとに `{"job":"webhook","id":...,"status":"delivered",...}` の 1 行 JSON もログに出る。

SIGTERM / SIGINT を受けると、新しい仕事を拾うのをやめ、実行中の 1 周が終わるまで（最長 `CMS_JOBS_DRAIN_SECONDS`。既定 15 秒）待ってから終わる。compose の `stop_grace_period` はそれより長くする。

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

cms のログは 1 行 1 JSON。`docker compose logs -f cms` で見られる。

```json
{"time":"2026-09-07T12:00:00.123Z","method":"POST","path":"/graphql","status":200,"ms":12}
```

Grafana Cloud（無料枠）へ送るなら `.env` に `GRAFANA_*` を入れて `docker compose --profile alloy up -d`。外形監視は Better Stack や UptimeRobot で `/health` を叩く。

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
| `CMS_JOBS_DRAIN_SECONDS` | 停止時に実行中の仕事を待つ秒数 | 15 |
| `CMS_CACHE_MAX_AGE` | コンテンツ API の GET で、鍵もトークンも無い応答に付ける `Cache-Control` の秒数（CDN 用）。0 で no-store | 60 |
| `CMS_BASE_DOMAIN` | `{プロジェクト slug}.{base}` の Host でプロジェクトを選ぶ。無ければ `/p/{プロジェクト slug}/` だけ | 無し |
| `CMS_API_KEY_PEPPER` / `CMS_API_KEY_PEPPER_ID` | API キーと PAT のハッシュ、プレビュートークンの署名に混ぜる秘密と版。無ければ鍵と PAT を発行できない | 無し / v1 |
| `JAVA_OPTS` | JVM の引数 | `-Xss32m -XX:MaxRAMPercentage=70` |
