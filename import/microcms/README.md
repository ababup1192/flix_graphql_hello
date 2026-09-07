# microCMS からの取り込み

- `schema/<API 名>.json`: 管理画面の「API 設定」→「API スキーマ」→「エクスポート」で取った JSON をそのまま置く
- `contents/<API 名>.json`: コンテンツ一覧（`GET /api/v1/<API 名>?limit=100` の応答）。まだ読まない（今はダミーの entry を作る）。git には入れない

`make db-up && make migrate && make import-microcms` で既定プロジェクトに型を写し、各 API に 3 件（`CMS_IMPORT_COUNT`）のダミー entry を作って公開する。

写し方: text → TEXT、textArea → TEXT_AREA、richEditor → RICH_TEXT、media → ASSET、boolean → BOOLEAN、number → NUMBER、
relation → REFERENCE、relationList → REFERENCE の配列、repeater → BLOCKS（customFieldIds が variant、custom の fields が子）。
エンドポイント名は lowerCamel の apiId に（`insidesales-category` → `insidesalesCategory`）。複数形でない名前は一覧のクエリ名が `<apiId>List` になる。
custom field と同名の子フィールドは `<名前>Value` に改名する。
