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
DB 層は sqlfx（github:ababup1192/sqlfx）を `flix.toml` の `[dependencies]` で取る。PostgreSQL は docker compose。

```bash
make check     # 型検査
make test      # DB 無しのテスト（test/Pg を除く）
make test-pg   # 実 PostgreSQL 込み（コンテナの起動と停止まで）
make db-up     # PostgreSQL を起動
make migrate   # migrations/ を当てる
make run       # サーバ起動（CMS_DSN 等は Makefile が渡す）
make generate  # admin.graphql → src/generated/graphql/、schema.graphql（見本）→ test/sample/（schemagen）
make gen       # migrations/ + queries/*.q → src/generated/sql/（sqlfx の生成器。flix_db 側で動く）
```

実 PG が要るテストは `test/Pg/` に置く。`make test` はそれを除いた写しを `build/unit/` に作って回す。

## ディレクトリ

```
admin.graphql          管理 API の SDL（正）
schema.graphql         見本の SDL
migrations/            DDL。sqlfx の机上スキーマの元で、make migrate が当てる
queries/*.q            SQL
src/generated/graphql/ schemagen の生成物（触らない）。GeneratedSchema / GeneratedAdminSchema
src/generated/sql/     sqlfx の生成物（触らない）。*Queries / Tables
src/cms/model/         ドメインの型。Ids（TypeId / FieldId / ApiId / TypeName）、ContentType（enum・レコード・Draft / Changes・FieldConfig）、Entry（EntryId / Stage / EntryData / IdGen）
src/cms/rules/         純粋な規則。Naming（予約名・衝突・kind と config）、EntryValidation（下書きは緩く、公開は required まで）、EntryLinks（中身から参照を取り出す）
src/cms/db/            行とドメインの値の変換と、絞り込みの SQL 化（EntryFilterSql）。列名と JSONB の式を知るのはここだけ
src/cms/               ユースケース（ContentTypes / ContentEntries / Projects）と業務エラー（CmsErr）、今のプロジェクト（Tenant effect）
src/admin/             管理 API。AdminMapping（GraphQL の型 ↔ ドメイン）、リゾルバ、AdminRunner（最初の SQL で借りる Tx）、AdminEngine（プロジェクトごとのエンジン）
src/content/           コンテンツ API。ContentSchemaBuilder（定義 → Schema）、ContentEngine（目印で組み直す置き場）、ContentRunner（読むだけ）
src/app/               Server（ルーティング・CORS・/health）、DbConfig、Health
src/http/              手書き HTTP/1.1 と Cors
src/graphql/           graphql-java の境界と Schema の DSL
test/                  src と同じ構成。test/Pg/ だけ実 PG
test/sample/           graphql-java の境界のテストで使う見本のスキーマ（schema.graphql → GeneratedSchema.flix、Post / Counter）。本番では使わない
```

## プロジェクト（テナント）

1 つの DB に複数のプロジェクト（型と entry の集まり）を持つ。パスの先頭 `/p/{slug}/` で選び、無ければ既定（id 1 / `default`）。
ユースケースは `Tenant.current()`（algebraic effect）で今のプロジェクトを読み、読み書きを全部そこに閉じる。
Runner がリクエストごとに handler を入れ、テストは `PgTestSupport` が既定のプロジェクトで入れる。他のプロジェクトの id を渡しても notFound。

## 型の決まり

- id はプリミティブで持ち回らない。`TypeId` / `FieldId`（Int64 を包む）、`EntryId`（文字列。parse 済み）で、GraphQL の `Id` との写しは admin 層だけ
- 識別子は `ApiId`（lowerCamel）と `TypeName`（UpperCamel）で、`parse` を通した物しか作らない。規則外の文字列は境界で invalid になる
- ドメイン（src/cms）は GeneratedAdmin を知らない。enum と入力レコードはドメインが自分で持ち、写しは `AdminMapping`
- entry の中身は `EntryData = Map[ApiId, Json]`。GraphQL の `JSON` scalar（`Value`）との往復も `AdminMapping`
