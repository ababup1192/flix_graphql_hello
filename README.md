# flix_graphql_hello

**Flix と PostgreSQL で書く headless CMS の API サーバ。** GraphQL の実行は Java の graphql-java を Java interop で使い、
Flix 側は代数的 effect でそれを境界に閉じ込めている。DB 層は [sqlfx](https://github.com/ababup1192/sqlfx)、HTTP は `java.net.ServerSocket` の上の手書き HTTP/1.1。

microCMS の移行先として作っている（動的に content type を定義し、GraphQL で読む）。ロードマップは [docs/design/roadmap.md](docs/design/roadmap.md)。

## API

| 入口 | 何をする |
|---|---|
| `/graphql` | **コンテンツ API**（読むだけ）。型の定義から graphql-java のスキーマを実行時に組む。`blogs` 型を作れば `blog(id)` / `blogs(where, orderBy, first, skip, after, stage)` と `Blog` / `BlogWhere` / `BlogOrderBy` / `BlogConnection` が生え、定義を変えると次のリクエストで組み直す |
| `/admin/graphql` | **管理 API**。型とフィールドの定義、entry の読み書き、公開、asset、Webhook、予約公開、鍵。SDL は `admin.graphql`（正） |
| `/account/graphql` | **Account API**。プロジェクトを選ぶ前の操作（me / 組織 / プロジェクト作成 / PAT）。SDL は `account.graphql` |
| `/mcp` | **MCP サーバ**。AI エージェントから読み書きする 15 のツール。管理 API への GraphQL クライアント |
| `/admin/audit.csv` `/admin/audit.jsonl` | **監査ログの書き出し**（owner だけ。GET。引数は `auditEvents` と同じ絞り込み、上限 100,000 件）。MCP と同じく管理 API への GraphQL クライアント |
| `/health` | DB に届けば `{"status":"ok","version":"<git の sha>"}`。接続プールが張り付いていれば 200 のまま `"status":"degraded"`、DB に届かないかワーカーが止まっていれば 503（[deploy/README.md](deploy/README.md)） |

管理画面は Elm で `admin-ui/`（別のビルド。`make ui-dev`）。CMS 本体は API だけを出す。
画面にあるのは、プロジェクト選択と組織（作成と、組織ごとのプロジェクトの一覧。組織そのものの画面はまだ無い）、API スキーマ（型とフィールド。消す前・締める前に当たるコンテンツの件数と見本を出す）、
コンテンツの一覧とボード、エディタ（TipTap v3。「+」の一覧は画像・区切り線・引用・囲み・折りたたみ・コード・表・数式・チェックリスト・埋め込みの 10 項目）、バージョン履歴と差分、メディア、メンバー、
API キーと PAT（GitHub と同じ「権限のチェックと有効期限」の形）、Webhook、監査ログ（絞り込みと CSV / JSON Lines の書き出し、行の固定 URL）、
API プレビュー、⌘K。画面の文言は [docs/design/admin-ui-spec.md](docs/design/admin-ui-spec.md) の 7.1 の表に揃え、`wording-check.mjs` が見張る。

管理 API と Account API は SDL が正で、そこから型付きの Flix コードを生成する。人が書くのは SDL と、生成されたレコード型に合わせたリゾルバだけで、**スキーマとリゾルバのズレはコンパイルで落ちる**。

`/p/{プロジェクト slug}/graphql` か Host（`CMS_BASE_DOMAIN`）でプロジェクトを選ぶ。省くと既定プロジェクト（`CMS_DEFAULT_PROJECT`）。

## 動かす

Flix コンパイラは flix_game_engine の devbox が持つ jar を借りる（`bin/flix` が解決する）。JDK と Docker が要る。

```bash
make db-up     # PostgreSQL と MinIO を docker compose で起動
make migrate   # migrations/ を当てる（初回と、migration を足した時）
make run       # サーバ起動（CMS_DSN 等は Makefile が渡す。初回は Maven 依存の取得で時間がかかる）
make query     # 起動中のサーバへ /health と管理 API・コンテンツ API のサンプルを投げる

make import-microcms      # import/microcms/schema/（microCMS の API スキーマ）を既定プロジェクトへ
make import-blog-example  # import/blog-example/schema/（blogs / authors / tags）を blog-example プロジェクトへ

make seed      # 手で触るためのテストデータを作り直す（demo / blog-example / empty-example。何度でも走らせられる）
```

`make seed`（`seed-demo` / `seed-blog-example` / `seed-empty` で 1 つずつ）は、対象のプロジェクトを
`scripts/reset-project.sh` で空にしてから取り込み直す。**取り込みのコードを直したら `make seed-demo` で当て直す**
（`make import-*` は作るだけなので、二度目は apiId の重複で落ちる）。消すのは取り込みが作る物だけで、
`default` と手で作ったプロジェクト、API キー・メンバー・監査ログには触らない。
管理画面の見本データ（`npm run seed`）はサーバを上げてから `cd admin-ui && CMS_PROJECT=demo npm run seed` で別に入れる。

取り込みはサーバを立てずに走る一発処理。`import/microcms/schema/` は実在の 9 型（relation / relationList / repeater / unsupported が揃っていて、取り込みの実力を測る材料）で、
作例サイト用の blogs / authors / tags は apiId が衝突するので `import/blog-example/` に分けて別プロジェクトに流す。

環境変数の一覧（認証、asset、CDN、仕事、自己回復、停止）は [deploy/README.md](deploy/README.md)。手元では `CMS_AUTH=dev` で `X-Dev-User` が使える（`CMS_VERSION=dev` の時だけで、その時は 127.0.0.1 にしか bind しない）。

### 型を作って entry を公開する

```bash
# 型とフィールド
curl -s -X POST localhost:8080/admin/graphql -H 'Content-Type: application/json' \
  -d '{"query": "mutation { createContentType(input: { apiId: \"blogs\", name: \"記事\" }) { id singular plural } }"}'
# {"data":{"createContentType":{"id":"1","plural":"blogs","singular":"Blog"}}}

curl -s -X POST localhost:8080/admin/graphql -H 'Content-Type: application/json' \
  -d '{"query": "mutation { addField(typeId: \"1\", input: { apiId: \"title\", name: \"題名\", kind: TEXT, required: true, config: { maxLength: 120 } }) { id position } }"}'

# entry（中身は JSON。型に無いフィールドや kind に合わない値は invalid）
curl -s -X POST localhost:8080/admin/graphql -H 'Content-Type: application/json' \
  -d '{"query": "mutation { createEntry(typeId: \"1\", fields: { title: \"Flix で GraphQL\" }) { id version fields } }"}'
# {"data":{"createEntry":{"fields":{"title":"Flix で GraphQL"},"id":"3f1c9a2b7d4e","version":1}}}

# 公開（required と unique と参照先を検査して公開側へ写し、版を積む）
curl -s -X POST localhost:8080/admin/graphql \
  -d '{"query": "mutation { publishEntry(id: \"3f1c9a2b7d4e\") { stage publishedAt versions { version reason } } }"}'
```

`updateEntry` は `expectedVersion` が今の version と違えば conflict（楽観ロック）。公開後に下書きを直すと `stage` が `CHANGED` になり、
再公開で反映する。`unpublishEntry` で取り下げ、`restoreVersion` で版から戻す。名前の規則（lowerCamel の apiId、予約名、他の型との衝突）に
合わない入力は `errors[].message` に理由が並ぶ。

**押す前に分かる / 壊れない**ための入口が 4 つある（前の 3 つは query）。

- `publishCheck(id)` — required / unique / 参照 / asset の違反と未公開の参照先を**全部一度に**返す（dry-run）
- `impact(id)` — 取り下げ・削除で壊れる entry（フィールドの参照・本文内のリンク・asset の使用先）
- `fieldImpact(input)` — 型を変える前の影響（dry-run）。フィールドを消す・締める（maxLength / min / max / integer / 選択肢）・型を消す・消した apiId で足し直す時に、下書きと公開中の件数と見本を返す。`safe` なら確認なしで押せる
- `publishPlan(ids, withDependencies)` / `publishMany` — 参照先が先の順に並べ、1 つでも通らなければ何も公開しない

**スキーマの破壊は見た物しか通らない。** `removeField` / `updateField` / `addField` / `deleteContentType` は、`fieldImpact` で見た影響を `expected` で渡す。
Tx の中でもう一度数え直し、見た時より影響の種類が増えるか公開中の件数が増えていれば止める（`expected` 無しで影響のある操作を押しても止まる）。
影響が空の操作は何も渡さずに通る。

`Entry.path` は、その entry がサイト上で持つ path（型の `linkPath` から作る。型紙が無い型は null）。本文からこの entry を指した時に出る href と同じ物で、
管理画面が「今どこを指しているか」を出すのに使う。

**版の残らない変更は監査ログに残る。** 型・フィールド・メンバー・招待・API キー・Webhook・asset・公開範囲と、entry の取り下げ・削除・予約公開の実行は、
業務の書き込みと同じ Tx で `audit_events` に 1 行積む（誰が・いつ・何を・どの対象に。消した物は変更前の姿を `detail.before` に持つ）。
失敗した操作は一緒に ROLLBACK されるので記録も残らない。表は RLS で append-only（SELECT と INSERT の policy しか無く、アプリも表の所有者も書き換えられない）。
主体は `actorKind`（USER / API_KEY / PAT / SYSTEM）と `actorId` で分け、secret と asset のファイル名は入れない（Webhook の URL は host と hash に落とす）。
entry の編集と手での公開を入れないのは `entry_versions` が版として全部持っているため。
読むのは管理 API の `auditEvents(first, after, actorKind, action, since, until)` と `auditEventsCount`（owner だけ。新しい順）、
書き出しは `GET /admin/audit.csv` / `audit.jsonl`（書き出した事も `audit.exported` として残る）。画面はプロジェクト設定 › 監査ログ。
詳しくは [docs/design/audit-log.md](docs/design/audit-log.md)。

### コンテンツ API で読む

```bash
curl -s -X POST localhost:8080/graphql -H 'Content-Type: application/json' \
  -d '{"query": "{ blogs(where: { title_contains: \"flix\", OR: [{ views_gte: 10 }] }, orderBy: [views_DESC], first: 10) { totalCount nodes { id title views } pageInfo { hasNextPage endCursor } } }"}'
curl -s -X POST localhost:8080/graphql -d '{"query": "{ blog(id: \"b1\", stage: DRAFT) { title updatedAt } }"}'
curl -s -X POST localhost:8080/graphql -d '{"query": "{ blog(slug: \"hello-flix\") { id title } }"}'
```

**1 件のクエリは `id` か `slug` のどちらか 1 つで引く。** `slug` の引数が生えるのは、**unique な SLUG のフィールドを 1 つだけ持つ型**だけ
（下書きでは同じ slug が並びうるので、1 件に決まる型に限る）。どちらも渡さない・両方渡す・同じ slug の entry が 2 件以上見つかった、は
`INVALID`（下書きの重複を null で隠さない）。`id` は `slug` と選べるように `ID!` から `ID` になった。ワイヤ互換だが、
introspection から型を作るクライアント（graphql-codegen）では `id` が optional に緩むので、生成した型を作り直すこと。

`where` はフィールドの kind ごとに `_eq` / `_in` / `_contains` / `_startsWith`（文字列）、`_eq` / `_gt` / `_gte` / `_lt` / `_lte`（数値と DATE）、
`_eq`（真偽値）、`_eq` / `_in`（select）、`_id_eq` / `_id_in`（reference）、配列には `_contains`、全部に `_isNull` が生え、`OR` / `AND` は 1 段。
値は全部プレースホルダで SQL に渡す。一覧は `first` / `skip` に加えて `after`（cursor）で辿れる（[docs/design/pagination.md](docs/design/pagination.md)）。
**`skip` は 10000 まで**で、それより後ろは `after` に前のページの `endCursor` を渡す（`OFFSET 50000` が 99.9 ms だったため。`after` と `skip` は同時に渡せない）。

`REFERENCE` は参照先の型として展開され、同じ stage の物を返す（一覧は 1 本の SELECT で先読み）。`SELECT` は型ごとの enum（`BlogCategory`）で、
`many: true` なら複数選択。`DATE` は ISO 8601 の文字列。

`RICH_TEXT` は `RichText { json html markdown text assets headings links excerpt(length) wordCount readingTimeMinutes }` で返る。
`json` は ProseMirror の doc、`html` はその描画（見出しに id、表・callout・details・embed・linkCard・数式・Mermaid は class ではなく `data-*`）、`headings` は目次用。
**数式（TeX）と Mermaid は CMS が描かない**（中身をそのまま持って出す）ので、描くのはサイト側。
doc は入口で深さ 20 / ノード 10000 を超えると `Violation` で断る（JSON のパーサに任せると「どの field のどこが」を返せないため）。

```bash
curl -s -X POST localhost:8080/graphql \
  -d '{"query": "{ blogs { body { html links { id apiId path } headings { level text id } } } }"}'
curl -s -X POST localhost:8080/graphql \
  -d '{"query": "{ blogs { body { markdown assets { id url width height alt } } } }"}'
```

**`markdown` は CMS の方言を含む。** 画像は `![alt](asset:ID)`、表のセルの結合は中身の後ろの `{colspan=2 rowspan=3}`（GFM に結合の書き方が無いので、`{#id}` / `{width=W height=H}` と同じ `{key=value}` に揃えた。`colspan=1` は書かない）、
コンテンツへのリンクは `entry:ID` のまま出る（URL に焼き込まない。
焼き込むと Markdown から doc に戻せず往復が壊れる）。**画像は `assets`、entry のリンクは `links` で解く**（どちらも本文 1 つにつき 1 本の SELECT で、
`markdown` と同じ 1 往復で取れる）。解決済みの物が要るなら `html` を読む。

**本文のコンテンツへのリンクは、CMS が path まで作る。** 型に**パスの形**（`ContentType.linkPath`。`/blog/{slug}` のような型紙で、
使える印は `{id}` と `{slug}` の 2 つ。`{slug}` は値が無ければ id に落ちる）を入れておくと、`html` の `<a href>` がそのまま踏める path になり、
`links[].path` にも同じ物が出る。型紙が無い型は href が `#entry:{id}` のままで、サイトが置き換える。
**`data-entry-id` は型紙のあるなしに関わらず必ず付く**ので、`json` を自分で描くサイトも `links` から id → path を引ける。
型紙は `/` か `http(s)://` で始まる物だけを受ける（`//evil.example.com/` は scheme 相対なので弾く）。
本文の自由なリンクは `http(s)://` の他に **`/about` のような相対パスと `#section` の断片**を受ける（`//` と `/\` は別ホストとして読まれるので弾き、`javascript:` / `vbscript:` / `data:` は大文字小文字を問わず弾く）。
外に出るリンクにだけ `target="_blank"` が付く（同じサイトの中のリンクまで別タブにすると読む人の戻る道が切れるため）。

匿名の GET はプロジェクトの版から weak な ETag を組み、`If-None-Match` が合えば GraphQL を実行せず 304 を返す。

### 認証

ヘッダで渡す。`Authorization: Bearer <JWT>`（OIDC の JWKS で検証）、`Authorization: Bearer cmspat_...`（PAT）、`X-Api-Key`（プロジェクトの鍵）、`X-Preview-Token`（その entry の下書きだけ）。
役割は owner ⊃ editor ⊃ writer ⊃ viewer で、判定は Datalog。public なプロジェクトのコンテンツ API は鍵無しで公開中を読める。
詳しくは [docs/architecture/auth.md](docs/architecture/auth.md)。

## アーキテクチャ

### SDL が正、Flix コードは生成物

生成器 `schemagen/` は別プロジェクト（Flix + graphql-java のパーサ）。本体と分けているのは、生成物が壊れていると本体がコンパイルできず、
コンパイルできないと生成し直せない、という循環を避けるため。生成物には SDL と生成器バージョンの SHA-256 が埋まり、テストと起動時に SDL と照合する。

生成物の中身は `src/graphql/Schema.flix` の型付き DSL（`Schema.fieldRaw` / `Out` / `GqlCodec` / `objectType`）で、人が直接書くこともできる（コンテンツ API はそうしている）。
素通しのフィールドには既定リゾルバ `<型名>Defaults()` が生成されるので、手書きのリゾルバは写しが要る物だけをレコードの更新で上書きする。

```
admin.graphql ──(make generate / schemagen)──▶ src/generated/graphql/ ──▶ Schema（Field / ObjectType / Out）
                                                       ▲                          │
                                          src/admin/ のリゾルバ          Graphql.buildEngine ──▶ graphql-java
```

コンテンツ API だけは逆で、**型の定義（DB の行）から実行時に Schema を組む**（`ContentSchemaBuilder`）。プロジェクトの版が変われば組み直す。

### 境界は代数的 effect

- `eff Graphql` — ルーティング（`Server`）は graphql-java を知らない。テストは偽ハンドラに差し替える
- `eff Tenant` — 今のプロジェクト。ユースケースは読み書きを全部そこに閉じる
- `eff Session` — 認証済みユーザー。handler を入れるのは `DbRunner.transact` だけ
- `eff Log` / `eff Observe` — 構造化ログ（`src/log/` は cms / http に依存しない独立したライブラリ）
- `eff ObjectStore` — asset の置き先。MinIO と R2 を同じ handler で

Java のオブジェクトはリゾルバに出さない。スカラーと引数は JSON 相当の enum `Value`、オブジェクト型の値は `JavaValue.Boxed` で不透明に箱詰めして往復させる。

### 守り方を型と機構に落とす

- **権限は証明で運ぶ** — DB に触るユースケースは `Granted[ManageTypes]` のような証明を最初の引数で受け、自分では判定しない。作り忘れは引数不足でコンパイルが落ちる
- **テナントは三重** — 型（`Tenant` effect）、生成器（`make gen --scope project_id` が条件の無い query を通さない）、DB（RLS。印の無い Tx は 0 行。`entry_contents` も含めた 8 表）
- **Tx の入口は 3 つだけ** — `scripts/check-tx.sh` が allowlist の増減を見張る（業務の外で 1 本だけ繋ぐ起動時の確認 / ロール作成 / `/health` / 自己回復は理由付きで allowlist）。読むだけの文書は 1 リクエスト 1 Tx、mutation はルートフィールドごと
- **Session / Tenant / CmsErr の handler と `Granted` の組み立ては 3 ファイルだけ** — `scripts/check-handlers.sh`。Flix は非 pub の enum も pub eff も他の mod から隠せないので、型の代わりに見張りで守る
- **スキーマの破壊は Tx の中で数え直す** — `SchemaGuard.withImpact`。`fieldImpact` で見た影響（`expected`）と食い違えば CmsErr で止め、`DbRunner.transact` が戻す
- **1 リクエストの SQL と Tx の数に上限** — `test/Pg/TestQueryBudgetPg`
- **ログのキーの一覧** — `scripts/check-log-keys.sh`

### 仕事と運用

配信と予約公開は outbox（業務の Tx で行を積み、tick が `FOR UPDATE SKIP LOCKED` で拾う。複数台でも二重にならない）。
プロセス内のワーカーが 2 秒ごとに回復・掃除 → 予約公開 → Webhook → CDN の purge を回す。
SIGTERM は listen を閉じる → 接続を待つ → 仕事を drain → プールを閉じるの順、接続プールが壊れたまま戻らなければ自分で exit 3（`SelfHeal`）。
ログは 1 行 1 JSON（[docs/logging.md](docs/logging.md)）。

## 開発

```bash
make check     # 型検査（+ tx / handler の allowlist と log キーの検査）
make test      # DB 無しのテスト（test/Pg を除いた写しを build/unit/ に作って回す）
make test-pg   # 実 PostgreSQL と MinIO 込み（コンテナの起動と停止まで）
make generate  # admin.graphql / account.graphql → src/generated/graphql/
make gen       # migrations/ + queries/*.q → src/generated/sql/（sqlfx の生成器）
make fatjar    # 実行可能な jar（artifact/）

make ui-gen    # admin.graphql / account.graphql → admin-ui/generated/（elm-graphql）
make ui-dev    # 管理画面の dev サーバ（CMS は別のターミナルで make run）
make ui-check  # 文言の見張り（wording-check.mjs）・手組みの見張り（editor-check.mjs）・elm-format の検査・
               # elm-review・elm-test・tsc・エディタの検査（Vitest のブラウザモード 414 件）
```

エディタの検査は **`admin-ui/dev/`** の開発用の画面（`dev/editor.html`。CMS のサーバも DB もログインも要らず、手元からしか開けない）と
同じ初期状態（`dev/fixtures.ts`）を使い、裸の chromium で打鍵して doc と座標を読む。Playwright の通し実行は 2026-09-12 に無くした。
`editor-check.mjs` は「部品を使わずに帯や浮く面を手組みする」印（`getBoundingClientRect` / `offsetHeight` / `style.top` など）を数え、
`scripts/editor-check-allow.json` の件数より増えた時だけ落ちる。

`bin/flix` は `--Xsubeffecting=lambdas` を付けて呼ぶ（純粋なリゾルバのラムダをそのまま effect 付きの関数型に置くため）。
VS Code の Flix 拡張にも同じフラグが要り、`.vscode/settings.json` の `flix.extraFlixArgs` で渡している。
CI は push ごとに `make check` と `make test-pg`（`test.yml`）。`admin-ui/` と SDL を触ると `admin-ui.yml` が動き、
SDL と生成物のずれ・`ui-check`・build・本番のビルドに dev のヘッダが混ざっていない事を見る。

テストの方針は**純粋な物はテストファースト**。`src/cms/rules`、`src/cms/db` の SQL 化、`src/crypto`、`src/http/Router` のような入出力が決まる物は、
実装の前に表（入力 → 期待）を書いて通す。実 PG と GraphQL は後付けで、機能ごとに 1 回「繋ぎ目を伸ばす」観点を入れる。

### 落とし穴

- **リゾルバのラムダに effect を使う式を直に書かない**（JVM の VerifyError。関数に切り出す）。型検査もスキーマの組み立ても素通りし、そのフィールドを選ぶ query でだけ出る
- **graphql-java 22 の good-faith introspection**: 1 つのクエリに `__type` や `__schema` を複数並べると data が null になる。introspection は 1 つずつ投げる
- **`Net.Http.runWithIO` を src/ で使わない**（handler ごとに HttpClient を作りスレッドが残る）

## ディレクトリ

```
admin.graphql / account.graphql   管理 API / Account API の SDL（正）
migrations/ queries/*.q           DDL と SQL（sqlfx の生成器の元）
schemagen/                        SDL → Flix の生成器（別プロジェクト）
src/generated/                    生成物（触らない）
src/cms/                          ドメイン。model / rules / db とユースケース
src/admin/ src/content/ src/account/   各 API のリゾルバと Runner
src/graphql/                      graphql-java の境界と Schema の DSL
src/app/                          AppEnv・認証・ルート表・DbRunner・仕事・ログ・/health・停止
src/mcp/ src/import/              MCP サーバ、microCMS からの取り込み
src/http/ src/log/ src/crypto/ src/auth/ src/storage/
admin-ui/                         管理画面（Elm 0.19.2 + Vite。src/ が画面、web/ が TipTap v3 の Web Component、
                                  dev/ が開発用の画面とエディタの検査）
import/microcms/ import/blog-example/   取り込み用の API スキーマ（実在の 9 型 / 作例サイト用）
deploy/                           本番とセルフホスト（compose + Caddy / Alloy）
test/                             src と同じ構成。test/Pg/ だけ実 PG
```

## 読む先

| 何を知りたいか | どこ |
|---|---|
| 動かす・環境変数・監視 | [deploy/README.md](deploy/README.md) |
| ドメイン・型・テナント | [docs/architecture/domain.md](docs/architecture/domain.md) |
| API 層・リゾルバ・MCP | [docs/architecture/api.md](docs/architecture/api.md) |
| Tx・仕事・ログ・停止 | [docs/architecture/runtime.md](docs/architecture/runtime.md) |
| 認証と権限 | [docs/architecture/auth.md](docs/architecture/auth.md) |
| 管理画面の仕様 | [docs/design/admin-ui-spec.md](docs/design/admin-ui-spec.md) |
| これから作る物 | [docs/design/roadmap.md](docs/design/roadmap.md) |
| 直近の決めと未解決 | [docs/design/2026-09-12-handover.md](docs/design/2026-09-12-handover.md) |
| Flix の書き方 | [docs/flix-conventions.md](docs/flix-conventions.md) |
| コードの流儀 | [AGENTS.md](AGENTS.md) |
