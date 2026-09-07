# 設計: 読み取りだけの REST（優先度は低い）

状態: 計画のみ（2026-09-07）。サービス化の段（管理画面の後）に入れる。書き込みの REST は作らない。

## なぜ読み取りだけか

- 公開サイト側に「GraphQL を書きたくない」層がいる。SSG の content loader、ノーコードツール、Zapier、curl で試す人。
  microCMS からの乗り換え先を探す人の一部はここにいるので、「REST あります」の 1 行が要る
- 書き込みを 2 経路にすると、権限とバリデーションの検査を 2 回持つ事になる。管理画面と移行ツールは GraphQL で足りる
- 絞り込みを REST 独自の構文（microCMS の `filters=title[contains]x[or]...`）にしない。それは捨てると決めた負債

## 形

GraphQL の `where` / `orderBy` をそのまま URL に載せる。内部では GraphQL のクエリを組み立てて同じエンジンで実行するので、
型・絞り込み・参照の展開は GraphQL と 1 つ。

```
GET /p/{slug}/rest/{plural}?first=10&skip=0&orderBy=publishedAt_DESC&where={"category_eq":"NEWS"}&fields=title,body.html,cover.url
GET /p/{slug}/rest/{plural}/{id}?fields=...
GET /p/{slug}/rest/{singularApiId}            # SINGLETON
```

- `where` は GraphQL の `Where` 入力の JSON を URL エンコードした物。GET なので本文は使わない
- `fields` は返す物の指定（GraphQL の selection に写す）。省けば scalar の全フィールドと、参照・asset・richText は id / url / html だけ
- `stage=DRAFT` は preview トークン付きの時だけ
- 応答は GraphQL の `nodes` / `totalCount` と同じ JSON。エラーは `{ "errors": [...] }` で GraphQL と同じ形
- `Cache-Control: public, max-age=60` を付け、Cloudflare にそのまま乗せる。`ETag` は entry の updatedAt から

## 一緒に出す物

- **OpenAPI 3.1 の自動生成**: `/p/{slug}/rest/openapi.json`。型ごとの schema はコンテンツ API の Schema から写す（ContentSchemaBuilder に
  「型 → JSON Schema」の写しを 1 つ足す）。「API 仕様書を見せて」に応える
- `GET /graphql?query=...`（GraphQL over HTTP の GET。CDN キャッシュ用）はこれより先に、1 時間で入れる

## 実装の置き場

- `src/app/Rest.flix`: パスとクエリ文字列 → GraphQL のクエリ文字列（純粋。テストは文字列の比較）
- `Server` の分岐に `("GET", "/rest/...")` を足し、組んだクエリを `Graphql.execute` に渡す
- OpenAPI は `src/content/OpenApi.flix`（Schema → JSON）

見積もり: REST 半日、OpenAPI 1 時間。

## やらない事

- 書き込み（POST / PUT / DELETE）
- microCMS 互換の URL や `filters` 構文
- ページネーションの cursor（`first` / `skip` のみ。GraphQL と揃える）
