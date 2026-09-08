# 一覧の cursor ページネーション（2026-09-09）

コンテンツ API の `<plural>` と管理 API の `entries` / `assets` を、offset（`first` / `skip`）に加えて cursor（`after`）でも辿れるようにした。ロードマップの 16c。

## 決めた事

- **形は GitHub の GraphQL API と同じ。** `nodes` と `edges { cursor node }` の両方、`pageInfo { hasNextPage endCursor }`、`totalCount`。素の fetch や Elm は `nodes` + `pageInfo`、Apollo / urql / Relay は `edges` を使う。`first` / `skip` / `totalCount` は消さない（管理画面の「N ページ目へ」と件数表示は offset の方が向く）
- **cursor の中身は、並び順のキーの値（並び順と同じ順）+ id を JSON にして base64url にした物。** クライアントは中を読まず、`endCursor` をそのまま次の `after` に渡す。`orderBy` と対で意味を持つので、cursor には (キー, 向き) も入れて復号の時に突き合わせる。並び順を変えて古い cursor を渡すと INVALID（`after: cursor が orderBy と合いません`）、壊れた文字列も INVALID（`after: cursor が壊れています`）
- **`after` と `skip` は同時に渡せない**（INVALID）。`skip: 0` は既定値なので「指定なし」と見る
- **続きの条件は行の比較ではなく OR の展開。** DESC は `<`、ASC は `>`、同じ値なら次のキー、最後は `id >`。PG の行の比較 `(a, b) < ($1, $2)` は NULL の組で unknown になり、NULL を末尾に置いた並びと合わないため。NULL を取りうるキー（`publishedAt` と JSONB のフィールド）は、並び（`ORDER BY`）も比較も NULL を末尾に固定する（DESC は `(式 IS NULL) ASC` を前に置く。断片 DSL に `NULLS LAST` が無いため）。cursor の値が NULL なら「NULL の行の id の先」だけ
- **cursor の id がその型の entry でなければ 0 件。** 他のプロジェクトの cursor を渡しても位置として効かない（`EXISTS` の副問い合わせ。SQL の本数は増えない）。ゴミ箱の entry は除かない: ページの末尾の entry を消した直後に次のページが 0 件になり、全件を舐める途中で切れるため
- **`webhookDeliveries` / `schedules` の cursor は id そのもの**（ULID で時刻順）。`after: ID` に前のページの最後の id を渡す
- **MCP の `search_entries`** は `after` を受け、`next_cursor`（次が無ければ null）を返す。管理 API の cursor をそのまま通す
- **管理 API の `entries` の `where` / `orderBy`** は SDL が固定なので、コンテンツ API の型ごとの `<Singular>Where` とは形が違う: `where: { stage, id_in, fields: [{ apiId, op, value }] }`、`orderBy: [{ field, direction }]`。意味（Condition / SortKey）はコンテンツ API と同じ物で、写しは `AdminMapping.entryWhere` / `entryOrderBy`。フィールドで絞る・並べる時だけ型の定義を 1 回引く（kind で式が決まる）
- **migration は無し。** 既定の並び（更新順）の keyset は `(type_id, updated_at)` の索引に乗る。JSONB のフィールドの並びは元から索引に乗っていないので、cursor 化で速くも遅くもならない

## 見張るテスト

- 純粋: `test/cms/model/TestCursor`（往復・壊れた物・不一致・同時指定）、`TestEntryFilterSql`（`afterClause` の SQL と NULL の向き）、`TestEntryPage`（`trimPage`）、`test/admin/TestAdminMapping`（where / orderBy の写し）
- 実 PG: `test/Pg/TestCursorPg`（3 ページ辿って重複なし、途中で 1 件足しても崩れない、JSONB の orderBy、他のプロジェクトの cursor は 0 件、INVALID）、`TestAdminCursorPg`（管理 API の where / orderBy / after、assets、ULID の一覧）、`TestMcpPg`（2 ページ）、`TestCdnCachePg`（`after` の違いが ETag に出る）、`TestQueryBudgetPg`（SQL の本数が増えない）
