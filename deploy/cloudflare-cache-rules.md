# Cloudflare の Cache Rules（コンテンツ API の GET を CDN に乗せる）

cms は匿名の `GET /graphql`（と `/p/{プロジェクト slug}/graphql`）に `Cache-Control: public, s-maxage=…` と weak な `ETag` を付ける
（決めた事は [docs/design/cdn.md](../docs/design/cdn.md)）。Cloudflare は既定では API の応答（`application/json`）をキャッシュしないので、
Cache Rules で 1 つ作る。ダッシュボードの Caching → Cache Rules → Create rule。

## 1. cache eligible にする rule

- **When incoming requests match**（Custom filter expression）:

```
(http.host eq "cms.example.com")
and (http.request.method eq "GET")
and (starts_with(http.request.uri.path, "/graphql") or http.request.uri.path matches "^/p/[a-z0-9-]+/graphql$")
and not any(lower(http.request.headers.names[*])[*] in {"x-api-key" "x-preview-token" "authorization"})
```

- **Cache eligibility**: Eligible for cache
- **Edge TTL**: Use cache-control header if present, bypass cache if not（cms の `s-maxage` に従う。errors のある応答は `no-store` なので溜まらない）
- **Browser TTL**: Respect origin（`max-age`。既定 0）
- **Cache key**: Query string は **All query string parameters**（`?query=…&variables=…` が鍵。既定の設定でも全部入るが明示しておく）
- **Serve stale content while revalidating**: on（`stale-while-revalidate=60` を効かせる）

鍵やトークンのヘッダが付いた要求を式で外すのは、Cloudflare が `Vary` をキャッシュの鍵に使わない（画像以外）ため。
cms はそれらの応答に `private, no-store` を付けるので溜まりはしないが、式で外さないと**匿名の応答が鍵付きの要求に返る**。
cms の `Vary: X-Api-Key, X-Preview-Token, Authorization` はそのまま出しておく（Vary を尊重する CDN や Caddy のキャッシュ向け）。

## 2. 条件付き要求（304）

Cloudflare は origin に `If-None-Match` を付けて再検証し、cms が 304 を返せば本文無しで済む（SQL は版の 1 本）。
ブラウザには `max-age=0` なので毎回 CDN に来るが、CDN が `s-maxage` の間は origin に来ない。

## 3. purge（任意）

`CMS_CDN_PURGE_URL=https://api.cloudflare.com/client/v4/zones/<zone id>/purge_cache` と `CMS_CDN_PURGE_TOKEN=<Cache Purge の権限の API トークン>` を
両方入れると、公開・取り下げ・削除・型の変更で版が進んだプロジェクトの `purge_everything` をバックグラウンドの tick が送る（最長 2 秒後。失敗は Webhook と同じ間隔で再試行）。
zone 全体を消すので、同じ zone に置いた画像（`assets.example.com`）のキャッシュも一緒に外れる。画像は `immutable` で長く持たせているので実害は再取得の 1 回。
入れなくても ETag で「次に読まれた時」には新しくなる（`s-maxage` の間は古い物が返る）。

## 4. 確かめ方

```bash
# 1 回目は MISS、2 回目は HIT。ETag は W/"v<版>-<hash>"
curl -sI 'https://cms.example.com/graphql?query=%7B%20blogs%20%7B%20nodes%20%7B%20id%20%7D%20%7D%20%7D' | grep -iE 'cf-cache-status|etag|cache-control'
# 版が進んだら ETag が変わる（publish の後）
```
