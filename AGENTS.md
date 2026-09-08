# flix_graphql_hello

Flix から graphql-java（Java の GraphQL ライブラリ）を Java interop で叩けるか試す
最小プロジェクト。ゲームエンジン（flix_game_engine）の Flix のお約束だけを持ち込んでいる。

## 会話ポリシー

日本語で会話してください。途中報告なども含めて、日本語で回答してください。

単語は業界の言葉をそのまま使う（カタカナ・英語のまま。和語へ言い換えない・造語を作らない）。
説明は平易に書く。独自の比喩で名付けない。

## Flix のお約束

- **Flix を書く前・テストを書く前に `/flix-docs` を引く**（本文は `.claude/skills/flix-docs/SKILL.md`）
- **コンパイルエラーが出たら `/compile-fix`**（本文は `.claude/skills/compile-fix/SKILL.md`）
- 予約語・コメントの流儀・型の設計・二乗を書かない、の本文: [docs/flix-conventions.md](docs/flix-conventions.md)
- **GraphQL のリゾルバのラムダに effect を使う式を直に書かない**（JVM の VerifyError。関数に切り出す）。型検査もスキーマの組み立ても素通りし、そのフィールドを選ぶ query でだけ出る。見張るのは `test/admin/TestApiSurface.flix`（型とフィールドの一覧）と、全フィールドを選ぶ Pg テスト。本文は [docs/flix-conventions.md](docs/flix-conventions.md)

## テストの進め方

- **純粋な物はテストファースト。** `src/cms/rules`、`src/cms/db` の SQL 化、`src/crypto`、`src/http/Router` のような入出力が決まる物は、実装の前にテスト計画（入力 → 期待の表、往復、境界）を書き、表駆動の `List#{(入力, 期待)}` で通していく。`make test` は DB 無しで回る
- **実 PG と GraphQL は後付けで良い。** schema と Runner を組んでからでないとテストの形が決まらない。代わりに機能ごとに 1 回「繋ぎ目を伸ばす」（操作の列を最後の状態まで追う、outbox の行を見る、接続が返るか）観点を入れる
- テストの書き方の決まり（1 assert、分岐しない、表駆動、コメントは What）は `.claude/skills/flix-docs/SKILL.md`

## コーディングポリシー

コードには **How** / テストコードには **What** / コミットログには **Why** / コードコメントには **WhyNot**

特にコードコメントは WhyNot を重視し、How・What を書かない。実装の由来や旧実装などの歴史背景も書かない。

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

MCP サーバ（`POST /mcp`）は `claude mcp add --transport http cms http://127.0.0.1:8080/mcp --header "X-Api-Key: …"` で繋ぐ（手順は `deploy/README.md`）。

本番と セルフホストは `deploy/`（docker compose + Caddy / Alloy の例、README）。イメージは起動時に migrations/ を当てる（`CMS_MIGRATE=apply`）。
ログは 1 行 1 JSON、`/health` に `version`（git の sha）が出る。

実 PG が要るテストは `test/Pg/` に置く。`make test` はそれを除いた写しを `build/unit/` に作って回す。
CI（`.github/workflows/test.yml`）は push ごとに `make check` と `make test-pg` を回す。Flix のコンパイラは release の jar を `FLIX_JAR` で `bin/flix` に渡す。
Webhook の受け手の見本は `scripts/webhook-receiver.py`（署名の照合）。

## ディレクトリ

```
admin.graphql          管理 API の SDL（正）
account.graphql        Account API の SDL（正）
schema.graphql         見本の SDL
migrations/            DDL。sqlfx の机上スキーマの元で、make migrate が当てる
queries/*.q            SQL
src/generated/graphql/ schemagen の生成物（触らない）。GeneratedAdminSchema / GeneratedAccountSchema。素通しのフィールド（引数が無く、スカラーか enum かそのリストを返す）は既定リゾルバ `<型名>Defaults()` を生成するので、手書きのリゾルバは写しが要る物だけをレコードの更新で上書きする（書き方は [docs/flix-conventions.md](docs/flix-conventions.md)）
src/generated/sql/     sqlfx の生成物（触らない）。*Queries / Tables
src/cms/model/         ドメインの型。Auth（UserId / OrgId / Role / Permission / Actor / ApiKeyScope / Visibility）、Webhook（WebhookEvent / DeliveryStatus / Webhook / WebhookDelivery）、Schedule（ScheduleAction / ScheduleStatus / Schedule）、Ulid（配信記録など時刻順の記録の id）、Ids（TypeId / FieldId / ApiId / TypeName）、ContentType（enum・レコード・Draft / Changes・FieldConfig）、Entry（EntryId / Stage / EntryData / IdGen）、Asset（AssetId / AssetStatus / Upload）
src/cms/rules/         純粋な規則。Authz（役割 → 権限の Datalog。`can` は resource も受ける。read の PAT は viewer に落ちる）、SecretHash（API キー・PAT・プレビュートークンの pepper 付き hash と寿命）、Naming（予約名・衝突・kind と config）、EntryValidation（下書きは緩く、公開は required まで）、EntryLinks（中身から参照を取り出す）、AssetRules（置いてよい mime と大きさ）、RichText（doc の検査・平文・HTML）、Markdown（richText の doc ↔ Markdown。方言は GFM + alerts / `{#id}` / `asset:` / `entry:`。自前のパーサで依存なし）、AssetRefs（中身から asset を取り出す）、EntryDiff（2 つのバージョンの中身の差分。kind ごとの比べ方、many は位置、OBJECT / BLOCKS は再帰、RICH_TEXT は Markdown の行差分 LCS。管理 API の `Entry.diff` の中身）
src/cms/db/            行とドメインの値の変換（EntryRows / ContentTypeRows / AssetRows / AuthRows / WebhookRows / ScheduleRows）と、絞り込みの SQL 化（EntryFilterSql）。列名と JSONB の式を知るのはここだけ
src/cms/               ユースケース（ContentTypes / ContentEntries / Projects / Assets / Accounts / Members / ApiKeys / PersonalTokens / Webhooks / PreviewTokens / Schedules。Webhooks.emit は公開などと同じ Tx に配信行を積む outbox。PersonalTokens は本人に付く PAT で Tenant を取らない）と業務エラー（CmsErr）、今のプロジェクト（Tenant effect）、今の主体（Session effect。`Session.require(permission)` が既定拒否の入口、`Session.currentUser()` が書く人の入口）
src/account/           Account API（/account/graphql。プロジェクトを選ぶ前の操作: me / 組織 / プロジェクト作成 / 組織のメンバー）。Runner は Tenant を入れない
src/admin/             管理 API。AdminMapping（GraphQL の型 ↔ ドメイン）、リゾルバ、AdminRunner（最初の SQL で借りる Tx）、AdminEngine（プロジェクトごとのエンジン）
src/content/           コンテンツ API。ContentSchemaBuilder（定義 → Schema）、ContentEngine（目印で組み直す置き場）、ContentRunner（読むだけ）
src/app/               Server（ルート表 `Server.routes`。1 行 = メソッド・パス・engine・handler。`/p/{projectSlug}/` は `Router.withProjectPrefix` が複製。行を足したら TestServer の describe の一覧にも 1 行。/health・Host のプロジェクト slug の middleware `wrapProjectFromHost`。Main は表の engine を見てエンジンを入れる）、Credentials（ヘッダ → Credential。PAT / JWT / X-Api-Key / X-Preview-Token の順。`Credentials.wrap` が middleware）、RequestId（`X-Request-Id` を受けるか捨てるか（64 字・`[A-Za-z0-9_-]`）、無ければ ULID、`RequestId.wrap` が応答ヘッダで返す middleware）、LogFields（CMS の値 → Log.Fields。request の span、credential.kind、応答の行と重さ、graphql.*、CmsFailure → error.code / entity / id。キーは [docs/logging.md](docs/logging.md)、`scripts/check-log-keys.sh` が見張る）、DbConfig（所有者とアプリ用ロール。`withTimeouts` が JDBC の URL に pgjdbc の `options` で idle_in_transaction_session_timeout / statement_timeout / lock_timeout を付ける。CMS_DB_TIMEOUT_SECONDS、既定 30、0 で無効）、TenantTx（RLS の印付き Tx）、AppRole（cms_app の作成）、BackgroundJobs（プロセス内のバックグラウンドワーカー。2 秒ごとに回復・掃除 → Scheduler.tick → WebhookDispatcher.tick。外部トリガー POST /jobs/tick も同じ tick）、Scheduler（予約公開の実行）、WebhookDispatcher（配信行を拾って POST）、JobLog（仕事 1 件の Log の行。job.kind / job.id / job.outcome）、DbRunner（Tx と業務エラー。transact / toFieldResult。DB の失敗は Error の行と INTERNAL の requestId）、GraphqlErrors（業務エラー → errors[].extensions の code / violations / entity / id / 版。分類を決めるのはここだけ。[docs/design/error-codes.md](docs/design/error-codes.md)）、RequestIdentity（Credential → Actor。API キーと PAT の hash 解決、死んだ PAT は理由付きで断る、last_used_at）、StorageConfig（ASSET_*。無ければ asset 無し）、AuthConfig（CMS_AUTH=jwks|dev|none）、Deps（storage / auth / log。log は Runner がリゾルバの中で Log を入れ直す sink。graphql-java の Java コールバックの中なので dispatch の handler は届かない）、Health（/health と /jobs/tick が読む関数のレコード `Health[ef]`。本番は `ofPool`、テストは `HealthFake.ok()` / `failing`。ログと時計は持たず、Route は `Log` と `Time.Clock` の effect を持つ。テストは `ServerTestKit.quietly` で捨てる）。Main が Sink を組み（CMS_LOG_LEVEL → service / version → JSON）、dispatch が request id と span を張ってリクエストの行を出す（[docs/logging.md](docs/logging.md)）
src/import/            microCMS からの取り込み。MicrocmsSchema（API スキーマの export を読む。純粋）、MicrocmsImport（型に写し、ダミーの entry を積む）、MicrocmsCli（CMS_MODE=import-microcms の一発処理）
src/mcp/               MCP サーバ v1（POST /mcp。legacy = MCP 2025-06-18 の形。initialize / ping / tools/list / tools/call だけ。modern は v2）。McpServer（JSON-RPC の parse / dispatch / initialize / error の形。純粋）、McpTools（ツール定義の表 `tools()`。tools/list の inputSchema と引数の復号を同じ定義から出す。引数 → admin.graphql の query + variables、data → content の写し、richText の Markdown / text / html の写し）。管理 API のエンジンへの GraphQL クライアントで、ユースケースは直に呼ばない。HTTP との繋ぎ（Origin の 403、401、202）は Server.flix の mcpRoute
src/log/               構造化ログのライブラリ（logfx の元。cms / http / app に依存しない）。`eff Log`（emit）、Severity、Fields（Map[String, Value]。ビルダーは `Log.Fields`）、Record、Sink（`Record -> Unit \ IO`。合成は `Log.Sink` の json / minSeverity / enrich / collect）、withFields（span。内側が勝つ）、runWith（スレッドの入口。sink の例外は捨てる）、runWithList（テスト）、exception（Java の例外 → exception.type / message / stacktrace）、toJsonLine（time / severity / message を先頭に名前順、ms 固定の ISO 8601、制御文字を落とす）。HttpServer は Log を知らず `Served` の値を `listen` の onServed に渡す
src/crypto/            Sha256（sha256 / HMAC / 16 進）と Base64Url。署名と鍵のハッシュが共通で使う。ドメインは storage や auth に依存しない
src/auth/              JWT の検証（RS256 固定。kid / iss / aud / exp / nbf）と TokenVerifier effect（JWKS の取得とキャッシュ）
src/storage/           asset の置き先。SigV4（純粋な署名）、ObjectStore effect（署名付き URL / HEAD / DELETE。MinIO と R2 は同じ handler）
src/http/              手書き HTTP/1.1（接続ごとのスレッドは Throwable で受けて 500。OutOfMemoryError だけ再送出）、Router（純粋なルート表。Method / Pattern / Route / Match、`find` は上から当てて 405 の Allow を表の順で出す）、Cors（`Cors.wrap` が preflight と 404 / 503 込みの CORS ヘッダ。Allow-Methods は表から）、JvmErrors（スレッドの境界で受けた Throwable の扱い。`isFatal` は VirtualMachineError から StackOverflowError を除いた物、`describe` は message か class 名）
src/graphql/           graphql-java の境界と Schema の DSL
test/                  src と同じ構成。test/Pg/ だけ実 PG
test/sample/           graphql-java の境界のテストで使う見本のスキーマ（schema.graphql → GeneratedSchema.flix、Post / Counter）。本番では使わない
```

## プロジェクト（テナント）

1 つの DB に複数のプロジェクト（型と entry の集まり）を持つ。パスの先頭 `/p/{プロジェクト slug}/` か Host（`CMS_BASE_DOMAIN`）で選び、無ければ既定プロジェクト（`CMS_DEFAULT_PROJECT`。既定 `default`、空なら 404）。
言葉: **プロジェクト slug**（`ProjectSlug`。URL 用の人が読める名前）と **プロジェクト id**（主キー）を混ぜない。裸の「slug」とは呼ばない。
ユースケースは `Tenant.current()`（algebraic effect）で今のプロジェクトを読み、読み書きを全部そこに閉じる。
Runner がリクエストごとに handler を入れ、テストは `PgTestSupport` が既定のプロジェクトで入れる。他のプロジェクトの id を渡しても notFound。

## 認証と権限

身元は `Credential`（Bearer / ApiKey / PersonalToken / Preview / Missing / Invalid）として graphql 層の Context に入り、Runner が Tx の中で `Actor` に解決して `Session` に入れる。
API キーは `scope: WRITE` + `role` で管理 API の mutation を役割の範囲で叩ける（メンバー・鍵・プロジェクトの管理は鍵では不可。`expiresAt` で期限、`lastUsedAt` は管理 API の使用だけ 1 分粒度で記録）。
Personal Access Token（PAT。`Authorization: Bearer cmspat_...`、Account API の `createPersonalAccessToken`）は本人の役割で動く。人の主体は `Actor.User(id, email, roles, Login)` で、`Login` がログインの JWT（Interactive）か PAT（scope 付き）かを持つ。READ の PAT は `Authz` が viewer に落とし、書く入口 `Session.currentUser()` は拒む（自分を読む物は `currentUserForRead()`）。API キーと PAT の発行は `Session.requireInteractive()`（ログインの JWT だけ。PAT や鍵からは作れない）。死んだ PAT は `PatRejection` で Runner が「認証に失敗しました」と断る。表 personal_access_tokens の RLS は本人の印と `app.token_hash` の印（解決の時だけその 1 行）。
ユースケースは `Session.require(Permission)` で守り、判定は `Authz.can`（Datalog）。src/cms の pub で DB に触る物は Session を持つ。持たない物（写し・outbox・Runner が主体を決める前の認証の解決）は `scripts/session-allowlist.txt` に列挙し、`make check` の `scripts/check-session.sh` が増減を見張る。役割は owner ⊃ editor ⊃ writer ⊃ viewer、組織 owner はプロジェクト owner。
公開 API は public なら鍵無しで公開中を読め、`stage: DRAFT` は readDraft、private は API キー（`X-Api-Key`）か役割が要る。
プレビュートークン（`X-Preview-Token`。`Actor.Preview(entryId)`）はその entry と参照先の下書きだけ読める。判定は `Authz.can` の resource（entryId）。
最初の owner は `CMS_BOOTSTRAP_OWNER` の初回ログイン。dev 認証（`X-Dev-User`）は `CMS_VERSION=dev` の時だけで、その時は 127.0.0.1 にしか bind しない。
テナント分離は三重: 型（Tenant effect）、生成器（`make gen` の `--scope project_id`。project_id 列の表を触る query に条件が無ければ止まる。跨ぐ物は `// unscoped: 理由`）、DB（RLS。Runner が `TenantTx.withLazyTx` で Tx の先頭に印を置く。印の無い Tx は中身の表が 0 行）。
仕事の表（webhook_deliveries / scheduled_actions）は outbox: 業務の Tx で積み、tick が `FOR UPDATE SKIP LOCKED` で拾う（複数台でも二重にならない）。実行中に落ちた行は claimed_at で回復する。
DB の Tx は `DbRunner.transact`（Runner とテストの mutate）を通す。業務エラー（CmsErr）のような再開しない effect を `withLazyTx` の外で受けると COMMIT / ROLLBACK と接続の返却が飛び、接続が漏れる（TestTxLeakPg が見張る）。
GraphQL の `ID` は連番でなく乱数の public_id。内部の id に戻すのは AdminMapping / AccountMapping だけ。
設計と決めた事は [docs/design/auth-and-organizations.md](docs/design/auth-and-organizations.md)。環境変数の一覧は `deploy/README.md`。

## 型の決まり

- id はプリミティブで持ち回らない。`TypeId` / `FieldId`（Int64 を包む）、`EntryId`（文字列。parse 済み）で、GraphQL の `Id` との写しは admin 層だけ
- 識別子は `ApiId`（lowerCamel）、`TypeName`（UpperCamel）、`ProjectSlug`（DNS のラベル）で、`parse` を通した物しか作らない。規則外の文字列は境界で invalid になる
- ドメイン（src/cms）は GeneratedAdmin を知らない。enum と入力レコードはドメインが自分で持ち、写しは `AdminMapping`
- 外向きの id: 連番は出さない。組織や鍵は乱数の public_id、配信記録のように時刻順に読む物は ULID（作成時刻が読めるので鍵や組織には使わない）
- entry の中身は `EntryData = Map[ApiId, Json]`。GraphQL の `JSON` scalar（`Value`）との往復も `AdminMapping`
- `FieldKind` は TEXT / TEXT_AREA / SLUG / NUMBER / BOOLEAN / SELECT / REFERENCE / OBJECT / BLOCKS / ASSET / RICH_TEXT / DATE。kind を足す時は ContentType（enum）・ContentTypeRows（DB の文字列）・migrations（CHECK）・Naming・EntryValidation・ContentSchemaBuilder・admin.graphql（`make generate`）・AdminMapping・MicrocmsSchema / MicrocmsImport の全部を触る
- DATE の値は ISO 8601 の文字列。日付だけ（"2026-09-08"）は書く時に `EntryValidation.normalize` が UTC の 0 時に揃える（規則は `DateValues`）。絞り込みと並び替えは `EntryFilterSql` が timestamptz にして比べる
- SELECT は `many: true` で複数選択（値は選択肢の配列。コンテンツ API では `[Enum!]!` と `_contains`）
