# 作例サイトで見つかった穴（計画。2026-09-11 のレビュー後）

`~/Desktop/flix-cms-example`（Next.js の作例）で実際にコンテンツ API を叩いて見つかった問題。
**批判者 2 人（実装する側 / 使う側と運用側）のレビューを通した後の版。**初版の見積もりは 3 点で外れていた。

## レビューで分かった一番大事なこと

**`markdown` を足すだけでは使えない。** 受け取った `![alt](asset:ID)` を URL に変える口がコンテンツ API に無い。
`entry:ID` は `links { path }` で解けるのに、asset だけ対応物が無い（`ContentSchemaBuilder.flix:164-167` にルートは `_types` と型ごとのクエリだけ）。
2 人が独立に同じ指摘をした。

## 段 1: コンテンツ API（1 つの作業）

### 1-a. `RichText.assets` を足す（これが先）

`imageRefs`（本文の HTML を組む時に既に引いている物）をそのまま出す。`{ id url width height alt }`。
これで `markdown` を採ったサイトが 1 往復で画像を解決できる。N+1 にならない（既に 1 本で引いている）。

### 1-b. `RichText.markdown` を足す

`Markdown.toMarkdown(doc)` は純粋で引数が doc だけ（`Markdown.flix:177`）。依存の向きも effect の決めも問題なし。
**方言のまま出す**（`asset:ID` / `entry:ID`）。1-a と `links` で解けるので使える。
理由: URL を焼き込むと Markdown から doc に戻せず、往復が壊れる。往復はエンジニアモード（[[editor-two-modes-idea]]）の前提。

README に「`markdown` は CMS の方言を含む。画像は `assets`、entry のリンクは `links` で解く。解決済みが要るなら `html`」と明記。

**波及**: `RichText` 型の description（フィールドを列挙している）、SDL の文字列比較テスト、README、roadmap の 4 か所。

### 1-c. slug 直引き（レビューで見積もりが上がった）

**実装側の指摘 1**: `Schema` に `field3` が無い。`oneField` は `field2` なので、引数を 3 本にすると
`manyField` と同じ `fieldRaw` + `Arg.info` の列に書き換えになる。**`fieldRaw` 版に寄せる**（`field3` を足して 2 実装に割らない）。

**実装側の指摘 2（重い）**: **slug は一意でも必須でも 1 個でもない。**
`slugOf` は最初の SLUG フィールドを取るだけで、型に 1 個までという検査が無い。
`is_unique` は任意のフラグで、照合は公開時だけ。**下書き stage では同じ slug が普通に複数ある。**
`first = 1` に `orderBy` が無いので、返る 1 件が非決定になる。

**決め**:
- `slug` の引数を出すのは、**unique な SLUG フィールドを 1 個だけ持つ型**に限る（SDL が正直になる）
- 引く時は `orderBy` を明示して決定的にする
- 2 件以上ヒットしたら null ではなく **INVALID** で気付かせる（下書きで重複している事を隠さない）
- 両方 null / 両方指定も INVALID

**後方互換**: `ID!` → `ID` はワイヤ互換だが、introspection から型を作るクライアント（graphql-codegen）では
`id` が optional に緩む。README に 1 行。SDL のスナップショットのテストは「意図した変更」とコメントを残す。

### 段 1 のテスト

- Pg: 下書きで同じ slug が 2 件ある時に INVALID、slug を持たない型に引数が無い、両方 null / 両方指定が INVALID
- `TestQueryBudgetPg` に slug 直引きの行（`where` 経由と同じ 2 本で済む事）
- `TestCdnCachePg` の匿名 GET のキャッシュが新しい引数で分かれるか
- `body { markdown }` と `body { assets { url } }` を引く 1 本ずつ

## 段 2: 作例サイトの作り直し（使う側の指摘。段 1 と並行可）

**作例自身のバグと、雛形として不味い点**が 3 つ。

1. **全ページが毎リクエスト CMS を叩く**（`force-dynamic` + `no-store`）。この作例を雛形にした人は CMS を単一障害点にする
2. **Webhook から再検証する道が無い**。CMS に `Webhooks.flix` があるのに繋いでいない
3. **`listSlugs` が `first: 100` で `hasNextPage` を見ていない**。101 件目から静的生成が黙って落ちる

**やる**: ISR（`revalidate` + `tags`）、`app/api/revalidate/route.ts`（署名の照合は `scripts/webhook-receiver.py` の写し）、
ページングの修正。**これは段 1 より先でもよい**（CMS のソースを触らないため）。

## 段 3: 穴として記録するが今はやらない

### 3-a. 画像の変換と URL の焼き込み（使う側の指摘）

- `ASSET_PUBLIC_URL` はプロセスに 1 つで、プロジェクト単位でもリクエスト単位でも切り替わらない
- `Asset.url` に幅や形式の引数が無い（Contentful / Sanity / Payload は持つ）
- 絶対 URL が本文の HTML に焼き込まれるので、静的生成の後にドメインを変えると古い URL が残る。
  プレビュー環境と本番でドメインを分ける構成も取れない

**今やること**: `deploy/README.md` の環境変数の表に `ASSET_PUBLIC_URL` を単独の行で載せ、
「ドメインを変えたらキャッシュを捨てる」と「`markdown` / `assets` も同じ `publicUrl` を通る」を併記。
作例の README に `next.config.ts` の `remotePatterns` と揃える手順。

**将来**: `Asset.url(width: Int, format: ImageFormat)`。R2 / MinIO の前段に何を置くかで実現コストが変わるので、
そこを決めてから。

### 3-b. コードブロックの強調行

CMS 側は全部できている（検証・HTML の `data-highlight-lines`・Markdown の往復）が、**画面に入力の口が無い**。

- **今やる**: `code-block.ts` に入力欄を足す（ファイル名の実装を写せる）。
  コードブロックを note の形にする作業（`richtext-note-codeblock-ui.md`）と同じ作業にまとめる
- **行 span は入れない**。使う側のレビューで「サイト側はハイライトの後に行で分割すればよい（10 行）」と判明したので、
  CMS が HTML を変える必要は無い。作例にその 1 例を載せる
- 入力欄が入るまで README の該当行に「現状は入力手段が無い」と注記

## やる順

1. **段 2**（作例の ISR と Webhook とページング）。CMS を触らないので独立。雛形として一番危ない
2. **段 1**（`assets` → `markdown` → slug 直引き）。1 つの作業にまとめる
3. **段 3-b の入力欄**（コードブロックを note の形にする作業と同時）
4. 段 3-a の画像変換は、前段に何を置くかを決めてから

## 初版から変えた点（記録）

| 項目 | 初版 | 直した後 |
|---|---|---|
| `markdown` | 1 行で足せる（小） | `RichText.assets` が無いと使えない。2 本セットで足す |
| slug 直引き | 引数を 1 本足すだけ（中） | `field3` が無く `fieldRaw` に書き換え。slug は一意でも 1 個でもないので、出す条件と重複時の挙動を決める必要（中の上） |
| 画像 URL | 文書だけで済む | 文書だけでは済まない穴（プロジェクト単位・変換・焼き込み）を記録として残す |
| 行 span | 保留（サイト側の当て方が未決） | **入れない**（サイト側で解決できると判明） |
| 作例 | 完成 | ISR と Webhook とページングが抜けていた。雛形として直す |
