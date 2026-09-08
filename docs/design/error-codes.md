# エラーの分類（`errors[].extensions`）

管理 API・Account API・コンテンツ API のどれでも、失敗は GraphQL 仕様どおり `errors[]` で返る。
`message` は**人が読む日本語**なので、クライアント（自作クライアント・CLI・MCP）は
`extensions` を見て分岐する。**`message` の文字列で分岐しない。**

```json
{
  "data": null,
  "errors": [
    {
      "message": "entry 'e_7f3a' が見つかりません",
      "path": ["deleteEntry"],
      "locations": [{ "line": 1, "column": 12 }],
      "extensions": {
        "code": "NOT_FOUND",
        "entity": "Entry",
        "id": "e_7f3a"
      }
    }
  ]
}
```

## `extensions.code`

`code` は必ず入る。値は API の一部で、綴りは変えない（足す事はある）。

| code | いつ | クライアントの出方 |
|---|---|---|
| `INVALID` | 入力が規則に合わない（名前の重複、required 漏れ、値の形） | `violations` を入力欄の横に出す。直せば通る |
| `NOT_FOUND` | 指した物が無い（消された、他のプロジェクトの id） | 一覧を読み直す |
| `FORBIDDEN` | 主体に権限が無い（viewer が型を作る等） | 操作を出さない。役割を上げてもらう |
| `CONFLICT` | 楽観ロックに負けた（読んでから書くまでに他で更新された） | 読み直して差分を見せ、もう一度保存させる |
| `REQUIRES_LOGIN` | 主体の種類が合わない（read の PAT で書く、API キーで Account API を使う） | ログインし直す。書く操作には write の PAT かログインの JWT が要る |
| `UNAUTHENTICATED` | 身元の検証に失敗した（壊れたログインの JWT、期限切れ・失効した PAT、知らない PAT） | 再ログイン。トークンを取り直す |
| `INTERNAL` | 上のどれでもない（DB の失敗、サーバの設定漏れ） | 再試行してよい。直らなければ運用へ |

**再試行してよいのは `INTERNAL` だけ。** 他は同じリクエストを送っても同じ結果になる。

## 分類ごとの追加

`code` 以外は、分かる時だけ入る。無い事もある前提で読む。

### `INVALID` — `violations`

```json
"extensions": {
  "code": "INVALID",
  "violations": [
    { "field": "apiId", "message": "'blogs' は既にあります" },
    { "field": "fields.title", "message": "必須です" }
  ]
}
```

`field` は GraphQL の入力の位置（`apiId`、`fields.title` のように `.` でつなぐ）。
`message` はその 1 件の日本語。`errors[].message` は全部の `violations` を `; ` でつないだ物なので、
欄ごとに出すなら `violations` を使う。

引数そのものが型に合わない場合（`expectedVersion` に文字列を渡した等）も `INVALID` になるが、
`violations` は付かない事がある（`message` に位置と期待する型が入る）。

### `NOT_FOUND` — `entity` と `id`

```json
"extensions": { "code": "NOT_FOUND", "entity": "Entry", "id": "e_7f3a" }
```

`entity` は `ContentType` / `Field` / `Entry` / `Version` / `Asset` / `Member` / `Invitation` /
`ApiKey` / `PersonalAccessToken` / `Organization` / `Webhook` / `WebhookDelivery` / `Schedule`。
`id` はリクエストが指した値。

### `CONFLICT` — `entity` / `id` と版

```json
"extensions": {
  "code": "CONFLICT", "entity": "Entry", "id": "e_7f3a",
  "expectedVersion": 3, "actualVersion": 5
}
```

`expectedVersion` は送った `expectedVersion`、`actualVersion` は今サーバにある版。
差が 1 なら誰かの 1 回の保存に負けただけなので、読み直してもう一度出せば済む事が多い。

### `FORBIDDEN` / `REQUIRES_LOGIN` / `UNAUTHENTICATED`

`code` だけ。どの権限が要るかは `message` にある（機械が読む必要がある物ではない）。

### `INTERNAL`

`code` と `requestId`（応答ヘッダ `X-Request-Id` と同じ。ログの `request.id`）。問い合わせに添えれば、その時のログの行に辿り着く。
他の分類には付けない（クライアントが自分で直せる物で、ヘッダで足りる）。

## 部分的な失敗

GraphQL なので、1 リクエストの一部のフィールドだけが失敗する事がある。
そのときは `data` に読めた分が入り、失敗したフィールドは `null`、`errors[]` にその 1 件が入る。
`errors[].path` がどのフィールドかを指す。**`errors` が空かどうかだけを見て成功と判断しない。**

## HTTP のステータス

GraphQL の実行まで届けば **200** で、失敗は `errors[]` に入る（`extensions.code` があるのはこの形だけ）。
ボディが壊れている・`query` が無い・GET で mutation を送った、のようにリクエストの形が違う場合だけ
400 / 405 で、その本文は `errors[].message` だけを持つ（`extensions` は無い）。

## 実装

分類を決めるのは `src/app/GraphqlErrors.flix` の 1 か所だけで、
`DbRunner.toFieldResult` を通る全部の入口（管理 API・Account API・コンテンツ API、これから足す MCP）が同じ形になる。
`extensions` を GraphQL のエラーに載せるのは `src/graphql/Graphql.flix` の `toErrorResult`。
