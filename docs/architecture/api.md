# API 層（GraphQL の境界、admin / content / account / mcp / import）

読むタイミング: リゾルバやスキーマを触る時、SDL を変えて `make generate` する時、一覧の N+1 や先読みに関わる時、MCP のツールを足す時。

## src/graphql/ — graphql-java の境界と Schema の DSL

`Context` はリクエスト単位の値（`actor` / `log` / `observe` / `preload`）で全リゾルバに届く。`preload` は先読みの写しの Ref（`Option`。読むだけの文書にだけ Main が `Context.withPreload` で付け、mutation を含む文書は無し）。

**リゾルバのラムダに effect を使う式を直に書かない**（JVM の VerifyError。関数に切り出す）。型検査もスキーマの組み立ても素通りし、そのフィールドを選ぶ query でだけ出る。見張るのは `test/admin/TestApiSurface.flix`（型とフィールドの一覧）と、全フィールドを選ぶ Pg テスト。本文は [../flix-conventions.md](../flix-conventions.md)。

## src/generated/graphql/ — schemagen の生成物（触らない）

GeneratedAdminSchema / GeneratedAccountSchema。素通しのフィールド（引数が無く、スカラーか enum かそのリストを返す）は既定リゾルバ `<型名>Defaults()` を生成するので、手書きのリゾルバは写しが要る物だけをレコードの更新で上書きする（書き方は [../flix-conventions.md](../flix-conventions.md)）。

正は `admin.graphql`（管理 API の SDL）と `account.graphql`（Account API の SDL）。`schema.graphql` は見本で、`make generate` が `test/sample/` に出す。

## src/admin/ — 管理 API

AdminMapping（GraphQL の型 ↔ ドメイン）、リゾルバ、AdminRunner（`AppEnv.runWith` → `Preloaded.runWith(context#preload)` → `DbRunner.transactObserved(…, context#actor, f)` → `toFieldResult`。認証はしない）、AdminEngine（プロジェクトごとのエンジン）。

一覧の N+1 は先読みの写し（Context の preload）で塞ぐ: `Query.entries` がページの entry id を覚え（SQL 無し）、`Entry.versions` は最初の行でページ分を `ContentEntries.versionsOf` の 1 本で引いて写しに入れ、`Entry.diff` は source の entry と写しの型（`ContentTypes.get` を 1 回）で `ContentEntries.diffOf`。数は `test/Pg/TestQueryBudgetPg` が見張る。

## src/content/ — コンテンツ API

ContentSchemaBuilder（定義 → Schema。reference の参照先は `ContentEntries.listByStage` / `findByStage` が同じ stage で 1 本先読みした `Entry.linked` から返し、無い物（2 段目以降）だけ 1 件ずつ引く）、ContentEngine（目印で組み直す置き場）、ContentRunner（読むだけ。Runner の形は Admin と同じ。先読みの写しは使わない）。

一覧は `first` / `skip` に加えて `after`（cursor）で辿れ、`<Singular>Connection` は `nodes` / `edges { cursor node }` / `pageInfo { hasNextPage endCursor }` / `totalCount`（GitHub の形）。管理 API の `entries` も同じ意味の `where` / `orderBy` / `after` を持つ（写しは AdminMapping）。システムの日時（`createdAt` / `updatedAt` / `publishedAt`）は entries の列なので、JSONB でなく列で比べる（管理 API は `where: { updatedAt: { gte: ... } }`、コンテンツ API は `updatedAt_gte`）。

`skip` には上限がある（`Cursor.maxSkip()` = 10000）。OFFSET は飛ばす行も全部読むので、entry 11 万件で OFFSET 10000 が 37ms、50000 が 100ms になる（同じ位置を cursor で引けば 9ms）。超えると `skip` の違反で断り、`after` へ誘導する。管理画面の一覧は 1 ページ 50 件なので 200 ページ目まで届く。

## src/account/ — Account API

`/account/graphql`。プロジェクトを選ぶ前の操作: me / 組織 / プロジェクト作成 / 組織のメンバー。Runner は Tenant を入れない。

## src/mcp/ — MCP サーバ v1

`POST /mcp`。legacy = MCP 2025-06-18 の形。initialize / ping / tools/list / tools/call だけ（modern は v2）。McpServer（JSON-RPC の parse / dispatch / initialize / error の形。純粋）、McpTools（ツール定義の表 `tools()`。tools/list の inputSchema と引数の復号を同じ定義から出す。引数 → admin.graphql の query + variables、data → content の写し、richText の Markdown / text / html の写し。search_entries は `after` を受けて `next_cursor` を返す）。

管理 API のエンジンへの GraphQL クライアントで、ユースケースは直に呼ばない。HTTP との繋ぎ（Origin の 403、401、202）は Server.flix の mcpRoute。

## src/import/ — microCMS からの取り込み

MicrocmsSchema（API スキーマの export を読む。純粋）、MicrocmsImport（型に写し、ダミーの entry を積む）、MicrocmsCli（CMS_MODE=import-microcms の一発処理）。

## test/sample/ — 境界のテストで使う見本のスキーマ

`schema.graphql`（見本の SDL）→ `GeneratedSchema.flix`。Post / Counter。graphql-java の境界のテストだけで使い、本番では使わない。

## 写しの決まり

GraphQL の `ID` は連番でなく乱数の public_id。内部の id に戻すのは AdminMapping / AccountMapping だけ。
