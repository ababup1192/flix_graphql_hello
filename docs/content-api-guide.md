# コンテンツ API ガイド（サイトを組む人向け）

読者: GraphQL は触った事があり、この CMS は初めて、という制作会社のエンジニア（Next.js / Astro / Nuxt でブログを組む人）。
この文書の例は全部、開発サーバ（`http://127.0.0.1:8080`）のプロジェクト `demo` と `fresh-blog` で実際に叩いて返った物です。
本番では host とプロジェクト slug を自分の物に読み替えてください。

この文書で「型」と書いたら content type（`blogs` のような、管理画面の「API スキーマ」で作る物）の事です。
「entry」はその型の 1 件、「asset」は画像やファイルです。

各章は「まず動く例 → 説明 → 落とし穴」の順です。

---

## 1. 最初の 1 回

```bash
curl -s -X POST http://127.0.0.1:8080/p/demo/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ blogs(first: 1) { totalCount nodes { id title } } }"}'
```

```json
{"data":{"blogs":{"nodes":[{"id":"3d1de1352b2a","title":"タイトル 1"}],"totalCount":3}}}
```

- endpoint は **`/p/{プロジェクト slug}/graphql`** の 1 本です。型ごとの URL はありません
- **公開中の entry は鍵無しで読めます**（プロジェクトの公開範囲が public の時。private なら 9 章の API キーが要ります）
- POST は `Content-Type: application/json`、ボディは `{"query": "...", "variables": {...}, "operationName": "..."}`（`variables` と `operationName` は省けます）
- GET も使えます。`?query=...&variables=...&operationName=...` を URL エンコードして渡します（`variables` は JSON 文字列）。GET は 10 章のキャッシュに乗ります

```bash
curl -s -G http://127.0.0.1:8080/p/demo/graphql \
  --data-urlencode 'query=query($n: Int!) { blogs(first: $n) { nodes { id } } }' \
  --data-urlencode 'variables={"n":1}'
```

```json
{"data":{"blogs":{"nodes":[{"id":"3d1de1352b2a"}]}}}
```

Query の root には、型ごとに **一覧**（`blogs` のように apiId をそのまま）と **1 件**（`blog` のように型名の先頭 1 文字を小文字に）が生えます。
`_types` は型の数で、どのプロジェクトにもあります（型が 0 個でもスキーマが組めるようにする物。サイトから使う事はありません）。

```graphql
{ _types }
```

```json
{"data":{"_types":9}}
```

落とし穴:

- プロジェクト slug を間違えると **HTTP 404** で `{"data":null,"errors":[{"message":"プロジェクト 'no-such-project' がありません"}]}` が返ります。`extensions` は付きません（11 章）
- ボディが JSON として壊れていると **HTTP 400** です。GraphQL の実行まで届いた失敗は全部 **HTTP 200** で `errors[]` に入ります

---

## 2. 一覧を取る

```graphql
{ blogs(first: 2, skip: 1) { totalCount nodes { id title } } }
```

```json
{"data":{"blogs":{"nodes":[{"id":"917989b4920d","title":"タイトル 2"},{"id":"ce38c28d9d4a","title":"タイトル 3"}],"totalCount":3}}}
```

| 引数 / フィールド | 意味 |
|---|---|
| `first` | 1 ページの件数。省くと **20**。**上限は 200** で、超えた値は黙って 200 に丸められます（エラーにならない） |
| `skip` | 先頭から飛ばす件数。省くと 0。**10000 まで**。それより後ろは 5 章の cursor で読みます |
| `totalCount` | `where` を当てた後の総件数（`first` / `skip` に関係なく全体） |
| `nodes` | entry の配列。`edges { cursor node }` でも読めます（5 章） |

既定の並び順は **`updatedAt_DESC`**（更新が新しい順）です。公開日順にしたければ `orderBy: [publishedAt_DESC]` を付けます（4 章）。

`first: 0` は「件数だけ欲しい」時に使えます。

```graphql
{ blogs(first: 0) { totalCount nodes { id } } }
```

```json
{"data":{"blogs":{"nodes":[],"totalCount":3}}}
```

`skip` の上限を超えると `INVALID` です。

```graphql
{ blogs(skip: 10001) { totalCount } }
```

```json
{"data":null,"errors":[{"extensions":{"classification":"DataFetchingException","code":"INVALID","violations":[{"field":"skip","message":"skip は 10000 まで指定できます（これより後ろは after に前のページの endCursor を指定してください）"}]},"locations":[{"column":3,"line":1}],"message":"skip: skip は 10000 まで指定できます（これより後ろは after に前のページの endCursor を指定してください）","path":["blogs"]}]}
```

落とし穴:

- **`first: 1000` はエラーにならず 200 件で切れます。** 全件を静的生成するなら `pageInfo.hasNextPage` を見て cursor で回す事（5 章）。`first: 100` で止めて `hasNextPage` を見ないと、101 件目から黙って落ちます
- `first` に負の値を渡しても 0 に丸められるだけでエラーになりません
- 既定の並びは公開日ではなく**更新日**です。公開後に直した entry が先頭に来ます

---

## 3. 絞り込む（where）

まず動く例を 3 つ。

タイトルの部分一致:

```graphql
{ blogs(where: { title_contains: "2" }) { totalCount nodes { id title } } }
```

```json
{"data":{"blogs":{"nodes":[{"id":"917989b4920d","title":"タイトル 2"}],"totalCount":1}}}
```

カテゴリ（参照）の id で:

```graphql
{ blogs(where: { category_id_eq: "8633b69d22fc" }) { totalCount nodes { id title category { id name } } } }
```

```json
{"data":{"blogs":{"nodes":[{"category":{"id":"8633b69d22fc","name":"カテゴリ名 1"},"id":"3d1de1352b2a","title":"タイトル 1"},{"category":{"id":"8633b69d22fc","name":"カテゴリ名 1"},"id":"917989b4920d","title":"タイトル 2"},{"category":{"id":"8633b69d22fc","name":"カテゴリ名 1"},"id":"ce38c28d9d4a","title":"タイトル 3"}],"totalCount":3}}}
```

公開日の範囲（ISO 8601。日付だけなら UTC の 0 時）:

```graphql
{ blogs(where: { publishedAt_gte: "2026-09-01T00:00:00Z", publishedAt_lt: "2026-10-01T00:00:00Z" }) { totalCount nodes { id publishedAt } } }
```

```json
{"data":{"blogs":{"nodes":[{"id":"3d1de1352b2a","publishedAt":"2026-09-12T10:59:52.515204Z"},{"id":"917989b4920d","publishedAt":"2026-09-12T10:59:52.515204Z"},{"id":"ce38c28d9d4a","publishedAt":"2026-09-12T10:59:52.515204Z"}],"totalCount":3}}}
```

### 演算子はフィールドの種類で決まる

`where` の入力型は型ごとに生成されます（`BlogWhere`、`ArticleWhere`、…）。中のフィールド名は `<apiId>_<演算子>` で、どの演算子が生えるかは管理画面で選んだフィールドの種類で決まります。
自分の型に何があるかは introspection か、管理画面の「API プレビュー」で見ます（13 章）。

全部の種類に共通:

| 演算子 | 意味 | 例 |
|---|---|---|
| `_isNull` | 値が無い（`true`）/ ある（`false`） | `thumbnail_isNull: false` |

システムの日時（`createdAt` / `updatedAt` / `publishedAt`。どの型にもあります）:

| 演算子 | 意味 | 例 |
|---|---|---|
| `_gt` / `_gte` / `_lt` / `_lte` | 範囲。値は ISO 8601 の文字列 | `publishedAt_gte: "2026-09-01"` |

テキスト（テキスト / テキストエリア / slug。`demo` の `title` `description`、`Profile.slug`）:

| 演算子 | 意味 | 例 |
|---|---|---|
| `_eq` | 完全一致 | `title_eq: "タイトル 1"` |
| `_in` | いずれかに一致 | `title_in: ["タイトル 1", "タイトル 3"]` |
| `_contains` | 部分一致 | `title_contains: "2"` |
| `_startsWith` | 前方一致 | `slug_startsWith: "profiles-"` |

数値（`demo` には数値のフィールドが無いので、ここは実測ではなくスキーマの生成規則から書いています）:

| 演算子 | 意味 | 例 |
|---|---|---|
| `_eq` | 一致 | `price_eq: 100` |
| `_gt` / `_gte` / `_lt` / `_lte` | 範囲 | `price_lte: 1000` |

真偽（`demo` の `memberOnly`）:

| 演算子 | 意味 | 例 |
|---|---|---|
| `_eq` | 一致 | `memberOnly_eq: true` |

```graphql
{ blogs(where: { memberOnly_eq: true }) { totalCount nodes { id title } } }
```

```json
{"data":{"blogs":{"nodes":[{"id":"917989b4920d","title":"タイトル 2"}],"totalCount":1}}}
```

日時のフィールド（自分で作った DATE の種類。`demo` には無し）: システムの日時と同じ `_gt` / `_gte` / `_lt` / `_lte` に加えて `_eq`。

セレクト（`demo` には無し）: `_eq` / `_in`。値はその型のために生成された enum。

参照（`demo` の `category` `profile` `theFirstPart` …）:

| 演算子 | 意味 | 例 |
|---|---|---|
| `_id_eq` | 参照先の entry id が一致 | `category_id_eq: "8633b69d22fc"` |
| `_id_in` | いずれかの entry id | `category_id_in: ["8633b69d22fc", "4f56676136d5"]` |

参照の配列（`demo` の `tags`）:

| 演算子 | 意味 | 例 |
|---|---|---|
| `_contains` | その entry id を含む | `tags_contains: "acf39f852649"` |

asset（`demo` の `thumbnail` `coverImage`）:

| 演算子 | 意味 | 例 |
|---|---|---|
| `_id_eq` | asset id が一致 | `thumbnail_id_eq: "e70ff098754d"` |

richText / オブジェクト / ブロック: `_isNull` だけ。本文の全文検索はありません。

### AND / OR

同じ `where` の中に複数の条件を並べると AND です。`OR` と `AND` は**配列で 1 段だけ**。中の要素の型（`BlogWhereLeaf`）には `AND` / `OR` が無いので、入れ子にはできません。

```graphql
{ blogs(where: { OR: [{ title_eq: "タイトル 1" }, { title_eq: "タイトル 3" }] }) { totalCount nodes { id title } } }
```

```json
{"data":{"blogs":{"nodes":[{"id":"3d1de1352b2a","title":"タイトル 1"},{"id":"ce38c28d9d4a","title":"タイトル 3"}],"totalCount":2}}}
```

```graphql
{ blogs(where: { AND: [{ category_id_eq: "8633b69d22fc" }, { memberOnly_eq: false }] }) { totalCount nodes { id title } } }
```

```json
{"data":{"blogs":{"nodes":[{"id":"3d1de1352b2a","title":"タイトル 1"},{"id":"ce38c28d9d4a","title":"タイトル 3"}],"totalCount":2}}}
```

### 参照は id でしか絞れない

`category.name` や `profile.slug` で `blogs` を絞る演算子は**ありません**。参照先の名前や slug で絞りたい時は、先に参照先を引いて id を取り、その id で絞ります（2 往復）。

```graphql
{ profile(slug: "profiles-2") { id name slug } }
```

```json
{"data":{"profile":{"id":"32b59b564442","name":"名前 2","slug":"profiles-2"}}}
```

その `id` を `blogs(where: { profile_id_eq: "32b59b564442" })` に渡します。

落とし穴:

- **日時の値が読めない形だと、エラーにならず 0 件になります。** `publishedAt_gte: "2026/09/01"` は `totalCount: 0` を黙って返します。ISO 8601（`2026-09-01` か `2026-09-01T00:00:00Z`）で渡す事
- `OR` の中に `AND` を入れると `ValidationError`（`contains a field not in 'BlogWhereLeaf': 'AND'`）
- 参照は id でしか絞れません。slug で絞るには参照先を先に引く
- `_contains` は文字列の部分一致で、単語の一致や全文検索ではありません

---

## 4. 並べる（orderBy）

```graphql
{ blogs(orderBy: [title_DESC]) { nodes { id title } } }
```

```json
{"data":{"blogs":{"nodes":[{"id":"ce38c28d9d4a","title":"タイトル 3"},{"id":"917989b4920d","title":"タイトル 2"},{"id":"3d1de1352b2a","title":"タイトル 1"}]}}}
```

`orderBy` は enum の配列で、先の要素が優先です。値は型ごとに生成されます（`BlogOrderBy`）。`demo` の `Blog` では:

| 値 | 中身 |
|---|---|
| `id_ASC` / `id_DESC` | entry id |
| `publishedAt_ASC` / `publishedAt_DESC` | 公開日時 |
| `updatedAt_ASC` / `updatedAt_DESC` | 更新日時（既定は `updatedAt_DESC`） |
| `createdAt_ASC` / `createdAt_DESC` | 作成日時 |
| `title_ASC` / `title_DESC`、`memberOnly_ASC` / …、`description_ASC` / … | テキスト・数値・真偽・日時のフィールド |

参照・asset・richText・配列のフィールドは並び順に使えません（enum に生えません）。

値が無い（NULL の）行は、昇順でも降順でも**末尾**に来ます。`publishedAt` が NULL なのは未公開の entry だけなので、`stage: DRAFT`（9 章）で下書きを混ぜて `publishedAt_DESC` で並べた時に、未公開の物が最後にまとまります。公開中だけを読む限り `publishedAt` は必ず入ります。

落とし穴:

- 同じ値が並んだ時の順は id で決まります（この `demo` は 3 件が同じ `publishedAt` なので、`publishedAt_DESC` でも id 順に見えます）
- `orderBy` を変えたら、持っている cursor は捨てて先頭から読み直します（5 章）

---

## 5. ページを送る（cursor）

1 ページ目。`first: 1` で `pageInfo.endCursor` を取ります。

```graphql
{ blogs(first: 1, orderBy: [publishedAt_DESC]) { edges { cursor node { id title publishedAt } } pageInfo { hasNextPage endCursor } } }
```

```json
{"data":{"blogs":{"edges":[{"cursor":"eyJpZCI6IjNkMWRlMTM1MmIyYSIsImsiOlt7ImRpciI6IkRFU0MiLCJrZXkiOiJwdWJsaXNoZWRBdCIsInQiOjE3ODkyMTA3OTI1MTUyMDR9XX0","node":{"id":"3d1de1352b2a","publishedAt":"2026-09-12T10:59:52.515204Z","title":"タイトル 1"}}],"pageInfo":{"endCursor":"eyJpZCI6IjNkMWRlMTM1MmIyYSIsImsiOlt7ImRpciI6IkRFU0MiLCJrZXkiOiJwdWJsaXNoZWRBdCIsInQiOjE3ODkyMTA3OTI1MTUyMDR9XX0","hasNextPage":true}}}}
```

2 ページ目。`endCursor` をそのまま `after` に渡します。`orderBy` は 1 ページ目と同じにします。

```graphql
{ blogs(first: 1, orderBy: [publishedAt_DESC], after: "eyJpZCI6IjNkMWRlMTM1MmIyYSIsImsiOlt7ImRpciI6IkRFU0MiLCJrZXkiOiJwdWJsaXNoZWRBdCIsInQiOjE3ODkyMTA3OTI1MTUyMDR9XX0") { edges { cursor node { id title publishedAt } } pageInfo { hasNextPage endCursor } } }
```

```json
{"data":{"blogs":{"edges":[{"cursor":"eyJpZCI6IjkxNzk4OWI0OTIwZCIsImsiOlt7ImRpciI6IkRFU0MiLCJrZXkiOiJwdWJsaXNoZWRBdCIsInQiOjE3ODkyMTA3OTI1MTUyMDR9XX0","node":{"id":"917989b4920d","publishedAt":"2026-09-12T10:59:52.515204Z","title":"タイトル 2"}}],"pageInfo":{"endCursor":"eyJpZCI6IjkxNzk4OWI0OTIwZCIsImsiOlt7ImRpciI6IkRFU0MiLCJrZXkiOiJwdWJsaXNoZWRBdCIsInQiOjE3ODkyMTA3OTI1MTUyMDR9XX0","hasNextPage":true}}}}
```

最後のページは `hasNextPage: false` になります。

```graphql
{ blogs(first: 1, orderBy: [publishedAt_DESC], after: "eyJpZCI6IjkxNzk4OWI0OTIwZCIsImsiOlt7ImRpciI6IkRFU0MiLCJrZXkiOiJwdWJsaXNoZWRBdCIsInQiOjE3ODkyMTA3OTI1MTUyMDR9XX0") { edges { node { id title } } pageInfo { hasNextPage endCursor } } }
```

```json
{"data":{"blogs":{"edges":[{"node":{"id":"ce38c28d9d4a","title":"タイトル 3"}}],"pageInfo":{"endCursor":"eyJpZCI6ImNlMzhjMjhkOWQ0YSIsImsiOlt7ImRpciI6IkRFU0MiLCJrZXkiOiJwdWJsaXNoZWRBdCIsInQiOjE3ODkyMTA3OTI1MTUyMDR9XX0","hasNextPage":false}}}}
```

- 形は GitHub の GraphQL API と同じです。`nodes` と `edges { cursor node }` の両方があり、素の fetch なら `nodes` + `pageInfo`、Apollo / urql / Relay なら `edges`
- cursor は「並び順のキーの値 + id」を base64url にした物です。**中を読まず、`endCursor` をそのまま次の `after` に渡します**
- cursor は `orderBy` と対で意味を持ちます。並び順を変えて古い cursor を渡すと `INVALID`
- ページを送っている途中で entry が増えても、重複や抜けは出ません（行の位置ではなく値で続きを決めているため）

`skip` と同時には渡せません:

```graphql
{ blogs(first: 1, skip: 1, orderBy: [publishedAt_DESC], after: "eyJpZCI6IjNkMWRlMTM1MmIyYSIsImsiOlt7ImRpciI6IkRFU0MiLCJrZXkiOiJwdWJsaXNoZWRBdCIsInQiOjE3ODkyMTA3OTI1MTUyMDR9XX0") { nodes { id } } }
```

```json
{"data":null,"errors":[{"extensions":{"classification":"DataFetchingException","code":"INVALID","violations":[{"field":"after","message":"after と skip は同時に指定できません（どちらか 1 つ）"}]},"locations":[{"column":3,"line":1}],"message":"after: after と skip は同時に指定できません（どちらか 1 つ）","path":["blogs"]}]}
```

並び順を変えて渡すと:

```graphql
{ blogs(first: 1, orderBy: [title_ASC], after: "eyJpZCI6IjNkMWRlMTM1MmIyYSIsImsiOlt7ImRpciI6IkRFU0MiLCJrZXkiOiJwdWJsaXNoZWRBdCIsInQiOjE3ODkyMTA3OTI1MTUyMDR9XX0") { nodes { id } } }
```

```json
{"data":null,"errors":[{"extensions":{"classification":"DataFetchingException","code":"INVALID","violations":[{"field":"after","message":"cursor が orderBy と合いません（並び順を変えたら先頭から読み直してください）"}]},"locations":[{"column":3,"line":1}],"message":"after: cursor が orderBy と合いません（並び順を変えたら先頭から読み直してください）","path":["blogs"]}]}
```

壊れた文字列を渡すと:

```graphql
{ blogs(first: 1, after: "abc") { nodes { id } } }
```

```json
{"data":null,"errors":[{"extensions":{"classification":"DataFetchingException","code":"INVALID","violations":[{"field":"after","message":"cursor が壊れています"}]},"locations":[{"column":3,"line":1}],"message":"after: cursor が壊れています","path":["blogs"]}]}
```

落とし穴:

- `skip` と `after` の同時指定は `INVALID`。`skip: 0` は「指定なし」と見なされるので通ります
- `orderBy` を省いた 1 ページ目の cursor は既定の `updatedAt_DESC` と対です。2 ページ目でも `orderBy` を省く事
- 他のプロジェクトや他の型の cursor を渡すと、エラーではなく **0 件**になります
- `where` を変えた時も先頭から読み直す事（cursor は `where` を覚えていません。変えた条件の中での「続き」になります）

---

## 6. 1 件を取る

id で:

```graphql
{ blog(id: "3d1de1352b2a") { id title } missing: blog(id: "000000000000") { id } }
```

```json
{"data":{"blog":{"id":"3d1de1352b2a","title":"タイトル 1"},"missing":null}}
```

無い id は `null` で、`errors` は付きません。

### `slug` の引数が出る条件

1 件のフィールドに `slug` の引数が生えるのは、**unique にした slug のフィールドを 1 個だけ持つ型**に限ります。`demo` では `Profile` がそれで、`Blog` には slug のフィールドが無いので `blog(slug:)` はありません。

```graphql
{ profile(slug: "profiles-2") { id name slug } }
```

```json
{"data":{"profile":{"id":"32b59b564442","name":"名前 2","slug":"profiles-2"}}}
```

無い slug は `null`:

```graphql
{ profile(slug: "no-such-slug") { id } }
```

```json
{"data":{"profile":null}}
```

`id` と `slug` は**どちらか 1 つ**。両方渡す・両方省くは `INVALID` です。

```graphql
{ profile(id: "x", slug: "y") { id } }
```

```json
{"data":{"profile":null},"errors":[{"extensions":{"classification":"DataFetchingException","code":"INVALID","violations":[{"field":"id","message":"id か slug のどちらか 1 つを指定してください"}]},"locations":[{"column":3,"line":1}],"message":"id: id か slug のどちらか 1 つを指定してください","path":["profile"]}]}
```

`slug` の引数が無い型でも、`id` を省くと同じメッセージが返ります（`{ blog { id } }` → `id か slug のどちらか 1 つを指定してください`）。

### `slug` の引数が出ない型で、slug から 1 件を引く

slug のフィールドを unique にしていない、または slug のフィールドが 2 個以上ある型では、一覧を `where` で絞ります。**`orderBy` を明示して**返る 1 件を決定的にします。

```graphql
{ profiles(where: { slug_eq: "profiles-2" }, first: 1, orderBy: [publishedAt_DESC]) { totalCount nodes { id name slug } } }
```

```json
{"data":{"profiles":{"nodes":[{"id":"32b59b564442","name":"名前 2","slug":"profiles-2"}],"totalCount":1}}}
```

`totalCount` が 2 以上なら slug が重複しています。

落とし穴:

- **slug の unique は公開時にだけ照合されます。下書き（`stage: DRAFT`）では同じ slug の entry が複数ありえます。** `slug` の引数で引いて 2 件以上見つかると `null` ではなく `INVALID` になります（重複を隠しません）。プレビューで slug から引く時は、この失敗を扱う事
- `id` の型は `ID`（非 null ではない）です。`slug` と選べるようにするためで、graphql-codegen で作った型では `id` の引数が optional になります（12 章）
- 型名の先頭 1 文字だけが小文字になります（`BlogPost` → `blogPost`）。snake_case にはなりません

---

## 7. 本文（RichText）

```graphql
{ blogs(first: 1) { nodes { id title content { excerpt wordCount readingTimeMinutes headings { level text id } links { id apiId path } assets { id url width height alt } } } } }
```

```json
{"data":{"blogs":{"nodes":[{"content":{"assets":[{"alt":"1 枚目・横長。本文の中に置く画像","height":630,"id":"e70ff098754d","url":"http://127.0.0.1:9000/cms/2/e70ff098754d/demo-wide.png","width":1200},{"alt":"2 枚目・並べた左側の画像","height":600,"id":"8f1aabdade20","url":"http://127.0.0.1:9000/cms/2/8f1aabdade20/demo-side-a.png","width":800},{"alt":"3 枚目・並べた右側の画像","height":600,"id":"0087864dd193","url":"http://127.0.0.1:9000/cms/2/0087864dd193/demo-side-b.png","width":800},{"alt":"4 枚目・縦長。小さく右に寄せた画像","height":900,"id":"416b528bff75","url":"http://127.0.0.1:9000/cms/2/416b528bff75/demo-tall.png","width":600}],"excerpt":"内容 1 の全部盛り 文字に掛ける印 この段落には太字・斜体・打ち消し・下線・蛍光ペン・Map.getを並べています。 水は H2O、面積は 10 m2 です。文の中の数式は e^{i\\pi} + 1 = 0 のように書けます。 外部リンク…","headings":[{"id":"demo-top","level":2,"text":"内容 1 の全部盛り"},{"id":"h-1","level":3,"text":"文字に掛ける印"},{"id":"h-2","level":3,"text":"リスト"},{"id":"h-3","level":3,"text":"引用"},{"id":"h-4","level":3,"text":"コード"},{"id":"h-5","level":3,"text":"表"},{"id":"h-6","level":3,"text":"画像"},{"id":"h-7","level":3,"text":"数式"},{"id":"h-8","level":3,"text":"囲みと埋め込み"},{"id":"demo-media","level":4,"text":"カードと埋め込み"}],"links":[],"readingTimeMinutes":2,"wordCount":483},"id":"3d1de1352b2a","title":"タイトル 1"}]}}}
```

richText のフィールド（`demo` の `content`、`fresh-blog` の `body`）は `RichText` 型で返り、同じ本文を何通りかの形で読めます。要る物だけ選びます。

| フィールド | 中身 | 使い所 |
|---|---|---|
| `html` | 描画済みの HTML。見出しに `id`、画像は `<img src width height alt>`、表・callout・details・埋め込み・数式・Mermaid は class ではなく `data-*` 属性 | **SSG / SSR でそのまま差し込む**時。一番手間が少ない |
| `json` | ProseMirror の doc（JSON） | **独自に描画する**時（React のコンポーネントに割り当てる等） |
| `markdown` | Markdown。ただし**この CMS の方言**を含む: 画像は `![alt](asset:ID)`、entry へのリンクは `entry:ID` | 既存の Markdown パイプラインに流す時。`asset:ID` は `assets` で、`entry:ID` は `links` で URL に解く |
| `text` | 平文（改行区切り） | 検索の索引、OGP の description |
| `excerpt(length: Int = 120)` | 平文の先頭。切れたら末尾に `…` | 一覧のカード |
| `wordCount` / `readingTimeMinutes` | 文字数と読了時間（分） | 一覧のカード |
| `headings` | `{ level text id }` の配列。`id` は `html` の見出しの `id` と同じ | **目次**。`#id` でページ内リンクが繋がる |
| `links` | 本文が指している entry。`{ id apiId path }`。`path` は型の設定に公開サイトのパスがあれば入り、無ければ `null` | `markdown` の `entry:ID` を解く。参照先が公開されているかの確認 |
| `assets` | 本文が指している asset。`Asset` 型（8 章） | `markdown` の `asset:ID` を解く。`json` から自分で描く時の画像の寸法 |

`html` の実物（長いので要点だけ）:

```html
<h2 id="demo-top">内容 1 の全部盛り</h2>
<p>この段落には<strong>太字</strong>・<em>斜体</em>・<s>打ち消し</s>・<u>下線</u>・<mark>蛍光ペン</mark>・<code>Map.get</code>を並べています。</p>
<pre data-file-name="src/demo.ts" data-highlight-lines="2,4-5" data-wrap><code class="language-ts">export function greet(who: string) { … }</code></pre>
<pre data-diagram="mermaid"><code class="language-mermaid">graph TD …</code></pre>
<figure><img src="http://127.0.0.1:9000/cms/2/e70ff098754d/demo-wide.png" alt="1 枚目・横長。本文の中に置く画像" width="1200" height="630"><figcaption>…</figcaption></figure>
<div data-math="block">\sum_{i=1}^{n} i = \frac{n(n+1)}{2}</div>
<aside data-kind="note"><p>note の囲みです。補足を入れます。</p></aside>
<figure data-embed="youtube"><iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ" loading="lazy" allowfullscreen …></iframe></figure>
```

落とし穴:

- **コードのシンタックスハイライト、数式（TeX）、Mermaid は CMS が描きません。** `html` には `class="language-ts"`、`data-math`、`data-diagram="mermaid"` で中身がそのまま入るので、サイト側で highlight.js / KaTeX / mermaid を当てます
- `markdown` の `asset:ID` / `entry:ID` は**そのまま Markdown の描画に渡すと壊れたリンクになります**。`assets` / `links` で置き換えてから渡す事。解決済みが要るなら `html`
- `html` の画像の URL は絶対 URL で焼き込まれています。静的生成の後に asset の配信ドメインを変えたら、生成し直す事
- `links[].path` は型の設定（公開サイトのパス）が無い間 `null` です
- `excerpt` は `text` の先頭を切っただけです。見出しも本文も区別しません

---

## 8. 画像（Asset）

```graphql
{ blogs(first: 1) { nodes { thumbnail { id url fileName mime size width height alt } } } }
```

```json
{"data":{"blogs":{"nodes":[{"thumbnail":{"alt":"1 枚目・横長。本文の中に置く画像","fileName":"demo-wide.png","height":630,"id":"e70ff098754d","mime":"image/png","size":5943,"url":"http://127.0.0.1:9000/cms/2/e70ff098754d/demo-wide.png","width":1200}}]}}}
```

| フィールド | 中身 |
|---|---|
| `id` | asset id |
| `url` | 配信 URL（絶対 URL）。`<img src>` にそのまま使う |
| `fileName` / `mime` / `size` | 元のファイル名、MIME、バイト数 |
| `width` / `height` | 画像なら寸法。画像でなければ `null`。`next/image` の `width` / `height` に渡す |
| `alt` | 代替テキスト（空文字の事もある。`null` にはならない） |

落とし穴:

- **リサイズや形式変換の URL はありません。** `url` は元のファイルそのままです。サムネイルが要るなら、`next/image` のようなサイト側の画像最適化を通します（`remotePatterns` に `url` のホストを足す）
- asset のフィールドの `where` は `_isNull` と `_id_eq` だけです。ファイル名や MIME では絞れません

---

## 9. 下書きとプレビュー

鍵無しで `stage: DRAFT` を投げると `FORBIDDEN` です。

```graphql
{ blogs(stage: DRAFT) { totalCount } }
```

```json
{"data":null,"errors":[{"extensions":{"classification":"DataFetchingException","code":"FORBIDDEN"},"locations":[{"column":3,"line":1}],"message":"この操作（readDraft）の権限がありません","path":["blogs"]}]}
```

`Stage` は `DRAFT` と `PUBLISHED` の 2 値で、一覧と 1 件のどちらにも `stage` の引数があります。省けば `PUBLISHED`。参照先（`category` や `profile`）も同じ stage で展開されます。

下書きを読む道は 2 つ:

| 道 | ヘッダ | 読める範囲 | 用途 |
|---|---|---|---|
| **API キー**（範囲 `READ_DRAFT`） | `X-Api-Key: <鍵>` | プロジェクトの全部の下書き | プレビュー環境のビルド、staging サイト |
| **プレビュートークン** | `X-Preview-Token: <トークン>` | **その entry とその参照先**の下書きだけ | 編集画面から開く「画面プレビュー」（entry 1 件ずつ） |

- API キーは管理画面の「設定 › API キーと Webhook」で発行します。範囲は `READ`（公開中だけ。private なプロジェクトを読む用）/ `READ_DRAFT`（下書きも）/ `WRITE`（管理 API 用。サイトからは使わない）
- プレビュートークンは管理 API の `createPreviewToken` で entry ごとに発行されます（既定 1 時間、最長 1 日）。編集画面の「画面プレビュー」は、型の設定の `previewUrl` の `{id}` を entry id に置き換え、`?preview=<トークン>` を付けて開きます。サイト側は `preview` のパラメータを取り出して `X-Preview-Token` に載せます（Next.js なら Draft Mode の cookie に入れる）。`previewUrl` が無い型では「画面プレビュー」は開けません
- プロジェクトの公開範囲が **private** なら、公開中を読むのにも API キーが要ります。匿名は `UNAUTHENTICATED`、メンバーでない人のログインは `FORBIDDEN`
- 鍵・トークン付きの GET の応答は **`Cache-Control: private, no-store`** になり、ETag も付きません（10 章）。下書きは CDN に乗りません

落とし穴:

- **鍵をブラウザに出さない。** `X-Api-Key` はサーバ側（SSG のビルド、Route Handler、Server Component）からだけ送ります。クライアントからの fetch に載せると誰でも下書きを読めます
- 知らない鍵を `X-Api-Key` に渡しても**エラーにならず、匿名として扱われます**（公開中は読め、`stage: DRAFT` は `FORBIDDEN`）。鍵を間違えているのに「公開中しか出ない」時はここを疑う事。知らないプレビュートークンも同じです
- 下書きの `publishedAt` は `null` です（4 章）
- 下書きでは slug が重複しうるので、slug から 1 件を引く時は 6 章の注意を読む事

---

## 10. キャッシュ

鍵無しの GET には CDN 向けのヘッダが付きます。

```bash
curl -s -G --data-urlencode 'query={ blogs(first: 1) { nodes { id title } } }' \
  http://127.0.0.1:8080/p/demo/graphql -D -
```

```http
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
Cache-Control: public, s-maxage=10, max-age=0, stale-while-revalidate=60
Vary: X-Api-Key, X-Preview-Token, Authorization
ETag: W/"v384-d9685e98e877ab79"

{"data":{"blogs":{"nodes":[{"id":"3d1de1352b2a","title":"タイトル 1"}]}}}
```

`If-None-Match` に ETag を返すと、中身が変わっていなければ **304**（本文無し）です。

```bash
curl -s -G --data-urlencode 'query={ blogs(first: 1) { nodes { id title } } }' \
  -H 'If-None-Match: W/"v384-d9685e98e877ab79"' \
  http://127.0.0.1:8080/p/demo/graphql -D - -o /dev/null
```

```http
HTTP/1.1 304 Unknown
Content-Length: 0
ETag: W/"v384-d9685e98e877ab79"
Cache-Control: public, s-maxage=10, max-age=0, stale-while-revalidate=60
Vary: X-Api-Key, X-Preview-Token, Authorization
```

| ヘッダ | 意味 |
|---|---|
| `Cache-Control: public, s-maxage=10, max-age=0, stale-while-revalidate=60` | CDN（共有キャッシュ）は 10 秒持つ。ブラウザは持たない（`max-age=0`）。期限切れから 60 秒は裏で取り直しながら古い物を返す。値はサーバの環境変数で変わります |
| `ETag: W/"v<版>-<ハッシュ>"` | weak な ETag。`<版>` はプロジェクト単位の番号で、公開・取り下げ・削除・型の変更で +1。`<ハッシュ>` は query + variables + operationName から。**本文のハッシュではない**ので、同じ文書なら応答の中身を読まずに 304 を返せる |
| `Vary: X-Api-Key, X-Preview-Token, Authorization` | 鍵付きと匿名の応答を混ぜないため |

CDN を前に置く時の考え方（詳細は `docs/design/cdn.md`、Cloudflare の設定は `deploy/cloudflare-cache-rules.md`）:

- **サイトから CMS を読むのは GET にする。** POST はキャッシュされません（POST の応答には `Cache-Control` も `ETag` も付きません）
- 版はプロジェクト単位なので、**1 回の公開でそのプロジェクトのキャッシュは全部無効になります**。`s-maxage=10` なので、公開が公開サイトに届くまで最長 10 秒（purge を入れれば最長 2 秒）
- 下書きの保存では版は進みません（匿名の応答の中身が変わらないため）
- Cloudflare は `Vary` をキャッシュの鍵に使いません。cache rule で `X-Api-Key` / `X-Preview-Token` / `Authorization` が付いた要求をキャッシュの対象から外す事。外さないと匿名の応答が鍵付きの要求に返ります
- Next.js の ISR や Astro の SSG のように**サイト側でも持つ**なら、CMS の Webhook（公開・取り下げ）を受けて再検証します。毎リクエスト CMS を叩く構成（`force-dynamic` + `no-store`）は CMS を単一障害点にします

落とし穴:

- `errors` がある GET の応答は `Cache-Control: private, no-store` で、ETag も付きません。失敗をキャッシュしません
- 鍵付きは `private, no-store`。下書きのプレビューは毎回 origin に届きます
- 版の読み取りと本文の読み取りが別の Tx なので、公開の瞬間に「古い ETag に新しい中身」が乗る事があります。逆（新しい ETag に古い中身）は起きません。古い物を見せ続ける事はありません

---

## 11. エラーの読み方

失敗は GraphQL の仕様どおり `errors[]` に入り、HTTP は **200** です。`message` は人が読む日本語で、クライアントは **`extensions.code` で分岐**します（`message` の文字列で分岐しない）。

```json
{"data":null,"errors":[{"extensions":{"classification":"DataFetchingException","code":"INVALID","violations":[{"field":"after","message":"cursor が壊れています"}]},"locations":[{"column":3,"line":1}],"message":"after: cursor が壊れています","path":["blogs"]}]}
```

コンテンツ API で見る `code`:

| code | いつ | どうするか |
|---|---|---|
| `INVALID` | 引数が規則に合わない（`skip` の上限、`after` と `skip` の同時指定、cursor と `orderBy` の不一致、`id` と `slug` の両方指定、slug の重複） | `violations[]` の `field` / `message` を見て query を直す。再送しても同じ |
| `FORBIDDEN` | 権限が無い（鍵無しの `stage: DRAFT`、private なプロジェクトにメンバーでない人） | `READ_DRAFT` の API キーを付ける |
| `UNAUTHENTICATED` | private なプロジェクトに匿名で来た | API キーを付ける |
| `INTERNAL` | サーバ側の失敗。`requestId` が付く（応答ヘッダ `X-Request-Id` と同じ） | **再試行してよいのはこれだけ。** 直らなければ `requestId` を添えて問い合わせる |

`NOT_FOUND` はコンテンツ API では出ません（無い id は `null`）。`CONFLICT` / `REQUIRES_LOGIN` は管理 API の物です。全部の一覧は `docs/design/error-codes.md`。

`extensions.code` が**付かない**失敗:

| 形 | いつ | 例 |
|---|---|---|
| `extensions.classification: "ValidationError"` | query が型に合わない（無いフィールド、`OR` の入れ子、引数の型違い）。graphql-java の検証 | `Validation error (FieldUndefined@[blogs/nodes/tags/name]) : Field 'name' in type 'Tag' is undefined` |
| `extensions.classification: "BadFaithIntrospection"` | 1 つの query に `__type` を 2 つ以上並べた | 12 章 |
| HTTP 400、`errors[].message` だけ | ボディが JSON でない、`query` が無い | `{"data":null,"errors":[{"message":"invalid JSON: unexpected character '&' at offset 41"}]}` |
| HTTP 404、`errors[].message` だけ | プロジェクト slug が無い | `プロジェクト 'no-such-project' がありません` |
| HTTP 405、`errors[].message` だけ | GET で mutation を送った | `GET は query だけです。mutation は POST で送ってください` |

認証に落ちた時（private なプロジェクトの匿名など）は HTTP 200 で `data: null`、`errors[]` は **`path` の無い 1 件**です。この時は 1 つのフィールドも実行されていません。

落とし穴:

- **`errors` が空かどうかだけで成否を判断しない。** 1 リクエストに複数のフィールドを並べると、一部だけ失敗して `data` に読めた分が入る事があります。`errors[].path` がどのフィールドか指します
- `violations[].field` は引数の名前（`after` / `skip` / `id`）です。管理 API と違って入力欄の位置ではありません
- 日時の形が読めない `where` はエラーになりません（3 章）

---

## 12. 型を自動生成する

スキーマは**プロジェクトごとに違います**（型・フィールド・`where` / `orderBy` は管理画面で作った物から生成）。必ず**自分のプロジェクトの URL**から introspection で取ります。`schema.graphql` のような固定ファイルはありません。

```bash
npm install -D @graphql-codegen/cli@latest @graphql-codegen/typescript@latest @graphql-codegen/typescript-operations@latest
```

`codegen.ts` の最小例:

```ts
import type { CodegenConfig } from "@graphql-codegen/cli";

const config: CodegenConfig = {
  schema: "http://127.0.0.1:8080/p/demo/graphql",
  documents: ["src/**/*.{ts,tsx,graphql}"],
  generates: {
    "src/generated/cms.ts": {
      plugins: ["typescript", "typescript-operations"],
    },
  },
};

export default config;
```

```bash
npx graphql-codegen --config codegen.ts
```

- 公開範囲が public なら鍵無しで introspection が通ります。private なら `schema` を `{ "http://.../graphql": { headers: { "X-Api-Key": process.env.CMS_API_KEY } } }` の形にします
- 型を作り直すタイミングは、管理画面の「API スキーマ」でフィールドを足した・消した・種類を変えた時です。CI で毎回生成すると、CMS 側の変更でビルドが落ちて気付けます

落とし穴:

- 1 件のフィールドの `id` は `ID`（optional）です。`slug` と選べるようにしているためで、生成した型でも `id` は必須になりません（6 章）
- introspection を手で書く時、**1 つの query に `__type` を 2 つ以上並べると `BadFaithIntrospection` で断られます**。型ごとに分けて投げます。graphql-codegen の標準の introspection query は 1 回で通ります
- `RichText.json` は `JSON` スカラーです。生成した型では `any` 相当になるので、ProseMirror の doc の型は自分で当てます

---

## 13. 次に読む物

- **管理画面の「API プレビュー」**: コンテンツ一覧と編集画面の「API」から右に開きます。自分の型の一覧と 1 件の query、`stage` の切り替え、`curl` の 1 行が出ます。`where` / `orderBy` の名前を確かめる一番早い場所です（API キーは画面に出ません）
- **管理画面の「API スキーマ」**: 型とフィールドの定義。`where` の演算子はフィールドの種類で決まるので（3 章）、ここで種類を見ます
- `docs/design/pagination.md`: cursor の中身と NULL の並び
- `docs/design/cdn.md` / `deploy/cloudflare-cache-rules.md`: CDN の設定
- `docs/design/error-codes.md`: `extensions.code` の全部
- `docs/architecture/auth.md`: 鍵・PAT・プレビュートークン・public / private
- `README.md`: Webhook の受け方（`scripts/webhook-receiver.py` に署名の照合の見本）
