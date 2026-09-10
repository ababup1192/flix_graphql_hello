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
| `/health` | DB に届けば `{"status":"ok","version":"<git の sha>"}`。接続プールが張り付いていれば 200 のまま `"status":"degraded"`、DB に届かないかワーカーが止まっていれば 503（[deploy/README.md](deploy/README.md)） |

管理画面は Elm で `admin-ui/`（別のビルド。`make ui-dev`）。CMS 本体は API だけを出す。

管理 API と Account API は SDL が正で、そこから型付きの Flix コードを生成する。人が書くのは SDL と、生成されたレコード型に合わせたリゾルバだけで、**スキーマとリゾルバのズレはコンパイルで落ちる**。

`/p/{プロジェクト slug}/graphql` か Host（`CMS_BASE_DOMAIN`）でプロジェクトを選ぶ。省くと既定プロジェクト（`CMS_DEFAULT_PROJECT`）。

## 動かす

Flix コンパイラは flix_game_engine の devbox が持つ jar を借りる（`bin/flix` が解決する）。JDK と Docker が要る。

```bash
make db-up     # PostgreSQL と MinIO を docker compose で起動
make migrate   # migrations/ を当てる（初回と、migration を足した時）
make run       # サーバ起動（CMS_DSN 等は Makefile が渡す。初回は Maven 依存の取得で時間がかかる）
make query     # 起動中のサーバへ /health と管理 API・コンテンツ API のサンプルを投げる
```

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

**押す前に分かる / 壊れない**ための入口が 3 つある（前の 2 つは query）。

- `publishCheck(id)` — required / unique / 参照 / asset の違反と未公開の参照先を**全部一度に**返す（dry-run）
- `impact(id)` — 取り下げ・削除で壊れる entry（フィールドの参照・本文内のリンク・asset の使用先）
- `publishPlan(ids, withDependencies)` / `publishMany` — 参照先が先の順に並べ、1 つでも通らなければ何も公開しない

`Entry.path` は、その entry がサイト上で持つ path（型の `linkPath` から作る。型紙が無い型は null）。本文からこの entry を指した時に出る href と同じ物で、
管理画面が「今どこを指しているか」を出すのに使う。

### コンテンツ API で読む

```bash
curl -s -X POST localhost:8080/graphql -H 'Content-Type: application/json' \
  -d '{"query": "{ blogs(where: { title_contains: \"flix\", OR: [{ views_gte: 10 }] }, orderBy: [views_DESC], first: 10) { totalCount nodes { id title views } pageInfo { hasNextPage endCursor } } }"}'
curl -s -X POST localhost:8080/graphql -d '{"query": "{ blog(id: \"b1\", stage: DRAFT) { title updatedAt } }"}'
```

`where` はフィールドの kind ごとに `_eq` / `_in` / `_contains` / `_startsWith`（文字列）、`_eq` / `_gt` / `_gte` / `_lt` / `_lte`（数値と DATE）、
`_eq`（真偽値）、`_eq` / `_in`（select）、`_id_eq` / `_id_in`（reference）、配列には `_contains`、全部に `_isNull` が生え、`OR` / `AND` は 1 段。
値は全部プレースホルダで SQL に渡す。一覧は `first` / `skip` に加えて `after`（cursor）で辿れる（[docs/design/pagination.md](docs/design/pagination.md)）。

`REFERENCE` は参照先の型として展開され、同じ stage の物を返す（一覧は 1 本の SELECT で先読み）。`SELECT` は型ごとの enum（`BlogCategory`）で、
`many: true` なら複数選択。`DATE` は ISO 8601 の文字列。

`RICH_TEXT` は `RichText { json html text headings links excerpt(length) wordCount readingTimeMinutes }` で返る。
`json` は ProseMirror の doc、`html` はその描画（見出しに id、表・callout・gallery・数式・Mermaid は class ではなく `data-*`）、`headings` は目次用。

```bash
curl -s -X POST localhost:8080/graphql \
  -d '{"query": "{ blogs { body { html links { id apiId path } headings { level text id } } } }"}'
```

**本文のコンテンツへのリンクは、CMS が path まで作る。** 型に**パスの形**（`ContentType.linkPath`。`/blog/{slug}` のような型紙で、
使える印は `{id}` と `{slug}` の 2 つ。`{slug}` は値が無ければ id に落ちる）を入れておくと、`html` の `<a href>` がそのまま踏める path になり、
`links[].path` にも同じ物が出る。型紙が無い型は href が `#entry:{id}` のままで、サイトが置き換える。
**`data-entry-id` は型紙のあるなしに関わらず必ず付く**ので、`json` を自分で描くサイトも `links` から id → path を引ける。
型紙は `/` か `http(s)://` で始まる物だけを受ける（`//evil.example.com/` は scheme 相対なので弾く）。

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
- **テナントは三重** — 型（`Tenant` effect）、生成器（`make gen --scope project_id` が条件の無い query を通さない）、DB（RLS。印の無い Tx は 0 行）
- **Tx の入口は 3 つだけ** — `scripts/check-tx.sh` が allowlist の増減を見張る。読むだけの文書は 1 リクエスト 1 Tx、mutation はルートフィールドごと
- **1 リクエストの SQL と Tx の数に上限** — `test/Pg/TestQueryBudgetPg`
- **ログのキーの一覧** — `scripts/check-log-keys.sh`

### 仕事と運用

配信と予約公開は outbox（業務の Tx で行を積み、tick が `FOR UPDATE SKIP LOCKED` で拾う。複数台でも二重にならない）。
プロセス内のワーカーが 2 秒ごとに回復・掃除 → 予約公開 → Webhook → CDN の purge を回す。
SIGTERM は listen を閉じる → 接続を待つ → 仕事を drain → プールを閉じるの順、接続プールが壊れたまま戻らなければ自分で exit 3（`SelfHeal`）。
ログは 1 行 1 JSON（[docs/logging.md](docs/logging.md)）。

## 開発

```bash
make check     # 型検査（+ tx allowlist と log キーの検査）
make test      # DB 無しのテスト（test/Pg を除いた写しを build/unit/ に作って回す）
make test-pg   # 実 PostgreSQL と MinIO 込み（コンテナの起動と停止まで）
make generate  # admin.graphql / account.graphql → src/generated/graphql/
make gen       # migrations/ + queries/*.q → src/generated/sql/（sqlfx の生成器）
make fatjar    # 実行可能な jar（artifact/）

make ui-gen    # admin.graphql / account.graphql → admin-ui/generated/（elm-graphql）
make ui-dev    # 管理画面の dev サーバ（CMS は別のターミナルで make run）
make ui-check  # elm-format の検査・elm-review・elm-test・tsc
```

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
admin-ui/                         管理画面（Elm + Vite。src/ が画面、web/ が TipTap の Web Component）
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
| Flix の書き方 | [docs/flix-conventions.md](docs/flix-conventions.md) |
| コードの流儀 | [AGENTS.md](AGENTS.md) |
