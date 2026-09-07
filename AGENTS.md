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
make image     # Docker イメージ（手元用。CI は ghcr.io に amd64 / arm64）
```

本番と セルフホストは `deploy/`（docker compose + Caddy / Alloy の例、README）。イメージは起動時に migrations/ を当てる（`CMS_MIGRATE=apply`）。
ログは 1 行 1 JSON、`/health` に `version`（git の sha）が出る。

実 PG が要るテストは `test/Pg/` に置く。`make test` はそれを除いた写しを `build/unit/` に作って回す。

## ディレクトリ

```
admin.graphql          管理 API の SDL（正）
account.graphql        Account API の SDL（正）
schema.graphql         見本の SDL
migrations/            DDL。sqlfx の机上スキーマの元で、make migrate が当てる
queries/*.q            SQL
src/generated/graphql/ schemagen の生成物（触らない）。GeneratedAdminSchema / GeneratedAccountSchema
src/generated/sql/     sqlfx の生成物（触らない）。*Queries / Tables
src/cms/model/         ドメインの型。Auth（UserId / OrgId / Role / Permission / Actor / ApiKeyScope / Visibility）、Ids（TypeId / FieldId / ApiId / TypeName）、ContentType（enum・レコード・Draft / Changes・FieldConfig）、Entry（EntryId / Stage / EntryData / IdGen）、Asset（AssetId / AssetStatus / Upload）
src/cms/rules/         純粋な規則。Authz（役割 → 権限の Datalog。`can` は resource も受ける）、Naming（予約名・衝突・kind と config）、EntryValidation（下書きは緩く、公開は required まで）、EntryLinks（中身から参照を取り出す）、AssetRules（置いてよい mime と大きさ）、RichText（doc の検査・平文・HTML）、AssetRefs（中身から asset を取り出す）
src/cms/db/            行とドメインの値の変換と、絞り込みの SQL 化（EntryFilterSql）。列名と JSONB の式を知るのはここだけ
src/cms/               ユースケース（ContentTypes / ContentEntries / Projects / Assets / Accounts / Members / ApiKeys）と業務エラー（CmsErr）、今のプロジェクト（Tenant effect）、今の主体（Session effect。`Session.require(permission)` が既定拒否の入口）
src/account/           Account API（/account/graphql。プロジェクトを選ぶ前の操作: me / 組織 / プロジェクト作成 / 組織のメンバー）。Runner は Tenant を入れない
src/admin/             管理 API。AdminMapping（GraphQL の型 ↔ ドメイン）、リゾルバ、AdminRunner（最初の SQL で借りる Tx）、AdminEngine（プロジェクトごとのエンジン）
src/content/           コンテンツ API。ContentSchemaBuilder（定義 → Schema）、ContentEngine（目印で組み直す置き場）、ContentRunner（読むだけ）
src/app/               Server（ルーティング・CORS・/health・Host の slug）、DbConfig（所有者とアプリ用ロール）、TenantTx（RLS の印付き Tx）、AppRole（cms_app の作成）、StorageConfig（ASSET_*。無ければ asset 無し）、AuthConfig（CMS_AUTH=jwks|dev|none）、Deps、Health
src/auth/              JWT の検証（RS256 固定。kid / iss / aud / exp / nbf）と TokenVerifier effect（JWKS の取得とキャッシュ）
src/storage/           asset の置き先。SigV4（純粋な署名）、ObjectStore effect（署名付き URL / HEAD / DELETE。MinIO と R2 は同じ handler）
src/http/              手書き HTTP/1.1 と Cors
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

身元は `Credential`（Bearer / ApiKey / Missing / Invalid）として graphql 層の Context に入り、Runner が Tx の中で `Actor` に解決して `Session` に入れる。
ユースケースは `Session.require(Permission)` で守り、判定は `Authz.can`（Datalog）。役割は owner ⊃ editor ⊃ writer ⊃ viewer、組織 owner はプロジェクト owner。
公開 API は public なら鍵無しで公開中を読め、`stage: DRAFT` は readDraft、private は API キー（`X-Api-Key`）か役割が要る。
最初の owner は `CMS_BOOTSTRAP_OWNER` の初回ログイン。dev 認証（`X-Dev-User`）は `CMS_VERSION=dev` の時だけで、その時は 127.0.0.1 にしか bind しない。
テナント分離は三重: 型（Tenant effect）、生成器（`make gen` の `--scope project_id`。project_id 列の表を触る query に条件が無ければ止まる。跨ぐ物は `// unscoped: 理由`）、DB（RLS。Runner が `TenantTx.withLazyTx` で Tx の先頭に印を置く。印の無い Tx は中身の表が 0 行）。
DB の Tx は `DbRunner.transact`（Runner とテストの mutate）を通す。業務エラー（CmsErr）のような再開しない effect を `withLazyTx` の外で受けると COMMIT / ROLLBACK と接続の返却が飛び、接続が漏れる（TestTxLeakPg が見張る）。
GraphQL の `ID` は連番でなく乱数の public_id。内部の id に戻すのは AdminMapping / AccountMapping だけ。
設計と決めた事は [docs/design/auth-and-organizations.md](docs/design/auth-and-organizations.md)。環境変数の一覧は `deploy/README.md`。

## 型の決まり

- id はプリミティブで持ち回らない。`TypeId` / `FieldId`（Int64 を包む）、`EntryId`（文字列。parse 済み）で、GraphQL の `Id` との写しは admin 層だけ
- 識別子は `ApiId`（lowerCamel）、`TypeName`（UpperCamel）、`ProjectSlug`（DNS のラベル）で、`parse` を通した物しか作らない。規則外の文字列は境界で invalid になる
- ドメイン（src/cms）は GeneratedAdmin を知らない。enum と入力レコードはドメインが自分で持ち、写しは `AdminMapping`
- entry の中身は `EntryData = Map[ApiId, Json]`。GraphQL の `JSON` scalar（`Value`）との往復も `AdminMapping`
