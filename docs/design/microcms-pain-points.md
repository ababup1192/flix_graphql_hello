# microCMS の負（管理画面の計画の入力）

microCMS を日常で使ってきた人が挙げた不満。管理画面の計画は、これを 1 つずつ「うちではこうする」で潰す。
追記していく（2026-09-07 開始）。

| 負 | 何が困るか | うちでの向き |
|---|---|---|
| プランで使えない機能が画面に disabled で並ぶ | 触るたびに「上位プランへ」でイラつく | 使えない機能は出さない。セルフホストは全機能。hosted の差は容量と席数だけにする |
| 検索が弱い | entry を探すのに時間が掛かる | 全文検索（タイトルと本文の平文）、フィールドごとの絞り込み、保存したビュー。API の `where` と同じ物を画面が使う |
| サイドバーが畳めず、横長のテーブルを見渡せない | 列の多い型で一覧が使い物にならない | サイドバーの折り畳み、列の表示 / 非表示と幅の記憶、テーブルとボードの切り替え（Jira / GitHub Projects） |
| コンテンツを区切る仕切りが無く、ダミーの entry で線を作っている。グルーピングも無い | 型の中で entry を整理できない | フォルダかタグかステータスでグルーピング。区切り線はダミーで作らせない（保存したビューと並び替えで代替） |
| 残り文字数が視覚的に分かりづらい | 上限を超えてから気づく | X の文字数の見せ方（円のゲージ、残り少なくなると色が変わり、超えた分をハイライト）。上限はフィールドの設定（Naming の config）に持つ |
| 画像の大きさの数値指定が直感的でない | 幅や高さを数字で入れても結果が想像できない | プレビュー付きのリサイズ、プリセット（サムネイル / 本文 / OGP）、`?w=` の URL パラメータを画面で組み立てて見せる |
| 本文の中で画像を横に並べられない。繰り返しフィールドで記事の外に組むしかない | 「ここだけ 2 枚横に」が本文の流れで書けない。記事の構造がフィールドに漏れる | richText の doc に gallery（container node、attrs.columns 2〜4、中は image だけ）。HTML は `data-gallery`、Markdown は 1 行に画像を並べたら gallery、エディタは画像を画像の横にドロップ。Gutenberg / Ghost / Medium と同じ定番（2026-09-08） |
| リンクカードやアフィリエイトカードをカスタムフィールドで持ち、本文が分断される | 本文の流れの中に置けない | richText の doc に linkCard（url だけ持つ。OGP はサイト側か将来の asset の仕事）。Markdown は URL だけの行で embed にならない物 |
| 画像に alt を持てず、別のフィールドで alt を持つ | アクセシビリティと SEO のために alt を別管理する手間 | image の attrs.alt。公開時に alt 必須にできる config。Markdown は `![alt](asset:ID "caption")` |
| コードブロックにファイル名と行のハイライトが無い | 直前の段落に書くしかない | codeBlock の attrs.fileName / highlightLines。Markdown は ```` ```ts:src/a.ts {1,3-5} ```` |
| 脚注が無い | 末尾に手書き | footnote mark。Markdown は `[^1]`（gallery などの後で） |
| 文字色・寄せ・カスタムクラスがあり、本文にスタイルが混ざる | サイトの見た目と食い違う。移行で消える | 出さない（決め）。強調は mark、区別は callout。表のセル結合も入れない |
| 折りたたみ（Notion のトグル、GitHub の details）が無い | 長いログや補足を畳めない。エンジニアの記事で定番 | richText の doc に details（attrs.summary、中は何でも）。HTML は `<details><summary>`、Markdown は GitHub でそのまま畳める `<details>` の形（Zenn の `:::details` は GitHub で出ないので採らない） |
| 数式と Mermaid の図が書けない | 技術記事で必須。画像に焼くしかない | `math` mark と `mathBlock` node（Markdown は `$…$` `$$…$$`）。codeBlock の language が mermaid なら HTML は `data-diagram`。描画は KaTeX / Mermaid をサイト側で |
| タスクリストが無い | 手順や進捗を本文に書けない | listItem の attrs.checked。Markdown は `- [ ]` `- [x]` |
| 動画を直接置けない（oEmbed だけ） | 短い動画のために YouTube に上げる | `video` node（assetId、caption、poster）。AssetRules に mime ごとの上限（動画は大きめ）。容量はプランの枠に乗る。変換はしない。長い物は embed に |
| 画像の拡大表示が無い | 小さい画像を読めない | バックエンドは width / height を持っているので無し。サイト側の lightbox |
| 本文に別の entry を差し込めない（参照はフィールドの外側だけ） | 記事カードや共通の注意書きを本文に置けない | `entryEmbed` node（entryId）。impact と参照展開に乗せる。差分と MCP の後に単独で計画 |
