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
| `CMS_BASE_DOMAIN` | `{プロジェクト slug}.{base}` の Host でプロジェクトを選ぶ。無ければ `/p/{プロジェクト slug}/` だけ | 無し |
| `CMS_API_KEY_PEPPER` / `CMS_API_KEY_PEPPER_ID` | 公開 API の鍵のハッシュに混ぜる秘密と版。無ければ鍵を発行できない | 無し / v1 |
| `JAVA_OPTS` | JVM の引数 | `-Xss32m -XX:MaxRAMPercentage=70` |
