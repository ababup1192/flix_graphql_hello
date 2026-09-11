# flix_graphql_hello

Flix から graphql-java（Java の GraphQL ライブラリ）を Java interop で叩けるか試す
最小プロジェクト。ゲームエンジン（flix_game_engine）の Flix のお約束だけを持ち込んでいる。

このファイルは**毎回読まれる索引**なので、置くのは「破ると事故る決まり」と「どこを見るか」だけ。
仕組みの説明は `docs/architecture/` に書く。

## 会話ポリシー

日本語で会話してください。途中報告なども含めて、日本語で回答してください。

単語は業界の言葉をそのまま使う（カタカナ・英語のまま。和語へ言い換えない・造語を作らない）。
説明は平易に書く。独自の比喩で名付けない。

## Flix のお約束

- **Flix を書く前・テストを書く前に `/flix-docs` を引く**（本文は `.claude/skills/flix-docs/SKILL.md`）
- **コンパイルエラーが出たら `/compile-fix`**（本文は `.claude/skills/compile-fix/SKILL.md`）
- 予約語・コメントの流儀・型の設計・二乗を書かない、の本文: [docs/flix-conventions.md](docs/flix-conventions.md)
- **GraphQL のリゾルバのラムダに effect を使う式を直に書かない**（JVM の VerifyError。関数に切り出す）。型検査もスキーマの組み立ても素通りし、そのフィールドを選ぶ query でだけ出る。見張るのは `test/admin/TestApiSurface.flix` と、全フィールドを選ぶ Pg テスト

## テストの進め方

- **純粋な物はテストファースト。** `src/cms/rules`、`src/cms/db` の SQL 化、`src/crypto`、`src/http/Router` のような入出力が決まる物は、実装の前にテスト計画（入力 → 期待の表、往復、境界）を書き、表駆動の `List#{(入力, 期待)}` で通していく。`make test` は DB 無しで回る
- **実 PG と GraphQL は後付けで良い。** schema と Runner を組んでからでないとテストの形が決まらない。代わりに機能ごとに 1 回「繋ぎ目を伸ばす」（操作の列を最後の状態まで追う、outbox の行を見る、接続が返るか）観点を入れる
- テストの書き方の決まり（1 assert、分岐しない、表駆動、コメントは What）は `.claude/skills/flix-docs/SKILL.md`
- 実 PG が要るテストは `test/Pg/` に置く。`make test` はそれを除いた写しを `build/unit/` に作って回す

## コーディングポリシー

コードには **How** / テストコードには **What** / コミットログには **Why** / コードコメントには **WhyNot**

特にコードコメントは WhyNot を重視し、How・What を書かない。実装の由来や旧実装などの歴史背景も書かない。

エントリポイント（Main の起動、runRoute、BackgroundJobs.tick、Authentication.resolve）と重要なワークフローだけは例外で、塊ごとに「ここで何をしているか」の短い What コメントを置き、環境変数を読む・依存を組む・エンジンを作る・listen する、のような意味の単位で関数を分ける。ユースケースや規則には広げない。

## ビルドと実行

Flix コンパイラは flix_game_engine の devbox が持つ jar を借りる（`bin/flix` が解決する）。
DB 層は sqlfx（github:ababup1192/sqlfx）を `flix.toml` の `[dependencies]` で取る。PostgreSQL と MinIO（asset の置き先。本番は R2）は docker compose。

```bash
make check     # 型検査
make test      # DB 無しのテスト（test/Pg を除く）
make test-pg   # 実 PostgreSQL と MinIO 込み（コンテナの起動と停止まで）
make db-up     # PostgreSQL と MinIO を起動
make migrate   # migrations/ を当てる
make run       # サーバ起動（CMS_DSN 等は Makefile が渡す）
make generate  # admin.graphql / account.graphql → src/generated/graphql/、schema.graphql（見本）→ test/sample/（schemagen）
make gen       # migrations/ + queries/*.q → src/generated/sql/（sqlfx の生成器。flix_db 側で動く）
make fatjar    # 実行可能な jar（artifact/）
make import-microcms  # import/microcms/schema/*.json（microCMS の API スキーマ）を既定プロジェクトに写し、ダミーの entry を積んで公開
make image     # Docker イメージ（手元用。CI は ghcr.io に amd64 / arm64）
```

CI（`.github/workflows/test.yml`）は push ごとに `make check` と `make test-pg` を回す。Flix のコンパイラは release の jar を `FLIX_JAR` で `bin/flix` に渡す。
MCP サーバ（`POST /mcp`）の繋ぎ方、本番とセルフホスト（docker compose + Caddy / Alloy）、環境変数の一覧は `deploy/README.md`。

手元の道具: `scripts/webhook-receiver.py`（Webhook の受け手の見本。署名の照合）、`scripts/mcp-trial/`（MCP の試用の手順と 13 シチュエーションのプロンプト）。

## ディレクトリ

| 場所 | 中身 |
|---|---|
| `admin.graphql` / `account.graphql` | 管理 API / Account API の SDL（正）。`schema.graphql` は見本 |
| `migrations/` | DDL。sqlfx の机上スキーマの元で、`make migrate` が当てる |
| `queries/*.q` | SQL |
| `src/generated/` | schemagen と sqlfx の生成物（**触らない**） |
| `src/cms/` | ドメイン。`model/` 型、`rules/` 純粋な規則、`db/` 行 ↔ 値と SQL 化、直下がユースケース |
| `src/admin/` `src/content/` `src/account/` | 管理 API / コンテンツ API / Account API のリゾルバと Runner |
| `src/graphql/` | graphql-java の境界と Schema の DSL。`Context` がリクエスト単位の値 |
| `src/app/` | AppEnv・認証・ルート表・DbRunner・仕事・ログ・/health・停止と自己回復 |
| `src/mcp/` | MCP サーバ v1（`POST /mcp`） |
| `src/import/` | microCMS からの取り込み |
| `src/http/` | 手書き HTTP/1.1、Router、Cors、OutboundHttp |
| `src/log/` | 構造化ログのライブラリ（logfx の元。cms / http / app に依存しない） |
| `src/crypto/` `src/auth/` `src/storage/` | Sha256 / Base64Url、JWT 検証、asset の置き先 |
| `test/` | src と同じ構成。`test/Pg/` だけ実 PG、`test/sample/` は境界のテスト用の見本スキーマ |

詳しくは:

| 文書 | 読むタイミング |
|---|---|
| [docs/architecture/domain.md](docs/architecture/domain.md) | `src/cms/` を触る、型（FieldKind）や id を変える、テナントの境界に関わる |
| [docs/architecture/api.md](docs/architecture/api.md) | リゾルバ・スキーマ・SDL を触る、一覧の N+1 や先読み、MCP のツール |
| [docs/architecture/runtime.md](docs/architecture/runtime.md) | Tx・接続・再試行、ルートを足す、仕事、ログ、/health、停止と自己回復 |
| [docs/architecture/auth.md](docs/architecture/auth.md) | 認証の道、権限の判定、API キー / PAT / プレビュートークン |

## 破ると事故る決まり

- **Tx の入口は `DbRunner` の 3 つだけ**（`transact` / `withTx` / `withRequestTx`）。接続や Tx を自分で開いて良いのは `scripts/tx-allowlist.txt` のファイルだけ（業務の外で 1 本だけ繋ぐ物は理由付きで載せる）で、`scripts/check-tx.sh` が見張る。破ると接続が漏れる
- **業務エラー（CmsErr）を値に潰すのは Tx の境界とテストキットだけ。** 途中で潰すと失敗が Tx の中で握り潰される
- **Session の handler を入れるのは `DbRunner.transact` だけ。** ユースケースは `Granted[p]` を引数で受け、自分では権限を判定しない。Session / Tenant / CmsErr の handler と `Granted` の組み立ては `scripts/handler-allowlist.txt` の 3 ファイルだけで、`scripts/check-handlers.sh` が見張る（Flix は非 pub の enum も pub eff も他の mod から隠せない）
- **スキーマを壊す mutation は `SchemaGuard.withImpact` を通す。** `fieldImpact` で見た `expected` を Tx の中で数え直し、食い違えば止める。操作の種類で除外を書かない（影響が空なら通る）
- **認証はリクエストに 1 回**（`Main.runRoute`）。Runner とリゾルバは認証をしない
- **テナントは三重で守る**（Tenant effect / `make gen --scope project_id` / RLS）。跨ぐ query は `// unscoped: 理由`
- **ルート表に行を足したら `TestServer` の describe にも 1 行**
- **`Net.Http.runWithIO` を src/ で使わない**（handler ごとに HttpClient を作りスレッドが残る）。`OutboundHttp.runWith`
- **外向きの id に連番を出さない**（乱数の public_id、時刻順に読む物は ULID）
- **監査（`Audit.record`）は業務の書き込みと同じ Tx で呼ぶ。** `audit_events` は SELECT と INSERT の policy しか無く、後から書き換えられない
- **ドメイン（src/cms）は GeneratedAdmin を知らない。** 写しは `AdminMapping` / `AccountMapping`
- **ライブラリを新しく入れる時は最新版を入れる**（`npm install -D foo@latest` のように明示し、入れた後に `npm outdated` で確かめる）。記憶で版を書かない。実際に `vitest@^3` と書いて入れた日に最新は 5 で、provider の渡し方が変わっていた
