# 管理画面の仕様（決めた事）

作成: 2026-09-09。計画（モノレポの形、画面の一覧、技術）は `~/Desktop/cms-admin-ui-plan.md`。本書はその上で決めた仕様と、CMS 側に要る変更。
負の表は [microcms-pain-points.md](microcms-pain-points.md)。

## 0. 3 つの決め（2026-09-09）

| 論点 | 決め |
|---|---|
| 本文（richText）の構造 | エディタは **メジャーな node から作り始め**、負の表の node は重さを見ながら順に埋める。doc の形は CMS が既に持つ物（`RichText` のホワイトリスト）を正とし、`docs/design/richtext-doc.md` に写す |
| ワークフロー | 下書き / 公開の 2 段のままにせず、**プロジェクトごとに決めるステータス**を持つ（Jira / GitHub Projects の流れ）。一覧はテーブルとボードの両方 |
| 編集の競合 | リアルタイム共同編集はしない。**版の楽観ロック（`expectedVersion` → `CONFLICT`）+ 誰が開いているかの表示** |

## 1. richText のエディタの段階

doc の node は CMS のホワイトリストが正（知らない node は INVALID）。エディタは TipTap で、段階ごとに対応する node を増やす。**未対応の node が doc に入っていても壊さない**（TipTap の unknown node は保持して素通しする extension を最初から入れる。CMS が受けた doc を管理画面が削る事が無いように）。

| 段階 | node / mark | 備考 |
|---|---|---|
| 1（最初） | paragraph / heading(level 1〜4, id) / bulletList / orderedList / listItem(checked) / blockquote / codeBlock(language, fileName, highlightLines) / hardBreak / horizontalRule / image(assetId, alt, caption, width, height)。mark: bold / italic / strike / underline / code / link(href \| entryId) | TipTap の StarterKit + Image + Link + TaskItem で届く範囲。image は asset の選択 / ドロップ |
| 2 | table / tableRow / tableCell / tableHeader / callout(kind) / details(summary) / embed(url) / linkCard(url) | 負の表の「本文が分断される」「折りたたみ」 |
| 3 | gallery(columns 2〜4) / video(assetId, caption, poster) / mathBlock(tex) / mark: math | 負の表の「横に並べる」「動画」「数式」 |
| 後 | entryEmbed / footnote | CMS 側も未実装。単独で計画 |

`/` コマンド（Notion）で node を挿す。Markdown ショートカット（`## `、`- `、`> `、```` ``` ````）は TipTap の InputRule で。

note 風の書き心地（画像・引用の出典、外部リンクのカード、Enter の挙動）は [richtext-note-style.md](richtext-note-style.md)（2026-09-11）。

### 1.1 microCMS のリッチエディタとの突き合わせ（2026-09-09）

方針は「**microCMS が入れている物は全部入れる**」。ただし**入れられるのは CMS の
`RichText.flix` のホワイトリストにある物だけ**で、無い物は画面に出さず、ここに「CMS 側に口が要る物」
として置く（画面に出て保存できない、が一番悪い）。

出典: [リッチエディタの操作方法（v2）](https://document.microcms.io/manual/rich-editor-usage) /
[リッチエディタの WRITE API](https://document.microcms.io/manual/rich-editor-write-api)

| 機能 | microCMS v2 | 管理画面 | CMS が受けるか | 対応 |
|---|---|---|---|---|
| 見出し | h1〜h5 | h1〜h4 | h1〜h4（`maxHeadingLevel`） | h5 は CMS 側の口が要る |
| 太字 / 斜体 / 打ち消し / インラインコード | ある | ある | ある | 済 |
| **下線** | ある | **入れた** | `underline` にある | 済 |
| **表** | ある（結合と分割も） | **入れた**（結合は無し） | `table` / `tableRow` / `tableCell` / `tableHeader` | 済。結合は `attrs.colspan` / `rowspan`（`toHtml` が属性に、Markdown が `{colspan=2 rowspan=3}` に出す） |
| **文字色** | ある（プリセット + ピッカー） | 無し | **無い** | **CMS 側に口が要る** |
| 背景色 | v2 で廃止 | 無し | 無い | 追わない |
| **文字寄せ** | ある（左 / 中央 / 右） | 無し | **無い** | **CMS 側に口が要る** |
| 上付き / 下付き | v2 で廃止 | 無し | 無い | 追わない |
| インデント | v2 で廃止 | 無し | 無い | 追わない |
| 文字サイズ | プリセット登録時のみ | 無し | 無い | 追わない（本文のサイズはサイト側の CSS の仕事） |
| カスタム class | ある | 無し | 無い | **CMS 側に口が要る**（`toHtml` は class を付けない方針なので、まず方針から） |
| HTML のソース編集 | **エディタには無い**（WRITE API 経由のみ） | 無し | — | 追わない |
| リンク | URL / 相対 / mailto / tel、別タブ、nofollow | URL / mailto / **entry** | `href`（http(s) / mailto）か `entryId` の排他 | tel と別タブ・nofollow は CMS 側の口が要る |
| 画像の alt / キャプション | ある | **入れた** | `image.alt` / `image.caption` | 済 |
| コードブロックの言語 / ファイル名 | ある | **言語とファイル名** | `language` / `fileName` / `highlightLines` | 3 つとも済。言語とファイル名はブロックの下の帯、強調行は左の行番号を押して選ぶ（2026-09-11） |
| 区切り線 / 引用 / 箇条書き / 番号付き | ある | ある | ある | 済 |
| チェックリスト | 無し | ある | `listItem.checked` | うちが上 |
| 埋め込み | 約 1,900 サービス | YouTube / Vimeo / X | `embedOf` の 3 つだけ | 差が大きい。CMS 側の口が要る |
| 数式 / callout / details / gallery / video / linkCard / mermaid | 無し | ある | ある | うちが上 |
| 元に戻す / やり直す | ある | ある | — | 済 |

### 1.2 表の操作は表の上で

**ツールバーのボタンは「表を作る」だけ**（升目で大きさを選ぶ。Word / Google ドキュメント / Notion の `/table` と同じ）。
行と列の足し引きは、カーソルが表の中にある時だけ**列の上端と行の左端に出る掴み**（`.tt-grip`）が持ち、
押すと**その行・列に対する操作だけ**が出る。表全体の操作（見出しの行、表を消す）はツールバーの面に残す。

- 掴みは ProseMirror の DOM の**外**に置く（表の node view は書き換えの度に中を作り直す）
- **見えているのは 4px の細い線**で、押せる当たり判定だけ透明な縁で 10px 取る。塗った太い棒にすると表の中身より枠が目立つ（Notion / Google ドキュメントの実物がどちらも細い線）
- **セルにカーソルがある時か、表にマウスが乗っている時だけ**出る。それ以外は消える
- 押すと**その行・列に薄い網掛け**が乗り、どこに効くのかが押した時点で分かる
- 表は `.tableWrapper` の中で**横スクロール**する。列が多くてもページは横に伸びない
- **列の幅は変えられない**（`resizable: false`）。CMS の `tableCell` は `colwidth` を持たず HTML にも幅が出ないので、画面でだけ動く幅は保存されず消えたように見える

### 1.3 ツールバーは折り返す

ヘッダは 6 個（2026-09-12 に役割で分けた。7.4 の「その他の書式」）だが、狭い幅では**行を折り返す**（`flex-wrap: wrap`）。

実測（2026-09-09、ボタンが 16 個だった頃。本文の枠の幅 = ツールバーの幅）:

| 画面の幅 | 本文の枠 | ツールバーの高さ | 行 |
|---|---|---|---|
| 1440 | 846 | 39 | 1 |
| 1024 | 430 | 67 | 2 |
| 768 | 174 | 123 | 3 |

**幅 768 で本文の枠が 174px しか無い**のは、左右のレールが畳まれず固定幅のまま残るため。
ツールバーの問題ではなく画面の骨格の問題で、別に直す。

## 2. ワークフロー（stage × status の 2 軸）

今の CMS は **stage**（DRAFT / PUBLISHED = 公開サイトに出ているか）と版だけを持つ。ここに **status**（下書きが今どの段にあるか）を直交させる。公開の可否は status に縛らない（公開は `publishEntries` の権限で決まる。status は人の段取りの印）。

- **プロジェクトのワークフロー定義**: status の並び（名前 / 色 / 順）。既定は `Draft → In review → Approved`。owner が `manageProject` で編集
- **entry の status と担当（assignee）**: 下書きに付く。公開しても消えない（公開後の直しも同じ流れ）
- **遷移の制限は最初は無し**（誰でもどこへでも）。要るなら status に「進めるのに要る役割」を後で足す
- **一覧**: `where` に status / assignee、`orderBy` に status の順。ボードは status を列にしたテーブルの見せ方の 1 つ（保存したビューの一種）
- **通知**: status が変わった時の Webhook event（`ENTRY_STATUS_CHANGED`）。人への通知（メール / Slack）は Webhook の先で

CMS 側に要る物（`admin.graphql` と DB。管理画面はこれを待つ）:

| 種類 | 追加 |
|---|---|
| 型 | `WorkflowStatus { id, name, color, position }`、`Project.workflow: [WorkflowStatus!]!`、`Entry.status: WorkflowStatus`、`Entry.assignee: Member` |
| Query | `entries` の `where` に `status_in` / `assignee_eq` |
| Mutation | `updateWorkflow(statuses)`、`setEntryStatus(id, statusId)`、`assignEntry(id, memberId)` |
| 制約 | 使われている status は消せない（INVALID + 件数）。移す先を指定して消す `deleteWorkflowStatus(id, moveTo)` |

MCP はこれを写す（`search_entries` の status、`set_status` ツール）。

## 3. 編集の競合

- **保存**: `updateEntry(expectedVersion)`。**保存は常に 1 本だけ飛ばし、保存中の入力は 1 件だけ queue に持つ**（2 秒デバウンスが重なると、古い `expectedVersion` で自分に CONFLICT を起こす）。応答の `version` で必ず更新する
- **`CONFLICT` の復帰は Elm 側で差分を出す。** `Entry.version` は Int で、`VersionRef` は `versionId` か `stage` しか取らないため、**「自分が読んだ版」を `diff` に渡せない**。相手の下書きを `entry(id)` で取り直し、自分の Model の fields と JSON を突き合わせて見せる（`Diff.elm` を自前で持つ）。「相手の上に乗せて保存」か「捨てる」を選ばせ、自動マージはしない
- **誰が開いているか（presence）**: `touchEditing(entryId)` の mutation を開いている間 30 秒ごとに打ち、`Entry.editors: [{ member, since }]` で読む。60 秒で消える。**プロセスのメモリで持つ**（複数台では台ごとになるが、印なので許す。要るなら表に移す）
- 画面: 編集中の人をヘッダに出し、他の人が開いていれば「保存すると競合するかも」と出す。ロックはしない

## 4. 画面の共通の決め（負の表から）

- 使えない機能は出さない（プランで disabled にしない）
- サイドバーは折り畳める。テーブルの列は表示 / 非表示と幅を覚える（localStorage）
- 一覧の絞り込みは API の `where` と同じ物を画面で組み立て、**保存したビュー**にする（保存先は最初は localStorage、次に API）
- 文字数の上限は円のゲージ（残り少なくなると色が変わり、超えた分をハイライト）。上限は FieldConfig の `maxLength`（**実装済み**。数値の `min` / `max` / `integer` も既にある）
- 画像はプレビュー付きのリサイズとプリセット

## 5. 順（計画の 5 章を本書で更新）

1. 骨組み + ログイン → プロジェクト選択（`me`）
2. entry の編集（段階 1 の richText、保存、CONFLICT、公開の dry-run → 公開、プレビュー）
3. entry の一覧（テーブル。search / where / orderBy / cursor）← **CMS 側は実装済み。待たずに着手できる**
4. 型の編集
5. asset
6. ワークフロー（status / assignee / ボード）← CMS の 2 章を待つ
7. 履歴と diff、予約、複数公開
8. 設定（owner）、Playground
9. richText の段階 2 → 3

CMS 側の並走は 10 章の優先順に従う。

## 6. 画面の構成（2026-09-09）

原則: **サイドバーは 1 段**（型がそのまま一覧）、**型に関わる物は全部その型の画面の中**（一覧 / ボード / 定義 / 設定をタブで）、**entry に関わる物は全部エディタの中**（公開・予約・status・プレビュー・履歴を右のレール）、**全部に URL**（戻っても状態が残る）、**モーダルは 1 段まで**（確認だけ。モーダルの中から別のモーダルは開かない）。

### 6.1 枠

```
┌ 上: [プロジェクト切替 ▾]  [Cmd+K 検索]                  [自分 ▾: アカウント / PAT / ログアウト] ┐
├ 左（折り畳み可）─────────────┬ 中央 ───────────────────────────────┬ 右（エディタでだけ）┤
│ コンテンツ                    │                                     │                  │
│   Blog          (型 = 一覧)   │  パンくず: Blog › 記事のタイトル     │ 公開の状態        │
│   Category                    │                                     │ status / 担当     │
│   + 型を作る                  │  一覧 [テーブル|ボード] [定義] [設定] │ 予約             │
│ asset                         │   or                                │ プレビュー        │
│ 設定（owner だけ出す）          │  エディタ（フォーム + richText）      │ 履歴 / diff      │
│ Playground                    │                                     │ 編集中の人        │
└───────────────────────────────┴─────────────────────────────────────┴──────────────────┘
```

- **プロジェクト切替**は上の左のメニュー（Linear / Vercel）。プロジェクト選択の画面は「最後に開いた物が無い時」だけ出す。1 つしか無ければ出さない
- **サイドバー**の「コンテンツ」は型の一覧そのもの。型をクリック = その型の entry 一覧。型の作成もここから（別の「API 設定」の世界を作らない）
- **設定**は owner だけに出す。中はタブ（メンバー / API キー / Webhook / ワークフロー / プロジェクト）。上の右の「自分」メニューはアカウント（組織 / PAT）で、プロジェクトの設定と混ぜない
- **右のレール**はエディタでだけ出る。公開に関わる操作はここに集める。dry-run（publishCheck）の結果はモーダルでなくレールの中に出し、通れば同じ場所のボタンで公開

### 6.2 URL

| URL | 画面 | 備考 |
|---|---|---|
| `/` | 最後のプロジェクトへ redirect。無ければプロジェクト選択 | |
| `/p/{slug}` | 最初の型の一覧へ redirect。型が無ければ「型を作る」 | |
| `/p/{slug}/c/{typeApiId}` | entry の一覧（テーブル） | `?q=` 検索、`?where=`、`?order=`、`?cols=`、`?after=`。保存したビューは `?view={id}` |
| `/p/{slug}/c/{typeApiId}/board` | 同じ一覧のボード（status の列） | 絞り込みの query は共通 |
| `/p/{slug}/c/{typeApiId}/schema` | 型の定義（フィールドの追加・並び替え・config） | 一覧のタブ。`manageTypes` だけ |
| `/p/{slug}/c/{typeApiId}/settings` | 型の設定（名前 / apiId / 削除） | |
| `/p/{slug}/c/{typeApiId}/new` | 新しい entry のエディタ | 保存で `/{entryId}` に置き換え |
| `/p/{slug}/c/{typeApiId}/{entryId}` | エディタ | `?version={id}` で履歴の版を読むだけで開く、`?diff={from}..{to}` |
| `/p/{slug}/assets` | asset の一覧（グリッド）。ドロップでアップロード | 1 件は同じ画面の右のパネル（遷移しない） |
| `/p/{slug}/settings/{members\|api-keys\|webhooks\|workflow\|project}` | プロジェクトの設定 | owner |
| `/p/{slug}/playground` | GraphiQL | |
| `/account`、`/account/tokens`、`/account/orgs/{id}` | 自分 / PAT / 組織 | Account API |

### 6.3 遷移を減らす決め

- **一覧 → エディタ → 一覧**で一覧の状態（絞り込み・列・ページ・スクロール位置）が残る。URL に持つ + Elm の Model で一覧を捨てない
- **エディタから隣の entry へ**: 右のレールの上に「前 / 次」（一覧の順）。一覧に戻らない
- **新規作成は 1 クリック**: 一覧の「+ 新規」で即エディタ。作成のウィザードやタイトルだけのダイアログを置かない。保存は自動（入力が止まって 2 秒。`updateEntry`）。「保存」ボタンは無く「保存済み / 保存中 / 競合」の表示だけ
- **公開は 2 クリック**: レールの「公開」→ dry-run の結果がレールに出る（違反はフォームの項目に赤で写す）→ 同じボタンが「公開する」に変わる
- **asset の選択はエディタを離れない**: 画像のフィールドと richText の image は、同じ画面の上に asset のピッカー（モーダル 1 段。ここにドロップでアップロードもできる）
- **参照先の entry も離れない**: REFERENCE のフィールドはピッカーで選び、選んだ物は「覗く」（右からのパネルで読むだけ）。編集したければそこから開く
- **Cmd+K**: 型・entry（検索）・asset・設定のページへ。型を跨いだ entry の検索もここ
- **削除・取り下げ**は impact（壊れる参照元）を確認の中に出す。確認は 1 段のモーダル

## 7. 画面の言葉（2026-09-09）

エンジニアと非エンジニアの両方が使うので、**画面の言葉は microCMS に寄せて統一**する（既に慣れている語をそのまま使い、エンジニアが嫌う語は避ける）。API と SDL の名前（`entry` / `contentType` / `asset`）は変えない。写しは画面だけ。

| 画面の言葉 | API / ドメイン | 備考 |
|---|---|---|
| プロジェクト | project | microCMS の「サービス」は採らない（URL と API がプロジェクトなので） |
| API | contentType（型） | サイドバーの見出しも「API」。「ブログ API」の言い方が定着している |
| エンドポイント | `ContentType.apiId` | `blogs` |
| API スキーマ | フィールドの定義 | 一覧のタブ名 |
| API 設定 | 型の名前・エンドポイント・削除 | |
| フィールド ID / 表示名 / 種類 | `Field.apiId` / `name` / `kind` | 種類の表示は「テキスト / テキストエリア / スラッグ / 数値 / 真偽 / セレクト / 参照 / オブジェクト / ブロック / メディア / リッチエディタ / 日時」 |
| コンテンツ | entry | 「記事」とは呼ばない（型が記事とは限らない） |
| コンテンツ ID | `Entry.id` | |
| 下書き / 公開中 / 公開終了 / 公開待ち | stage と予約 | 公開中で下書きがあれば「公開中 · 下書きあり」 |
| 公開 / 公開終了にする / 予約公開 / 公開終了を予約 | publish / unpublish / schedulePublish / scheduleUnpublish | 「取り下げ」は使わない |
| 公開前の確認 | publishCheck | |
| 画面プレビュー | createPreviewToken | |
| バージョン履歴 / 差分 / v3 の内容に戻す | versions / diff / restoreVersion | 「版」は単体で使わない（公開版 / 下書き版 の接尾辞は可）。1 件は「バージョン」、番号は「v3」 |
| ステータス / 担当者 | workflow status / assignee | |
| レビュー | ステータスの既定の 1 つ（In review → 「レビュー中」） | 既定は「下書き → レビュー中 → 承認済み」 |
| メディア | asset | |
| メンバー / 権限 | members / role | 権限は「管理者 / 編集者 / 投稿者 / 閲覧者」（owner / editor / writer / viewer） |
| API キー / Webhook | apiKeys / webhooks | そのまま |
| API プレビュー | Playground（GraphiQL） | microCMS の語 |
| 検索（⌘K） | Cmd+K | 「コマンドパレット」とは呼ばない |
| 代替テキスト / キャプション / 出典 / 出典の URL / 適用 / 閉じる | richText の image の `alt` / 中身（text と link / bold / italic / strike / code の mark）/ `source` / `sourceUrl`、blockquote の最後の子の `quoteCite` の中身（text と同じ 5 つの mark） | キャプションは画像の直下の figcaption で、カーソルがある間はキャプションの真上（画像の下端に重なる）に 太字 / 打ち消し / リンク の 3 つの帯が浮く（画像の枠と帯は出ない。見出しと引用は無い）。空で選ぶと placeholder「キャプションを入力」（中央・ラベル無し）。Enter は何もしない、上下の矢印で外の段落へ。旧い `caption` の文字列は読む時だけ中身に写す。代替テキストは画像の上の帯の ALT から（帯が「代替テキストの欄 + 適用 + ×」に入れ替わる）。画像の出典は帯には無い。`source` か `sourceUrl` がある時だけキャプションの下に小さく「出典: …」（URL があればリンク風）と出し、押すと帯の位置に「出典」と「出典の URL」の 2 欄 + 適用 + × が出る（直す・両方空にして消す。新しく付けるのは Markdown / API から）。引用の出典は箱の外の下の右で、**キャプションと同じ編集できる場所**（引用の最後の子の `quoteCite`。placeholder は「出典を入力」）。文字を選ぶと帯が出て、太字 / 打ち消し / リンクを掛けられる。入れた出典は本文と同じ濃さ（下線も枠も出さない）。URL は出典の文字に掛かる link の mark で、行に印もボタンも置かない。Enter は何もしない、上下の矢印で引用の外の行へ。出典が空なら `quoteCite` ごと出さず、焦点が引用の外にあれば行の中身も出さない。旧い `attrs.cite` / `citeUrl` は読む時だけ `quoteCite` に写す（`citeUrl` はその文字の link に。書き出しには出さない）（2026-09-11） |
| リンク / リンクの URL（キャプションの帯） | link mark の `href` | キャプションの帯のリンクを押すと、帯が「URL の欄（placeholder `https://`）+ 適用 + ×」に入れ替わる。Enter / 適用で掛かり（空なら外す）、× / Esc で戻る。リンクの掛かった文字を選ぶとリンクが押した状態になり、選択の下に小さな面で URL を文字で見せる（note と同じ。2026-09-11） |
| リンク / ALT / 縮小 / 拡大 / 配置 / 左に寄せる / 中央に寄せる / 右に寄せる / 削除（画像の帯） | 選んだ画像の上に浮く帯（画像との隙間 24px、高さ 52px）。リンクは `href`（http(s) だけ。帯が「URL の欄 + 適用 + ×」に入れ替わる。空で外す）、ALT は `alt`（同じ形で「代替テキストの欄 + 適用 + ×」）、縮小は `size` の small ⇄ なし（幅 50% まで。small の間は同じボタンが外向きの矢印の「拡大」になり、押すと戻す）、配置は帯そのものが 左寄せ / 中央 / 右寄せ の 3 つに入れ替わり、押すと `align`（left / なし / right）を書いて元の帯に戻る（Esc でも戻る。縮小していなくても押せる）。削除は画像を消す。帯に「キャプション」は置かない（欄は画像の下に出ていて押せば入力できる。note の帯にも無い）。選んだ画像の枠は水色 4px の実線、角は丸めない | note の帯（リンク / ALT / 縮小 / 配置 / 削除）と同じ並び。ALT 以外はアイコンで、語は title / aria-label に持つ（リンク = 鎖、縮小 = 内向きの矢印、拡大 = 外向きの矢印、配置 = 今の寄せの線（左 / 中央 / 右）、横に並べる = 2 列、削除 = ゴミ箱）。「ALT」は英字のまま（title は「代替テキスト」）。掛かっている物（リンクあり / 縮小 / 今の寄せ）はダークで緑、ライトで白の面。帯の下に面やポップオーバーは足さない（2026-09-11） |
| 横に並べる / 1 枚ずつに戻す（画像の横並び） | richText の image（中の imageItem） | 「+」の一覧には入れない。**画像の node は 1 つで、中に imageItem を並べる**（1 枚でも複数枚でも同じ node。`docs/design/richtext-gallery-ui.md` 1）。1 枚だけの image が隣り合っている時だけ帯に「横に並べる」が出て、続きの画像の imageItem を 1 つの image にまとめる。**列数は選ばせず枚数から決まる**（2 枚なら 2 列、3 枚以上は 3 列で折り返す。同 2）。**ぜんたいと 1 枚で帯が分かれる**（`docs/design/richtext-gallery-flow.html` 2・3）。ぜんたい（列の隙間か枠の余白を押す）は水色 4px の枠が外側に出て、帯は 1 枚ずつに戻す / 削除 の 2 つ。中の 1 枚を押すと枠はその 1 枚に出て、帯は リンク / ALT / 削除 の 3 つ（縮小と配置は並べている間は出さない。列の幅が決まっていて効かない）。「1 枚ずつに戻す」を押すと imageItem の数だけ image に分かれる。列を選ぶ帯は持たない。キャプション・縮小・配置・リンク・出典・alt はすべて imageItem が持ち、image 自身は attrs を持たない。中の画像が 0 枚になった image は消える（2026-09-12）|
| 数式を入力 / TeX で書く（例: E = mc^2）/ 削除（数式の帯） | richText の mathBlock（`tex`） | 普段は組版だけを出し、TeX の欄は隠す。空の時は組版の場所に薄く「数式を入力」。**箱のどこを押しても**下に TeX の欄が開いて焦点が入り（placeholder「TeX で書く（例: E = mc^2）」）、打つたびに上の組版を描き直す。欄は中身の行数に合わせて伸び、欄を伸ばす掴みは出さない。**ホバーしている間だけ箱の右上に小さな削除**（28×28、濃い地に白のアイコン、title / aria-label は「削除」。読み取り専用では出さない）。選んだ状態（Esc や矢印キー）では今までどおり水色 4px の枠と、上に削除だけの帯（画像と同じ部品）。空の欄の Backspace・ホバーの削除・帯の削除はどれも段落に戻す。Esc で欄を閉じて数式を選んだ状態、もう一度 Esc で本文へ。TeX の欄の 1 行目で ↑ / 最終行で ↓ で前後の行へ出る（2026-09-11） |
| 出典を入力 | blockquote の `quoteCite` の placeholder | 引用の箱の外の下、右寄せ（箱との間 18px）。引用に焦点がある間と乗せている間だけ出て、押すと出典に焦点が入る。空のまま離れると畳む（2026-09-11） |
| メディアから選ぶ / N 枚を本文に挿入 / 閉じる | エディタの画像の「+」から開くメディアのピッカー | 説明と決定の帯は面の上下に固定し、スクロールするのは一覧だけ（WordPress / microCMS / Contentful の「投稿に挿入」の帯）。決定は選んだ枚数を出し、0 枚は押せない。Enter でも決定、サムネイルのダブルクリックはその 1 枚だけをすぐ挿入、閉じるは Esc でも（2026-09-11） |
| 保存済み 12:34 / 保存中… / 未保存 / 競合しました | エディタの上の帯の保存の様子 | 下書きは入力が止まって 3 秒で自動保存（richtext-note-style §6.8）。時刻は最後に保存できた HH:MM、手元のタイムゾーン。⌘S と「下書き保存」も残す（2026-09-11） |
| ブロックを追加 | 空の段落の左の「+」 | 一覧は 画像 / 区切り線 / 引用 / 囲み / 折りたたみ / コード / 表 / 数式 / チェックリスト / 埋め込み。`/` でも開く。**ブロックを入れる口はここだけ**（ヘッダのツールバーにも浮く帯にも置かない）。画像だけはヘッダにも出す。表だけは選んだ後に升目（「大きさを選ぶ」）を出す（2026-09-12） |
| 囲み / ノート / ヒント / 警告 | richText の `callout`（`attrs.kind` は note / tip / warning） | 「+」の一覧から入れる。種別は箱の上の帯の 3 つのアイコンで切り替える。**アイコンは形で分ける**（色だけにしない。色覚と白黒の印刷で区別できなくなる）。左に太線、地は種別の色。中身は普通のブロック（段落・リスト・コードなど）。Markdown は GitHub alerts の `> [!NOTE]` / `> [!TIP]` / `> [!WARNING]`（2026-09-12） |
| 折りたたみ / 詳細 / 見出しを入力 | richText の `details`（`attrs.summary` は空でない文字列） | 「+」の一覧から入れる。見出しの欄は箱の上の帯。左の三角で**エディタの中でも畳める**。畳んだ状態は doc に持たない（`summary` しか置き場が無く、持たせると Markdown の往復で消える）。畳む前に中に選択があれば外の行へ出す。見出しを空にすると「詳細」に戻る（空だと `RichText.validate` に落ちるので、doc をいつ読んでも空でない形にする）。Markdown は `<details><summary>…</summary>`（2026-09-12） |
| その他の書式 | 浮く帯の右端の「…」 | **役割で分ける**（`docs/design/toolbar-split-mock.html` の案 D）。ヘッダのツールバーは**押すだけで入る物**だけ 6 個: 段落の種類 / 画像 / 箇条書き / 番号付き、右端に 元に戻す / やり直す。浮く帯は**文字を選んでから掛ける物**だけ 6 個 +「…」: 太字 / 斜体 / 打ち消し / コード（文の中）/ 数式（文の中）/ リンク。画像だけはヘッダに残す（書くたびに使うので「+」の一覧に寄せず、両方から入れる）。「…」の中は見出し付きの縦の一覧で、「文字」に 下線 / 蛍光ペン / 上付き / 下付き。畳んだ中に押されている物があれば「…」自体に印が付く。Esc と外を押すと閉じる（2026-09-12） |
| 数式（文の中） | 浮く帯の `math` mark のボタン | `$…$` を知らなくても掛けられる口。アイコンは Σ（上付き・下付きの道具と見分けが付くため `x²` にしない）。字を選んでいればその字に掛け、選んでいなければ 1 文字（`x`）を数式にして選んだ状態で置く。段落の数式は帯に置かず「+」の一覧の「数式」から（ブロックを入れる物は「+」に集める）（2026-09-12） |
| 埋め込み / URL を入力 / 埋め込む URL | richText の embed（YouTube / Vimeo / X）と linkCard | 「+」の一覧の「埋め込み」で URL を 1 つ聞く。提供元に合わなければ linkCard。埋め込みは提供元名（YouTube / Vimeo / X）と URL の薄い枠 |
| 削除（リンクカードの帯） / 取得中… | linkCard の帯と、OGP の取得中（`fetchLinkCard` / `linkCards`） | カードは note と同じ形（`docs/design/richtext-note-linkcard-ui.md`）。貼った瞬間に管理 API が OGP を取り、取れるまでは同じ大きさの白い箱に「…」。3 秒を超えたら箱の中に薄く「取得中…」。取れたら左に タイトル / 説明（2 行）/ ドメイン、右 30% にサムネイル（無ければ薄い灰色の面に画像のアイコン）。取れなければ URL と理由（理由の文は API の `error` をそのまま）。選ぶと画像と同じ水色 4px の枠と、上の中央に「削除」だけの帯。削除は素の URL の段落に戻す。OGP は doc に持たない（2026-09-11） |
| リンク先 / コンテンツを検索、または URL を入力 / URL / コンテンツ / 最近のコンテンツ / 外部のページ / 今のリンク先（外部）/ 今のリンク先（コンテンツ）/ 見つかりません / コンテンツ名か URL を入力してください / もっと見る（あと N 件）/ 読み込み中… / リンクを削除（リンクの面） | link mark の `href` と `entryId` | ツールバーと BubbleMenu の「リンク」で、押したボタンの下に出る幅 300px の面（`src/LinkPick.elm`。**面は Elm が描き**、TipTap は `linkopen` を投げて `linkchoice` を受け取るだけ）。**入力欄は 1 本**で、打った文字が `http(s)` / `mailto:` で始まれば一番上に「URL」の行、それ以外はコンテンツの検索。行は「URL」と「コンテンツ」の見出しで分ける（打つ前は「最近のコンテンツ」）。↑↓ で選び Enter で決め、Esc と外を押すと閉じる。既にリンクが掛かっていれば面の頭に「今のリンク先」（コンテンツは題・API 名・公開の状態・配信のパス、消えていれば赤く「見つかりません（id）」）と、下に「リンクを削除」。公開の状態の語は `Ui.Stage` が 1 か所で持つ（2026-09-11） |
| ファイル名 / コーディング言語 / この行を強調（コードブロック） | codeBlock の `fileName` / `language` / `highlightLines` | 言語とファイル名はブロックの**下**の帯（左にファイル名、右に言語。note の実物）。焦点がブロックの外にある間は帯だけが残り、placeholder は消える。言語の欄は打って絞り、候補は色の印（`Ui.initialMark` と同じ頭文字の四角。外部のアイコンは読まない）＋正式名＋薄い別名の 1 行で、別名は独立した行にしない（`csharp` の右に `cs`）。決めると帯には整った名前（`C++`）が出て、doc に入るのは正式名（`cpp`）だけ。強調行は帯に欄を置かず、コードの左の**行番号を押して選ぶ**（もう一度押すと解除、Shift で範囲）。押した結果を `1,3-5` に畳んで保存する。行が折り返すと番号とずれるので、コードは折り返さず横に送る（2026-09-11） |
| 太字 / 斜体 / 打ち消し / コード（文の中） / 数式（文の中） / リンク / その他の書式 | 選択の下に浮く帯（BubbleMenu） | **文字に掛ける物だけ** 6 個 +「…」。押した状態は aria-pressed。下線・蛍光ペン・上付き・下付きはその「…」の中だけ。見出し（H2 / H3）と引用は帯に置かない（段落の種類はヘッダのドロップダウン、引用は「+」の一覧）。画像のキャプションと引用の出典の中では、帯がその真上の 3 つ（太字 / 打ち消し / リンク）に入れ替わり「…」は出ない（2026-09-12） |

### 7.1 表記の決まり（2026-09-11）

文言を全件点検して決めた。今の多数派に合わせた物で、判断が要る所は先に決めておく（後から部品の文言を 2 回触らないため）。

| 項目 | 決まり | 根拠 |
|---|---|---|
| キャンセル | 「キャンセル」。「やめる」は使わない | microCMS / Contentful / Strapi / Sanity すべて。20.3 に「やめる」は何が起きるか読めなかった記録 |
| ボタン | 体言止め（保存・発行・削除・追加・公開・作成・キャンセル）。「〜する」にしない | microCMS のボタンは体言止め |
| 動詞の語彙 | 作成 / 追加 / 削除 / 変更 / 修正 / 入力 / 選択 / 検索 / 表示 / 取得 / 接続 / 通知 / コピー / 結合 / 解除。和語（作る・足す・消す・変える・直す・入れる・出る・叩く・投げる・繋ぐ・控える）は画面に出さない | AGENTS.md「和語へ言い換えない」 |
| 進行中 | 「〜中…」の体言止め（送信中… / 保存中… / 読み込み中… / 検索中… / 取得中…）。「…」まで必ず付ける | 「〜しています…」は対象を言い分けられない。状態の「公開中」「レビュー中」は進行中ではないので「…」は付けない（2026-09-11） |
| ボタンの前置き | 動作だけを書く。「承知して保存」のような前置きを付けない | 影響はボタンの上のコールアウトが説明する（2026-09-11） |
| 「…」の付け方 | 押すと**入力を求める**物だけに付ける。確認のモーダルを出すだけの物には付けない（「このフィールドを削除…」→「このフィールドを削除」）。進行中の「〜中…」と入力欄の placeholder は別 | Apple HIG / GNOME HIG。GitHub・microCMS・Contentful の削除も「…」無し（2026-09-11） |
| 句点 | 説明文は「。」あり。ラベル・ボタン・見出し・空状態・ヒント・エラー文は「。」なし | 今の多数派 |
| 括弧・記号 | 全角「（）」、半角「:」＋スペース、「…」1 文字、「〜」（U+301C）。英数字と日本語の間は半角スペース | 今の多数派 |
| 記号・記法 | 集合記号・矢印・正規表現・enum 名・引数名・JSON の断片・Markdown の強調を人向けの文に使わない | 入稿する人に読めない |
| 長音 | 付ける（サーバー・ユーザー）。「リッチエディタ」だけ microCMS の表記 | 今の多数派 |
| 形式名詞 | ひらがな（こと・もの・ところ・とき） | 公用文と主要な日本語 UI |
| 内部語 | entry / asset / 型 / SINGLETON / owner / 鍵 / 出来事 は画面に出さない。サーバの Violation も画面の語で書く | Violation は画面にそのまま出る |
| 版 | 単体で使わない。「バージョン」「v3」。公開版 / 下書き版 は可 | 2026-09-08 の決めの後も何度も入り込んだ（2026-09-11 に機械の見張りを入れた） |

### 7.1.1 機械の見張り（2026-09-11）

7.1 の決めのうち正規表現で書ける物は `admin-ui/scripts/wording-check.mjs` が `npm run check` の最初に見る（`src/` の Elm と `web/` の TypeScript の文字列リテラルだけ。コメントと識別子は見ない）。
今あるのは: 「版」の単体、「型」（content type の意味）、entry / 取り下げ / ゴミ箱、和語の動詞の過去形と口語（作った・足した・消した・直した・変えた・叩く・投げる・繋ぐ）、「並び替え」（正は「並べ替え」)、「やめる」、「承知して」、「〜する」で終わるボタン、「〜しています…」、「…」の無い進行中（読み込み中 / 保存中 / 送信中 / 検索中 / 取得中 ほか）。

2026-09-11 に TipTap のエディタ（`admin-ui/web/*.ts`）へ広げた。TS は quote が 3 種あり、コメントの中に 7 章の語の引用が多いので、リテラルは 1 文字ずつ走って拾う（コメントを正規表現で落とすと文字列の中の `https://` を切る）。この時に直したのは「読み込み中」→「読み込み中…」、「… を送っています…」→「… を送信中…」、「取得に時間がかかっています」→「取得中…」の 3 つ。

2026-09-11 に 7.1 を全画面へ適用した（「やめる」13 か所 → キャンセル、「〜する」のボタン 10 種 → 体言止め、進行中の 8 種 → 「〜中…」、和語の動詞と内部語の「鍵」）。

**決めを足したら、ここの表と `wording-check.mjs` の両方に足す。** レビューと記憶だけに置くと、サブエージェントが書いた文で再発する。
サブエージェントに画面の文言を書かせる時は、7 章の表をプロンプトに貼るか「7 章の表の語だけを使う」と指示する。

### 7.2 反応の決まり（2026-09-11）

「どこで何が起きているか分からない」を無くすための 4 つ。部品は `Ui.Reply`。最初に当てたのは API 設定。

1. **押したら必ず返事がある。** 送信中は押せなくなり、終わったら「保存しました」が出る。次に入力を触るまで残す（時間で消さない）
2. **エラーは原因の欄の下。** サーバの違反は path で欄に振り分け、欄に付かない物だけボタンの横に。ページの上端にまとめない
3. **開いた物は Esc と外側クリックで 1 段閉じる。** `Main` が Escape を今の画面に配り、画面が「今開いている物を 1 つ閉じる」を持つ
4. **未保存は状態として見える。** 見出しの横に「未保存」、保存は変更がある時だけ押せる、離れる時は止める

## 8. モックで決めた事（2026-09-09）

モック: https://claude.ai/code/artifact/0bd9dace-75e1-4d99-9cd5-9232f820d3c1（14 画面 + 密度の A/B 比較）。

- 骨組みは「サイドバー + テーブル + 右レール」（Contentful / Payload / Strapi と同じ主流の形）。サイドバーを畳むのは上のバー左端のアイコンボタン
- 密度は B（行 44px、文字 13.5px、ラベル 13.5px の黒、入力 14px）。エンドポイント・フィールド ID・種類の表記は既定で隠し、「開発者向けの表示」のトグル（ツールバー右と編集画面右上）で出す。フィールドの説明文（API スキーマで設定）を欄の下に出す
- アイコンは Lucide 系の線アイコン（24px グリッド、線 1.8）を自作。フィールドの種類 13、API の種類（リスト形式 / オブジェクト形式）、サイドバー、畳む
- 言葉は 7 章の表。権限は 管理者 / 編集者 / 投稿者 / 閲覧者
- CMS 側に足りない物は 10 章（バックエンドの調査係が SDL とソースで確かめた物）

## 9. ダークテーマ（2026-09-09）

- **3 状態**: システムに従う（既定）/ ライト / ダーク。切り替えは上のバー右の「自分」メニューの中
- **持ち方**: `<html data-theme="light|dark">`。システムに従う時は属性を付けず `prefers-color-scheme` に任せる。選択は localStorage（人ごと、端末ごと。API には持たない）
- **色はトークンで持つ**（生の hex を要素に書かない）。flix_ge_studio と同じ形で、daisyUI のテーマを 2 本（`studio-light` / `studio-dark`）作り、`@theme` に app / panel / raised / well / edge / ink（と soft / faint）を置く
- **色で意味を出す所はダークでも同じ意味を保つ**: 公開中（緑）/ 公開中・下書きあり（黄）/ 下書き（灰）/ 公開待ち（青）/ エラー（赤）。ダークは彩度を落とし、背景を暗く文字を明るくする
- **画像とメディア**: サムネイルの下地はダークでも中間の灰にする（白のままだと透過 PNG が飛ぶ）
- **リッチエディタの中身**は公開サイトの見た目ではなく管理画面のテーマに従う（プレビューは別画面）
- 最初のちらつきを防ぐため、index.html の `<head>` に localStorage を読んで `data-theme` を付ける小さなインラインスクリプトを置く

## 10. CMS 側の過不足（2026-09-09 の調査）

管理画面の実装者は `src/` を読まない。CMS の調査係が SDL とソースで確かめた結果が以下（詳細は本節）。

### 10.1 すでにあり、待たなくてよい物

- `entries(typeId, search, where, orderBy, first, skip, after)` と `EntryPage`（nodes / edges / pageInfo / totalCount）。`first` は 0〜200 に丸める
- `FieldConfig.maxLength` / `min` / `max` / `integer`（検証も実装済み）
- `publishCheck` / `impact` / `publishPlan` / `publishMany` / `schedules` / `createPreviewToken` / `versions` / `diff` / `restoreVersion` / `saveVersion`
- メンバー・招待・API キー・Webhook・配信履歴・再送・公開範囲
- `fieldImpact` と `expected`（型の変更の影響。2026-09-11）、`auditEvents` / `auditEventsCount` と `GET /admin/audit.csv` / `audit.jsonl`（監査ログ。2026-09-10〜11）

### 10.2 画面が要るのに無い物（優先順）

| # | 項目 | 効く画面 | 目安 |
|---|---|---|---|
| 1 | ワークフロー（`WorkflowStatus` / `Entry.status` / `assignee` / where の status_in・assignee_eq / updateWorkflow / setEntryStatus / assignEntry / `ENTRY_STATUS_CHANGED`） | ボード、一覧の絞り込み、編集のレール | 大 1.5〜2 日 |
| 2 | `ContentType.titleField`（一覧の代表列・参照ピッカー・⌘K の表示名） | 全画面 | 小 半日 |
| 3 | `FieldConfig.description` と `defaultValue` | 編集画面（欄の下の説明） | 小 半日 |
| 4 | `searchEntries(q, typeIds)`（型を跨いだ検索） | ⌘K | 中 半日〜1 日 |
| 5 | presence（`touchEditing` / `Entry.editors`） | 編集画面 | 中 半日 |
| 6 | `Entry.referrers`（逆参照。ページング付き） | 執筆者などの「このコンテンツ」 | 小〜中 半日 |
| 7 | メディアの `AssetWhere` / `orderBy`、`AssetUse.via`、容量の集計 | メディア | 中 1 日 |
| 8 | 違反にフィールドを紐づける（references / assets の violation に apiId）と、`Violation.path` と `extensions.violations` の**キーの統一** | 公開前の確認をフォームに写す | 小 半日 |
| 9 | 型編集の安全化（~~`fieldImpact`~~ 済み 2026-09-11 / `replaceSelectOption` / 子フィールドの並び替え） | API スキーマ | 中 1 日 |
| 10 | プロジェクトの rename / 削除、招待の期限と再送、`me` の件数集計 | 設定、プロジェクト選択 | 小 |
| 11 | 画像変換 URL（プリセット・srcset）。方針は外部委任なので当面は原寸表示 | メディア | 中〜大 |
| 12 | 保存したビューの API 化（最初は localStorage） | 一覧 | 中 1 日 |

### 10.3 管理画面が知っておく落とし穴

- **violations のキーが 2 種類**: `extensions.violations` の要素は `field`、GraphQL の `Violation` 型（publishCheck / publishPlan）は `path`。値の規則は同じだがデコーダは 2 本要る
- **path の規則**: 最上位は `fields.title`、OBJECT の子は `fields.hero.headline`、配列と BLOCKS は**ブラケット** `fields.sections[0].headline`、richText の中は `fields.body.content[2].marks[0]`。フィールドに紐づかない物は `references` / `assets`。`publishMany` だけ entry id が頭に付く（`b1.fields.title`）
- **diff の path には `fields.` が付かない**（`hero.headline` / `tags[2]`）。publishCheck と規則が違う
- `CONFLICT` の extensions は `{code, entity, id, expectedVersion, actualVersion}`
- `FORBIDDEN` / `REQUIRES_LOGIN` / `UNAUTHENTICATED` は code だけで、要る権限は日本語の message にしか無い（機械判定するには `extensions.permission` の追加が要る）
- **認証の失敗は 200 + path 無しの errors 1 件**。`/mcp` だけ 401
- **部分的失敗がある**（data に読めた分 + errors[].path）。errors の有無だけで成否を決めない
- `required` は**公開時だけ**効く（下書き保存は通る）。`unique` は**公開中の値とだけ**照合する
- **フィールドの種類（kind）は後から変えられない**。`removeField` / `updateField` / `addField` / `deleteContentType` は `fieldImpact` で見た影響を `expected` で渡す。渡さずに押すと影響のある操作は止まり、影響が空なら渡さなくて通る。見た時より影響の種類が増えるか公開中の件数が増えていれば violations 付きの `INVALID` で止まる（件数は他人の保存で動くので完全一致では見ない）
- `createPreviewToken` の `url` は型に `previewUrl` が無いと null
- 型の `linkPath` は**サイト上の path の型紙**（`/blog/{slug}`）。使える印は `{id}` と `{slug}` の 2 つで、`{slug}` は値が無ければ id に落ちる。`/` か `http(s)://` で始める。設定すると本文のコンテンツへのリンクの `href` がその path になり、無ければ `#entry:{id}`（`data-entry-id` はどちらでも付く）。`RichText { links { id apiId path } }` でも同じ物が引ける
- `EntryVersion.author` は表示名の文字列（email か `api-key:<名前>`）。userId は無いのでアバターは出せない
- **管理 API の URL は `/p/{プロジェクト slug}/admin/graphql`**。`/p/{slug}/graphql` は**コンテンツ API** で別物。Account API は `/account/graphql` だけ（`/p/{slug}/account/graphql` は 404）
- dev 認証は `X-Dev-User: <email>`（`Authorization` ではない）。dev の時サーバは 127.0.0.1 にしか bind しない
- 資格情報の読み取り順は PAT → トークンヘッダ → `X-Api-Key` → `X-Preview-Token`

### 10.4 権限とボタンの対応（`viewer.permissions` で出し分け。role では判定しない）

| permission | 出す物 |
|---|---|
| `readDraft` | 管理画面に入れる最低条件 |
| `writeEntries` | 新規・下書き保存・削除・status と担当者の変更 |
| `publishEntries` | 公開・公開終了・予約・公開前の確認・まとめて公開 |
| `manageTypes` | API スキーマのタブ・API を作る・API 設定 |
| `manageAssets` | メディアのアップロード・alt の編集・削除 |
| `manageMembers` | 設定 › メンバー |
| `manageApiKeys` | 設定 › API キーと Webhook |
| `manageProject` | 設定 › プロジェクトとワークフロー |

WRITE の API キーは manageMembers / manageApiKeys / manageProject が必ず落ちる。READ の PAT は viewer に落ちる。

### 10.5 richText の doc（TipTap が守る制約）

node は doc / paragraph / heading(level 1〜4, id は `[A-Za-z0-9_-]{1,64}`) / bulletList / orderedList / listItem(checked) / blockquote / codeBlock(language `^[a-z0-9+#-]{1,32}$`, fileName, highlightLines `1,3-5`) / table / tableRow / tableCell / tableHeader / callout(**kind 必須**: note / tip / warning) / details(**summary 必須・空不可**) / image(**中は imageItem のみ・1 つ以上**。attrs は持たない) / imageItem(assetId 必須) / gallery(読む側だけの互換。**中は古い形の image のみ・1 つ以上**, columns 2〜4) / text / hardBreak / horizontalRule / video(assetId 必須) / embed(**YouTube・Vimeo・X の URL のみ**) / linkCard(http(s) のみ) / mathBlock(tex 空不可)。

mark は bold / italic / strike / underline / code / link(**href か entryId の片方だけ**。`javascript:` 不可) / math(**他の mark と重ねられない**、TeX は空不可) / sub / sup(**上付きと下付きは重ねられない**) / highlight。

**入れ子は許さない。** 表のセル（tableCell / tableHeader）の中は paragraph だけ（GFM の表のセルが inline しか持てず、`Markdown.renderCell` が段落の中身しか拾わないため）。blockquote の中に blockquote は入らない。**リストの入れ子だけは残す**（Markdown で往復する）。Markdown から取り込む時は `> >` も `~^a^~` も 1 段に潰す。

知らない node と mark は INVALID。エディタは未対応の node を消さずに素通しする。`heading.attrs.id` は空欄で作らない（無ければサーバが振る。キーがあって非文字列だと INVALID）。

### 10.6 API にあるが画面に無い物（足す）

予約の一覧（`Schedule.status` と `lastError`、FAILED の理由の置き場が今どこにも無い）、まとめて公開（`publishPlan` → `publishMany` の順と理由）、公開時に一緒に公開される物（`impact(action: PUBLISH)` の cascades）、`viewer`（今どの身元で叩いているか）、公開中との差分（`diff(from:{stage:DRAFT}, to:{stage:PUBLISHED})`）、SINGLETON の型は一覧を出さず即エディタ、型の設定の `previewUrl` の欄、MCP をつなぐ画面（鍵の発行と URL の案内）。

## 11. Elm の決まり（2026-09-09。flix_ge_studio と insidesales-plus の調査から）

読んだ物: flix_ge_studio の `web/`（Browser.element、Tailwind v4 + daisyUI、Effect と封筒の port、elm-program-test）と insidesales-plus（elm-pages のコンテンツサイト。elm-css、elm-form-decoder、elm-storybook）。**insidesales-plus は SPA ではない**ので、アーキテクチャは flix_ge_studio を土台にし、部品とフォームの流儀を insidesales-plus から借りる。

### 11.1 土台（flix_ge_studio から）

- **`Effect` 型を挟む**。update は `Cmd` を返さず `Effect` の値を返し、`Cmd` にするのは `Effect.perform` の 1 関数だけ。理由は「Cmd を直接返すとテストから中身が見えない」。**ただし素通しにしない**（insidesales-plus は `fromCmd` で逃げていて抽象化の利益がゼロだった）。意味のあるバリアントを持たせる: `SendGraphql` / `PushRoute` / `ReplaceRoute` / `ShowToast` / `Autosave` / `Debounce` / `Focus` / `Batch` / `None`
- **port は封筒 2 本**（`apiRequest` / `apiResponse`）。送りは `{id, kind, payload}`、返りは `{id, kind, ok, body}`。URL・ヘッダ・再試行・タイムアウトは TypeScript 側に閉じ、Elm は知らない。id は update の中で採番する（純粋なまま）
- **port の命名は `動詞_モジュール_JS`（Elm → JS）/ `動詞_モジュール_ELM`（JS → Elm）**（insidesales-plus の癖。方向と持ち主が名前で分かる）
- **通信を持つのはページだけ。** ページは `(Model, Effect)` を直接返す。`Out` は `Ui/` の中の Modal や Picker のような「親に伝えるだけ」の部品に限る（子が通信すると id の採番を親に上げる定型コードがページの数だけ積み上がる）
- **純ロジックを Html から切り離す**（Route / Filter / Violation / RichTextDoc など Html を作らないモジュール）。モジュールの doc に「なぜ Main でなくここか」を日本語で書く
- **命名**: Msg は「名詞 + 過去分詞」（`SaveClicked` / `SearchTyped` / `EntryClicked`）、外から届いた値は `Got` 始まり、`Out` の構築子は `Out` 接頭。custom type は状態が排他の所だけ、データの入れ物は型 alias
- **コメントは日本語**。採らなかった案は `WhyNot:` で書く（CMS 側の流儀と同じ）
- **query は全部 `Queries.elm` に置く。** そこに無い物は契約の確認（`npm run contract`）に乗らない。確認は実際に動いている CMS に document を投げ、200 が返るか・errors が無いかを見る。**型が通ってもサーバに拒まれる物**（操作名の食い違い、引数の形、権限）は Elm の型では防げないので、ここで捕まえる
- **テストの fixture は手書きしない。** elm-graphql は同じフィールドを違う引数で選ぶとハッシュ付きの別名を振るので、手書きの JSON はキーが合わずに「謎のデコード失敗」になる。`make run` + curl の実応答を写す
- **richText は `RichTextDoc.elm`（Html を作らない純モジュール）に doc の読み書きを出す。** TipTap の中身は仮想 DOM に無いので elm-program-test では 1 行も試せない
- **テストは 2 系統**: 純ロジックの単体テストと、`avh4/elm-program-test` で Main を丸ごと起動するフローテスト。`Effect -> SimulatedEffect` の変換は本物の `perform` と対にし、封筒の JSON 化は両者で 1 つの関数を共有する（二重に組むと片方だけずれても気づけない）。`describe` は日本語

### 11.2 GraphQL（両取り。2026-09-09 に実物で確かめた）

**確かめた事**（`admin-ui/` で実際に生成して動かした）:

- **SDL を直接食える**（`--schema-file ../admin.graphql`。introspection を取るために CMS を起動する必要は無い）
- `where` は `where_` に自動で逃げる。日本語の description はコメントに入るだけで無害
- **`--scalar-codecs` は必須**。既定の codec は `JSON` を文字列として埋め込むので（`fields: "{\"title\":\"あ\"}"`）、`Json = Json.Decode.Value` / `encoder = identity` の codec を自作する。そうすると **GraphQL のオブジェクトリテラルとして正しく出る**（`fields: {title: "あ", n: 1.5, nil: null, tags: ["a","b"], doc: {...}}`）。入れ子・配列・null・引用符・改行・バックスラッシュの escape も正しい
- **`--base` は 2 本**（`Api.Admin` / `Api.Account`）。2 つの SDL は 10 個の型名を共有するので、同じ base に生成すると壊れる。分ければ同じプロジェクトで共存できる（確認済み）
- 生成物は **86 ファイル**（Admin 65 + Account 21）
- **elm-graphql は GraphQL の variables を使わない**。引数は document に直に埋め込まれる。したがって封筒は `{ id, kind, document }` で、**`variables` は持たない**
- `Me.permissions` / `Viewer.permissions` は `[String!]!` なので型で守られない。`Api/Permission.elm` で custom type に落とし、知らない文字列は捨てる

- **`dillonkearns/elm-graphql` で query と decoder の型を生成**（SDL が正。書き間違いがコンパイルで落ちる）
- **送信は封筒の port に載せる**。`Graphql.Document.serializeQuery` / `serializeMutation` で文字列を、`Graphql.Document.decoder` で decoder を取り出し、`Effect.SendGraphql { id, kind, document, retriable }` にする。URL・認証ヘッダ・再試行は TypeScript 側
- **`requestId` を封筒に通す（P0 で入れる。後付けできない）**: 送る前に Elm が ULID を作って `X-Request-Id` に載せ、返りの封筒にも入れる（TypeScript が応答ヘッダからも読む）。エラーのトーストに id を出し、押すとコピーできる。これが無いとログの行を引けない
- **mutation は再試行しない**。`retriable` を Elm 側が Effect で決め、query だけ再試行する（`createEntry` や `publishMany` は冪等でなく、二重に作られる / Webhook が二重配信される）。下書き保存だけは `expectedVersion` が守るので例外
- **エラーは 2 段で読む**: `Api/Response.elm` が **先に `errors` を読み、次に `data` を読む**。`{ data : Maybe a, errors : List ApiError }` を返す型にする。`Graphql.Document.decoder` に直に食わせると、認証切れ（200 + path 無しの errors 1 件）や部分的失敗が「謎のデコード失敗」になり、13.5 の状態 4 に入れない
- `Api/Error.elm` に `extensions.code` → 型、violations → フォームの項目の写しを置く。**violations のデコーダは 2 本**（`field` キーと `path` キー。10.3）

### 11.3 URL とページ（新規に設計する。両方に無い）

flix_ge_studio は URL ルーティングをしておらず（Main.elm が 15,571 行の 1 枚岩）、insidesales-plus は elm-pages がルーティングを持つ。**どちらも参考にならないので、`Route.elm` を手で書く**。

- `Browser.application` + `Url.Parser`。`Route.elm` に型・parser・`toString` を置き、往復をテストする
- **`Browser.Navigation.Key` を Model に入れない。** `Effect.perform` の capability のレコードで受ける（flix_ge_studio と同じ形）。elm-program-test の `createApplication` は init の第 3 引数に `()` を渡すので、Model に Key を持つと全ページの型に `key` が伝染してテストから起動できなくなる
- **一覧の状態（検索・絞り込み・並び・列・ページ）は URL に持つ**。`Url.Builder` で双方向に（insidesales-plus は書き戻していなくて、絞り込んだ一覧を共有できなかった）
- ページごとに `Model` / `Msg` / `init` / `update` / `view` を持ち、遷移で捨てる。**一覧の Model だけは親が持って捨てない**（6.3 の「戻っても状態が残る」）
- **`Session` は絞る**: 認証済みユーザー・permissions・今のプロジェクトだけ。**読み取り専用の値**にする（トーストは書き換わるので親の Model に置く）。モーダルの開閉やフォームの入力を入れない（insidesales-plus の Shared は 947 行の全部入れで、ページ遷移で閉じ忘れが起きる形だった）

### 11.4 CSS と部品

- **Tailwind v4 + daisyUI**（flix_ge_studio と同じ。elm-css は採らない）。`@source "./**/*.elm"` で Elm の中のクラス文字列を拾わせる
- **daisyUI のテーマを 2 本**（`cms-light` / `cms-dark`）。9 章のダークテーマはこれで実現する
- **トークンは意味で名付ける**（`--color-app` / `panel` / `raised` / `well` / `edge` / `ink` と soft / faint）。insidesales-plus の `fontSize16 = px 16` のような「値そのままの名前」にはしない（値を変える時に全置換になる）
- **`Ui/` に部品の層を作る**（insidesales-plus の `src/UI/` の考え方）。Button / Form / Table / Modal / Toast / Chip / Icon。API は `List (Attribute msg) -> List (Html msg) -> Html msg` で、呼ぶ側が `class` を足して微調整できる形
- **アイコンは `Ui/Icon.elm` に inline SVG**（Lucide 系の線、24px グリッド、線 1.8）。8 章のアイコン一覧が元
- Web Component は TipTap のエディタだけ。Shoelace のような部品集は最初は入れない

### 11.5 フォームと検証

- **`arowM/elm-form-decoder`**（insidesales-plus から）。入力は生の String で持ち、フィールドごとの `Decoder` を `Decoder.lift` で持ち上げ、`Decoder.top` + `Decoder.field` で合成する
- **サーバの違反をフォームに写す層を足す**（insidesales-plus には無かった）。`Api/Error.elm` の violations の path（`fields.sections[0].headline`）を、フォームのどの項目かに解く純粋な関数を書き、テストする
- 表示文言はエラーの種類ごとの関数にまとめる（各項目にベタ書きしない）

### 11.6 ツール

- **vite + vite-plugin-elm**（flix_ge_studio と同じ）。elm-tooling で elm と elm-format を固定
- **elm-review を最初から入れる**（`review/ReviewConfig.elm`）。両方のプロジェクトに無く、後から入れると直す量が増える
- CI は `elm-format --validate` / elm-review / elm-test / build / SDL と生成物のずれの検査（`ui-gen-check`）
- 部品の一覧は elm-storybook を検討（insidesales-plus にある。管理画面は部品の再利用が多い）

## 12. 画面の幅（2026-09-09）

**スマホでフル対応はしない。ただし「PC で開いてください」の壁も作らない。** 作り込まない画面は PC と同じ物をそのまま出し、**スタイルの崩れと横スクロールは許容する**（触れないより崩れて触れる方が良い）。

| 幅 | 出し方 |
|---|---|
| 1024px 以上 | 既定。6 章の枠のまま |
| 768〜1023px（タブレット） | サイドバーは既定で畳む。右のレールは下に回すか、上のボタンで開く引き出しに。一覧の列は減らす |
| 767px 以下（スマホ） | **作り込む画面**（下の表）だけ専用の並びにする。それ以外は PC の並びのまま出し、横スクロールで見る |

### 12.1 スマホで作り込む画面（レビューと承認）

| 画面 | できる事 |
|---|---|
| 自分に割り当てられた一覧 | ステータスと担当者で絞った縦のリスト。件数と公開状態 |
| コンテンツの確認 | 中身を読む（フォームではなく読みやすい並び）。公開中との差分を見る |
| ステータスと担当者の変更 | 下から出るシートで選ぶ |
| 公開前の確認 → 公開 | 違反の一覧を出し、通れば公開。公開終了と予約もここ |
| 画面プレビュー | プレビューの URL を開く |

richText の編集はスマホでもできるが、挿せるのは段落・見出し・リスト・リンク・画像まで。表・ギャラリー・数式・埋め込みのボタンは出さない（doc に入っていれば消さずに保持して表示する）。

### 12.2 作り込まない物

型の編集（API スキーマ）、一覧のテーブルとボード、差分の左右比較、メディアのグリッド、プロジェクト設定。これらはスマホでも PC と同じ物が出て、崩れたまま操作できる。**専用の空画面や案内は出さない。**

## 13. 認証（2026-09-09）

**管理画面はトークンを持たない。** ブラウザの資格情報を CMS が読み、認証はリクエストに 1 回 CMS がやる。管理画面は `viewer { permissions }` を見てボタンを出し分けるだけで、判定もトークンの保管もしない。

### 13.1 ローカル

- CMS を `CMS_AUTH=dev` + `CMS_VERSION=dev` で起動する（`make run`）。この時サーバは **127.0.0.1 にしか bind しない**
- **vite の dev サーバの proxy が `X-Dev-User: <email>` を足す**（`Authorization` ではない）。ブラウザは何も持たず、`http://localhost:5173` を開くだけでログイン済みになる
- **身元の切り替えは proxy に閉じる。** proxy が cookie（`dev_user`）を読んで `X-Dev-User` に写す。cookie を書くのは開発モードの帯の中の小さな JavaScript だけで、**Elm も封筒の TypeScript も dev のヘッダを知らない**。既定値は `.env.local` の `VITE_DEV_USER`
- **本番のビルドに dev が混ざらない事を CI で見張る**: `dist/*.js` を `grep -i 'x-dev'` して当たれば落とす。2 人を同時に見たい時はブラウザのプロフィールを分ける
- email は**小文字で統一する**（CMS は招待側だけ小文字化するので、大文字混じりだと招待が当たらない）
- **役割は DB の membership が決める。** dev でも招待か組織 owner の行が要る。最初の 1 人は `CMS_BOOTSTRAP_OWNER` に自分の email を入れて初回ログイン
- 管理画面のコードに dev 用の分岐を入れない（ヘッダを足すのは proxy の設定だけ）

### 13.2 本番

- **ホストを 2 つに分ける**（Access はホスト単位が実質の単位なので、1 ホストに全部入れると Access を付けた瞬間にコンテンツ API と `/mcp` と `/health` と `/jobs/tick` が同時に死ぬ）:

| ホスト | 出す物 | Access |
|---|---|---|
| `admin.example.com` | 管理画面の静的ファイル、`/account/graphql`、`/p/{slug}/admin/graphql` | **付ける** |
| `cms.example.com` | コンテンツ API（`/graphql`、`/p/{slug}/graphql`）、`/mcp`、`/health` | 付けない |

- 管理画面とそれが叩く管理 API は同じホストなので、**CORS は要らない**（同一オリジンの利点は残る）
- **`/p` を丸ごと CMS に転送しない。** 画面の URL（`/p/{slug}/c/{apiId}`）と API の URL（`/p/{slug}/admin/graphql`）は同じ前置きを共有する。丸ごと転送すると、画面を直接開いた時と再読み込みの時だけ 404 になる（画面の中の移動では気づかない。ローカルで実際に踏んだ）。転送するのは次の 3 つだけで、残りは静的ファイルと `index.html` の SPA fallback:

```
/p/{slug}/admin/graphql
/p/{slug}/graphql
/account/graphql
```
- パスで Access を切る案は採らない（`/p/*/admin/graphql` のワイルドカードが中間にあり、1 文字の設定ミスで保護漏れが起きる）
- `/jobs/tick` は VPS のローカルから叩く（compose は 127.0.0.1 にしか publish しない）。Cloudflare の cron を使う時だけ Access の Service Auth でバイパスし、CMS 側は `X-Jobs-Token` で二重に守る
- 前段に **Cloudflare Access**（`CMS_AUTH=jwks`、`CMS_AUTH_HEADER=Cf-Access-Jwt-Assertion`、`CMS_AUTH_ISSUER` / `CMS_AUTH_JWKS_URL` / `CMS_AUTH_AUDIENCE`）。ブラウザは Access の cookie を持ち、Cloudflare が JWT のヘッダを足す
- **管理画面は `Authorization` を自分で付けない。** リクエストは `credentials: "same-origin"` で投げるだけ
- **セッションが切れた時**: 認証の失敗は HTTP 200 + path 無しの errors 1 件（`UNAUTHENTICATED` / `REQUIRES_LOGIN`）で返る。これを見たら**ページを丸ごと再読み込みする**（`window.location.reload()`）。Access が未ログインを見て自分のログイン画面に飛ばす。Elm の中にログイン画面は作らない
- **ログアウト**は Access のログアウト URL（`/cdn-cgi/access/logout`）へ飛ばす。「自分」メニューに置く
- **Clerk などにする場合**だけ `CMS_AUTH_HEADER=Authorization` にし、管理画面が `Bearer <JWT>` を付ける。付ける場所は**封筒の port の TypeScript 側 1 か所**（Elm は知らない）

### 13.3 管理画面が使わない資格情報

- **API キー**（`X-Api-Key`）は公開サイトと CLI と MCP 用。管理画面は使わない
- **PAT**（`Authorization: Bearer cmspat_…`）は CLI と MCP 用。管理画面は発行の画面（`/account/tokens`）を出すだけで、自分の通信には使わない
- **プレビュートークン**（`X-Preview-Token`）は公開サイトのプレビュー用。管理画面は `createPreviewToken` で作って URL を開くだけ
- 資格情報の読み取り順は PAT → トークンヘッダ → `X-Api-Key` → `X-Preview-Token`。PAT が `Authorization` を先に取るので、Clerk の JWT と PAT は同じヘッダに同居できる（`cmspat_` で始まる Bearer だけ PAT 扱い）

### 13.4 権限の出し分け

`viewer { permissions }` の 8 つ（10.4 の表）で出し分ける。**role で判定しない。** 権限が無い操作はボタンを出さないが、押せてしまった時は `FORBIDDEN` が返るので、トーストで断る形も持つ。

### 13.5 入口の状態（ログイン画面の代わり）

Access を前段に置く限り、**管理画面にログイン画面は無い**。入口で人が見る状態は 5 つで、うちが作るのは 3 と 4 だけ。

| # | 状態 | 出す物 | 誰が出すか |
|---|---|---|---|
| 1 | 起動中（`me` を引いている間） | ロゴと骨組みだけの薄い画面 | 管理画面 |
| 2 | 未ログイン | サインインの画面 | **Cloudflare Access**（文言もロゴも Access の設定） |
| 3 | ログインは通ったがメンバーでない | 「まだどのプロジェクトにも参加していません」+ 今の email + 開き直す + 別のアカウント（Access のログアウト URL へ） | 管理画面 |
| 4 | セッション切れ | 「ログインの有効期限が切れました」+ 入力は保存されていない旨 + ログインし直す（= ページを丸ごと再読み込み） | 管理画面 |
| 5 | ローカル（dev） | 上に「開発モード」の帯と今の身元。`.env.local` の `VITE_DEV_USER` で切り替え | 管理画面 |

Clerk / Auth0 を選んだ時だけ、自前のログイン画面を作る（`Page/Login.elm`）。Access なら作らない。


## 14. 確認の 3 段（2026-09-09）

管理画面は 3 つの段で確かめる。`make ui-verify` が上の 3 つを回す。

| 段 | コマンド | 見る物 |
|---|---|---|
| 型と規則 | `make ui-check` | elm-format、elm-review、elm-test、tsc |
| CMS との契約 | `make ui-contract` | `Queries.all` の document を**実際の CMS に投げて** 200 と errors 無しを見る。型が通ってもサーバに拒まれる物（操作名、引数の形、権限）はここで捕まえる |
| 画面 | `make ui-smoke` | Playwright で **30 項目**を実際にクリック・入力して見る。JS の例外・コンソールのエラー・4xx / 5xx も拾う |
| 探索 | `npm run explore` | 決まった項目ではなく、**違和感を集める**。全画面を一巡し、無い物を開き、0 件にし、幅を変えてはみ出しを見る |

**query を足したら `Queries.elm` に置く。** そこに無い物は契約の確認に乗らない。

**画面を足したら smoke に 1 行足す。** 足さないと、壊れても誰も気づかない。

### これまでにブラウザで見つけた不具合

型では防げず、画面を触って初めて出た物。同じ形の物を疑う時の手がかりにする。

| 症状 | 原因 |
|---|---|
| すべての query が 500 | 匿名の document に `operationName` を別に送っていた |
| 画面の URL を直接開くと 404 | dev の proxy が `/p` を丸ごと CMS に流していた |
| ぐるぐるが止まらない | 読み込み中・見つからない・失敗を `Maybe` 1 つで表していた |
| 保存が丸ごと失敗する | 値を全部文字列で送っていた（richText は doc、select は選択肢） |
| 公開中なのに「公開前の確認」が押せる | 公開する物が無い状態を見ていなかった |
| エディタを開くと中身が空 | 型の定義より先にコンテンツが返ると、種類が分からず全部空になっていた |
| 1 文字の検索が効かない | 2 文字からにしていた（和文は 1 文字で絞る） |


## 15. 見た目の決め（2026-09-09）

**参考にする物を画面ごとに決めた。** 独自の様式を作らず、日常で触っている物に寄せる。

| 対象 | 参考 | 中身 |
|---|---|---|
| 配色とフォント | GitHub（Primer） | ライトとダークの両方。フォントは OS の物（読み込みを待たない） |
| ボード | GitHub Projects | 状態の丸、件数のバッジ、列の説明、カードの左肩に `blogs #7bd760` |
| リッチエディタのツールバー | Contentful | 種類のドロップダウン、区切り線の群、右端に元に戻す |
| 一覧・フォーム | Contentful / GitHub | 表の行は薄い枠、タイトルは黒（青くしない）、主な操作はアクセント色 |
| アイコン | Lucide | 24px の枠、線 1.8、`currentColor` を継ぐ。絵文字は使わない |
| 言葉 | microCMS | API / コンテンツ / メディア（7 章の表） |

### トークン

色は `src/styles.css` の `@theme` にだけ置く。**要素に生の色を書かない。**

```
--color-app / panel / raised / well / edge
--color-ink / ink-soft / ink-faint
--color-accent / link
--color-ok / ok-bg / warn / warn-bg / bad / bad-bg / done
```

ダークは同じ名前を塗り替えるだけで、**状態の色の意味は変えない**（公開中は緑、下書きありは黄、失敗は赤）。

### 部品

画面ごとに書き直さず `src/Ui.elm` に置く。足りなければそこに足す。

`heading` / `sectionTitle` / `note` / `card` / `table` / `headRowOf` / `rowOf` / `chip` / `button` / `ghostButton` / `dangerLink` / `input` / `select` / `field` / `fieldWith` / `gauge` / `tabs` / `avatar` / `spinner` / `empty` / `loadingCard` / `messageCard` / `toast`

### コードブロック

- 色付けは highlight.js。**Flix は自前で定義**（`web/flix-language.ts`）。他は Elm / TypeScript / JavaScript / JSON / GraphQL / SQL / シェル / YAML / CSS / HTML / Markdown / Python / Rust / Go / Java / Kotlin
- 書き味は Zenn と同じで、` ```flix ` と打てばその言語で始まる。コードブロックの中にいる時だけツールバーに言語の選択が出る
- **値の無い属性を落としてから送る。** TipTap は指定していない属性も `null` で持ち、そのまま送ると CMS が断る（実際に断られた）

### 表の列

`Ui.headRowOf` / `Ui.rowOf` に列幅を渡す。**見出しは 1 つずつ包む**（包まずに文字を並べると、CSS の grid が 1 つの物として扱い、見出しが全部くっつく。実際にくっついた）。

## 16. 保存と公開の決め

### 16.1 下書きは自動で保存し、公開は人が押す

**下書きだけ自動保存する**（入力が止まって 3 秒。richtext-note-style §6.8、2026-09-11 に変更）。
エディタの上の帯の「下書き保存」と ⌘S は残す。公開は今まで通り人が押す。

以前は「自動保存はしない」と決めていた。理由と、それが今は当たらない訳:

- 書きかけが勝手に版になる → 下書きの保存（`updateEntry`）は `entry_versions` に行を積まない。
  版が積まれるのは公開と「戻す」の時だけなので、打鍵の記録で履歴は汚れない
- 公開前の確認（必須の未入力、未公開の参照先）を挟む場所が無くなる → 公開は人が押すので変わらない。
  公開中のコンテンツを直すと「公開中 · 下書きあり」になるのは、手で保存した時と同じ
- 途中の状態を相手に見せたくない → 下書きは今も同じプロジェクトの人に見える。ここは残る懸念で、
  自動保存を切る設定は置かない（note と同じ。「閉じたら消えた」の方が実害が大きい）

新しいコンテンツ（`/new`）は最初の保存だけ人が押す。自動で作ると URL の `/new` と実体がずれる。

各社の形（2026-09 に見た物）:

| CMS | 保存 | 公開 |
| --- | --- | --- |
| Strapi | Save（手で押す） | Publish。上の帯に 2 つ並ぶ |
| Payload | Save draft | Publish changes。右のレール |
| WordPress（Gutenberg） | 下書きとして保存 | 公開 → 公開前パネルで確認してもう一度 |
| microCMS | 下書き保存 | 公開。上の右に 2 つ |
| Contentful | 自動保存 | Publish（右のレール） |
| Sanity | 自動保存 | Publish |
| Zenn | 下書き保存 | 公開するのトグル + ボタン |

**保存は Contentful / Sanity 側（自動）、公開は Strapi / Payload / WordPress / microCMS 側（人が押す）を採る。**
下書きと版が分かれているので、自動保存で版は汚れない。

**Zenn のトグルは採らない。** 記事 1 本の公開・非公開を切り替えるだけならトグルは分かりやすいが、
CMS の公開は確認（必須の未入力、未公開の参照先）を挟む。押した瞬間に状態が変わる形だと、
確認を出す場所が無くなる。代わりに、押せる・押せないと文字（「公開する」/「変更を公開する」）で
今どちらに動くかを出す。

### 16.2 上の帯（`Page.Editor.viewActionBar`）

画面を送っても付いてくる（`sticky top-0`）。長いフォームでも保存が画面の外に出ない。

```
[ タイトル      ] [下書き] [未保存]              [ 下書き保存 ] [ 公開する ]
[ /blogs        ]
```

- 左: 題（型の最初のテキストのフィールド）、API の名前、公開状態の印、保存の様子
- 右: 「下書き保存」（未保存の時だけ押せる。`⌘S` / `Ctrl+S` でも同じ）と「公開する」
- 「公開する」の文字は状態で変わる。下書き → 「公開する」、公開中 · 下書きあり → 「変更を公開する」
- 公開中で変更が無ければ「公開する」は押せない（押しても何も変わらない）

### 16.3 公開は保存の後

「公開する」を押した時に未保存が残っていれば、**先に下書き保存を済ませてから**公開前の確認を開く
（`Editor.pendingPublish`）。人に 2 回押させない。公開されるのは保存済みの下書きなので、
ここを飛ばすと「押したのに古い内容が公開された」が起きる。

確認は書き込まない（`publishCheck`）。結果が出てから、その画面の中で「公開する」をもう一度押す
（WordPress の公開前パネルと同じ 2 クリック）。

### 16.4 離脱の警告

保存が人任せになったので、未保存のまま閉じると書きかけが黙って消える。
`Effect.SetUnsaved` → port `setUnsaved_Editor_JS` で JS に印を渡し、`beforeunload` で止める。
Elm から `beforeunload` は触れないので JS 側に置く。画面を移った時（`UrlChanged`）は印を下ろす。

`⌘S` の既定（ブラウザの「ページを保存」）も JS の capture で止める。
`Browser.Events.onKeyDown` は preventDefault できないので、**止めるのは JS、動くのは Elm**に分ける。

## 17. API プレビュー

**専用のタブや画面は作らない。** 右から出る引き出し（`Page.Preview`）で、
コンテンツ一覧と 1 件の編集の両方から開く。

| CMS | 置き方 |
| --- | --- |
| microCMS | 一覧・詳細の「API プレビュー」ボタン → 別の面 |
| Sanity | 詳細の Inspect（Ctrl+Alt+I）→ 重なる面 |
| Directus | 詳細の「…」→ raw JSON の引き出し |
| Payload | 詳細の API タブ |
| Storyblok | 詳細の Draft JSON / Published JSON |

**多数派は「今見ている物のすぐ横で開く」。** API を見るのは今の物を確かめる作業で、
別の場所へ移る作業ではない。ナビゲーションのタブにすると、確かめる度に画面を離れる事になる。

  - **一覧**: 見出しの行の「API」→ その型の一覧の query
  - **1 件**: 編集の上の帯の「API」→ その 1 件の query（公開中でなければ `stage: DRAFT`）

引き出しは URL に持たない（重ねる物で、行き先ではない）。

### 17.1 一覧と 1 件

人が API を使う時の 2 通りを、引き出しの中の切り替えにする。

| | query | 引数 |
| --- | --- | --- |
| 一覧 | `<plural>(…) { totalCount nodes { … } }` | `first`（5 / 10 / 20 / 50）、`stage` |
| 1 件 | `<singular の頭を小文字>(id: "…") { … }` | `id`（一覧から選ぶ）、`stage` |

1 件のフィールド名は型名の**先頭 1 文字だけ**を小文字にした物（`Blog` → `blog`、
`BlogPost` → `blogPost`）。snake には落とさない。そのために `ContentTypeDetail` に
`singular` を足した。

「下書きも読む」を入れると `stage: DRAFT` が付く。匿名では読めないので、
ログインしている管理画面から投げる時だけ通る。

### 17.2 query の組み立て

型の定義から作る。フィールドの選び方は種類で決まる。

| FieldKind | 出す物 |
| --- | --- |
| TEXT / TEXT_AREA / SLUG / NUMBER / BOOLEAN / SELECT / DATE | そのまま |
| RICH_TEXT | `{ html text }` |
| REFERENCE | `{ id }` |
| ASSET | `{ id url fileName mime width height alt }` |
| OBJECT / BLOCKS | **出さない**（入れ子の形が型の一覧からは決まらない） |

出さなかったフィールドは名前を下に並べる。**query は書き換えられる**ので、人が書き足せる。
書き換えた後は型から作り直さない（書いた物を消さない）。「型から作り直す」で戻せる。

### 17.3 応答は生のまま

`Api.preview` は `Api.read` を通さず、応答の全体（`errors` 込み）をそのまま渡す。
プレビューは実物を見せる画面なので、失敗を人が読める形に畳んでしまうと意味が無い。
HTTP の番号も印で出す。

`curl` の 1 行も出す。**API キーは画面に出さない**（出すと共有されて漏れる）。
公開中の物は鍵無しで読めるので、その形で通る。

## 18. API スキーマの画面

9 社（Contentful / Sanity / Strapi / Payload / Storyblok / Directus / Prismic / microCMS /
Hygraph）を調べて決めた。

### 18.1 調べて分かった多数派

| | 多数派 | 少数派 |
| --- | --- | --- |
| 並び替え | 掴んで動かす（8 / 9） | 上下ボタンだけ: **0 社** |
| 掴む所 | 行の左端 | — |
| 編集を開く場所 | 一覧を離れない（GUI の 7 社すべて） | 別ページ: **0 社** |
| 編集の器 | 右のペイン / ドロワー（Directus / Hygraph / Storyblok）、モーダル（Contentful / Strapi） | 一覧の下: **0 社** |
| 設定の保存 | 人が押す（6 / 8） | 即時（Directus / Hygraph） |
| 種類の選び方 | アイコン付きの札を分類ごとに（Directus は 6 分類、Hygraph はパレット、Strapi はアイコン一覧） | ドロップダウン（Storyblok / microCMS） |
| 種類・API 名の変更 | **できない**（全社） | — |

### 18.2 決め

**左に一覧、右に設定の 2 ペイン。** モーダルにも覆いのドロワーにもしない
（仕様 6 章の「モーダルは 1 段まで・確認だけ」に従う。一覧を見ながら次を足せる）。

  - **並び替えは掴んで動かす。** 掴む所は行の左端（Directus / GitHub / Notion）。
    落とした時に `reorderFields` を 1 回投げる。上下ボタンは持たない
    （1 クリックごとに往復する上、10 個下げるのに 10 回押す事になる）
  - **行のどこを押しても右のペインが開く。** 右端の小さな「編集」だけが的だと遠い
  - **追加も右のペインで完結する。** 「+ フィールドを追加」で種類のパレットに変わり、
    種類を押すとそのまま名前の入力に進む。**種類を先に選ばせる**（後から変えられないため）
  - **種類はアイコン付きの札を 5 分類で並べる**（文字 / 数・真偽・日時 / 選ぶ・つなぐ /
    メディア / 入れ子）。`<select>` の 12 行では「オブジェクト」と「ブロック」の違いが読めない
  - **設定の保存は人が押す。** 直すと行の題の横に「未保存」が出る。
    送るまで一覧には反映しない（送る前の値が一覧に出ると、保存し忘れに気づけない）
  - **並び替えだけは即時**（落とした時に送る）。壊れない操作は即時、
    途中の状態を送ると `INVALID` を撒く操作は明示、で分ける

### 18.3 設定フォームに出す物

9 社に共通する項目に揃えた。**CMS が持っているのに画面から使えなかった `FieldConfig` を
全部出す**（無いのと同じだった）。

| 区切り | 項目 |
| --- | --- |
| 基本 | 表示名、フィールド ID（読むだけ）、種類（読むだけ） |
| 入力の決まり | 必須、重複不可 |
| この種類の設定 | TEXT / TEXT_AREA / RICH_TEXT: 文字数の上限、NUMBER: 最小・最大・整数だけ、SELECT: 選択肢、SLUG: 元にするフィールド |
| 危ない操作 | 削除（線で区切って下に離す） |

`config` は CMS 側で**丸ごと置き換わる**ので、送る時は今の値を全部詰める
（触っていない項目を省くと消える）。

**`localized` は出さない。** `FieldDef` に印はあるが、読む所がまだ無い
（コンテンツ API に locale の引数が無く、entry の中身も言語で分かれていない）。
入れても何も変わらない物を選ばせない。多言語を入れる時に、印と一緒に画面へ出す。

### 18.4 まだ入れていない物

調べた中で「あると良い」と分かったが、CMS 側が足りない物。

| 物 | 出どころ | CMS に要る物 |
| --- | --- | --- |
| 2 段階の削除（API から隠す → 消す） | Contentful が「間違えると壊滅的」として実装 | `FieldDef.hidden`、`fieldImpact` |
| 説明文と初期値 | 9 社中 8 社が持つ | `FieldConfig.description` / `defaultValue` |
| OBJECT / BLOCKS の入れ子の編集 | Directus / Storyblok | 子フィールドの並び替え |
| 選択肢の安全な付け替え | 消すと公開中のコンテンツが壊れる | `replaceSelectOption` |
| スキーマの JSON 書き出し / 読み込み | microCMS。移行の敷居が下がる | 不要（既存の mutation で組める） |
| 多言語（`localized` を効かせる） | Contentful / Storyblok / Hygraph は標準 | コンテンツ API の locale 引数、entry の中身を言語で分ける |
| フィールドの複製 | Directus | 不要（`addField` の再利用） |

**採らない物**: 条件付き表示（4 社が持つが、効くのは大きい型だけ）、
コードをスキーマの正とする流儀（Sanity / Payload。非エンジニアが型を触れる事が売りなので）、
全フィールドまとめて 1 回の保存（Strapi。CMS の mutation がフィールド単位で、
途中失敗の後始末ができない）。

## 19. コンテンツ同士の繋がりとメディア

見本データ（`admin-ui/scripts/seed.mjs`）に、**参照の 1 件と複数、メディアの 1 枚と複数**を
全部入れてある。片方しか無いと、画面がその形を扱えているか確かめられない。

| 形 | どこ | 中身 |
| --- | --- | --- |
| 参照 1 件 | ブログ → 著者 | `REFERENCE`。セレクトで 1 つ選ぶ |
| 参照 複数 | ブログ → タグ | `REFERENCE` の `many`。チップで出し、押して外す |
| メディア 1 枚 | ブログのアイキャッチ、著者の顔写真 | `ASSET`。サムネイルと「差し替える」「外す」 |
| メディア 複数 | ブログの本文中の図 | `ASSET` の `many`。並べて出し、「メディアから足す」 |

### 19.1 タグはコンテンツにする

`SELECT` の選択肢ではなく、`tags` という**型**にした。

  - 選択肢は UPPER_SNAKE しか置けない（CMS の決まり。`optionLabels` がまだ無い）
  - 説明を付けられない
  - タグだけを一覧で直す・増やす、ができない

コンテンツにすれば名前も説明も自由で、タグの一覧・編集がそのまま使える。
その代わり、絞り込みの値は**タグの entry id** になる（見出しは名前）。
一覧のセレクトは参照先の中身を引いて作る（`Entries.tagOptionCalls`）。

### 19.2 見出しの決め方は 1 か所

参照のチップ・ボードのカード・一覧・⌘K の候補が、同じ `EntryLabel` を使う。
画面ごとに書くと、同じコンテンツが場所によって違う名前で出る。

  - 型が分かる時は **最初のテキストのフィールド**（`byField`）
  - 分からない時（参照先の一覧）は `name` → `title` → `label` の順（`forRow`）

**`name` を `title` より先に見る。** 著者のように両方持つ型では `title` が肩書で、
名前ではない（実際に著者が「テクニカルライター」と出た）。

CMS に `ContentType.titleField` が入ったら、この決め方は捨てて型の設定に従う。

### 19.3 メディアは開いた時に引く

`ASSET` のフィールドがある型では、エディタを開いた時に asset の一覧を引く。
ピッカーを開いた時だけだと、既に入っている画像が id の文字のまま出る。

## 20. 一覧の絞り込み

9 社（Contentful / Sanity / Strapi / Payload / Storyblok / Directus / Prismic / microCMS /
Hygraph）を調べて決めた。

### 20.1 何が悪かったか

`tags` という apiId のフィールドだけを名前で特別扱いし、固定のセレクトを 1 つ出していた。

  - フィールドを `categories` や `topics` と名付けたプロジェクトには絞り込みが 1 つも出ない
  - 参照が 3 本ある型でも 1 本しか絞れない。1 件だけの参照（著者）でも絞れない
  - 条件が 1 つしか持てない。CMS の `EntryWhere.fields` は元から**配列**で受けるのに、
    画面が常に 1 要素しか入れていなかった
  - CMS の 10 個の演算子のうち 2 つ（`EQ` / `ARRAY_CONTAINS`）しか使っていない。
    日時の範囲・数の大小・「未入力」で絞れなかった
  - 参照の候補を `first: 100` で先読みしていたので、**101 件目のタグは絞り込めない**。
    しかも失敗を握り潰していて、空のセレクトが残る
  - 絞った結果を確認できない（列が固定で、絞った項目の列が無い）

**調べた 9 社に「特定の名前のフィールド」を見る例は 1 つも無い。** Sanity はスキーマを
深さ 3 で再帰展開し、Payload は `reduceFieldsToOptions`、Strapi は除外する型の一覧、
Hygraph は不可の型の列挙で、**どこも種類で機械的に決めている**。

### 20.2 決め

**条件を足していく形**（`src/Filter.elm` ＋ `Page.Entries`）。9 社中 6 社がこの形で、
固定のセレクトだけなのは Prismic だけ。そこも任意のフィールドでは絞れず、公式の
ロードマップに「高度な検索」が積み残っている。

```
[🔍 中身を検索] [すべての状態 ▾] [+ 絞り込み]            [更新日時の新しい順 ▾]

 ● タグ 設計 を含む ×   ● 公開日 2026-08-10 以降 ×   条件をすべて外す

 [ タイトル ▾ ] [ を含む ▾ ] [ 移行        ]  (絞り込む) (閉じる)
```

`+ 絞り込み` を押すと **項目 → 演算子 → 値** が 1 行に出る。足した条件はチップで並び、
押すと 1 つずつ外れる。

**AND だけで出す。** GUI で OR を組めるのは Payload と Directus の 2 社だけで、
CMS の `EntryWhere` も AND なので、標準から外れない。

### 20.3 言葉の原則（2026-09-09 に付け直した）

**演算子は「値の後ろに置いて文が終わる述語」にする。** 言い回しは microCMS の管理画面に
合わせた（15 章「言葉は microCMS」）。だから**チップは 項目 → 値 → 演算子**の順に描く。
選ばせる順（項目 → 演算子 → 値）と描く順が違うのは、日本語の語順がそうだから。

| 読み | 良い | 悪い（〜2026-09-08） |
| --- | --- | --- |
| 等値 | タイトル **移行** と一致する | タイトル **が** 移行 ← 文が終わらない |
| null | 本文 **未入力** | 本文 **が未入力** ← 「が」が浮く |

**入口と出口の言葉**も付け直した。「足す」「やめる」は何が起きるか読めなかった。

| 前 | 後 | 理由 |
| --- | --- | --- |
| 足す | **絞り込む** | 何が足されるかではなく、押した結果を言う |
| やめる | **閉じる** | 作りかけの条件を捨てるのか絞り込み全体をやめるのか読めなかった。押すと閉じるだけで、かかっている条件は残る |
| 全部消す | **条件をすべて外す** | チップを外すのと同じ動詞に揃える |
| 「項目」「条件」「値」の 3 ラベル | **置かない**（`aria-label` だけ） | 高さが 2 倍になり、狭い画面で見出しと入力がずれる。Notion / Strapi / Sanity / Airtable も置いていない |

**確定はボタンを押す**（`絞り込む`）。即反映の流派（Notion / Airtable / Linear / Sanity）と
明示ボタンの流派（microCMS「適用する」/ Strapi `Add filter`）があるが、条件が URL に乗る
作りなので、打っている途中で URL と一覧が更新されない明示ボタンを採る。
**値が要るのに空なら押せない**（前は押しても黙って何も起きなかった）。

### 20.4 種類ごとの演算子

**CMS が実際に SQL に落とせる組だけ**を出す（落ちない物は INVALID で断られる）。

| 種類 | 出す演算子（この順で出す。先頭が既定） |
| --- | --- |
| TEXT / TEXT_AREA / SLUG | を含む / と一致する / で始まる / 未入力 |
| NUMBER | と一致する / 以上 / 以下 / より大きい / より小さい / 未入力 |
| DATE / DATE_ONLY | 以降 / 以前 / と一致する / 未入力 |
| BOOLEAN | である（はい・いいえ）/ 未入力 |
| SELECT（単一）・REFERENCE（単一） | と一致する / 未入力 |
| **複数の値を持つ物すべて** | **を含む / 未入力**（CMS は `ARRAY_CONTAINS` しか通さない） |
| ASSET / RICH_TEXT | 未入力だけ（本文は検索窓に任せる） |
| **更新日時 / 作成日時 / 公開日時** | **以降 / 以前 / より後 / より前** |
| OBJECT / BLOCKS | **項目に出さない**（入れ子の形が決まらない） |

演算子 1 つに対する言葉の表（`Filter.opText` と `Filter.dateText`）:

| op | 既定 | 日時（DATE / DATE_ONLY / システムの日時） |
| --- | --- | --- |
| `EQ` | と一致する（真偽だけ「である」） | と一致する |
| `CONTAINS` / `ARRAY_CONTAINS` | を含む | — |
| `STARTS_WITH` | で始まる | — |
| `GTE` | 以上 | **以降** |
| `LTE` | 以下 | **以前** |
| `GT` | より大きい | **より後** |
| `LT` | より小さい | **より前** |
| `IS_NULL` | 未入力 | 未入力 |
| `IN` | のいずれか | — |

### 20.5 どの型も持つ日時（2026-09-09）

`EntryWhere` が `createdAt` / `updatedAt` / `publishedAt` を `DateTimeFilter` で受けるように
なったので、**項目に戻した**（「先週更新された記事」が引ける）。調べた全社が持っている。

- **入れ物は 1 つのまま。** この 3 つは `Naming.reservedFieldApiIds` にあり、型のフィールドに
  付けられない名前なので `apiId` がぶつからない。URL・チップ・画面は 1 種類の条件として
  扱い、`fields` と `where` 直下に分かれるのは `Queries.whereOf` だけ
- **大小しか出さない。** `DateTimeFilter` は `gt` / `gte` / `lt` / `lte` だけで、等値と未入力を
  写す先が無い。だから `Filter` の種類も `DATE` と分けて `SYSTEM_DATE` にしてある
- **入力は `<input type="date">`。** `datetime-local` は並びも曜日もブラウザの言語で決まるので
  使わない。`Ui.DateTime` は `Time.Zone` を要り、それを配れるのは `Main` だけなので今は使わない
  （日付だけで送っても CMS は ISO 8601 として読む）
- **相対の期間（今日 / 過去 7 日 / 今月）は入れていない。** Notion（`past_week` ほか）・
  Airtable（`is within the past week`）・Sanity（`last N days`）が持っており価値はあるが、
  URL に相対のまま持って**開くたびに解き直す**必要があり、ページに時刻の effect が要る。
  次に回す

### 20.6 並び替え（2026-09-09）

**表の見出しを押して並べ替える。** 見出し側だけを持つのが Jira / microCMS / Strapi、
メニュー側だけが Linear / GitHub Issues / Notion。**こちらは両方**を持つ。

- **押せる列**: タイトル（`EntryLabel.byField` と同じ最初のテキストのフィールドで並べる）と
  更新日時。**公開状態は押せない**（`stage` は `EntryOrderBy` の組み込みのキーに無く、
  フィールドとして読まれて全部 NULL になる。断られないまま何も起きないので押せる形にしない）
- **矢印は並べている列にだけ出し**、他の押せる列はホバーで薄く出す。常時表示を勧める
  デザインシステムは 1 つも無く、Material / Carbon / Fluent が揃ってこの形
- **2 段階**（昇順 ⇄ 降順）で、**最初に押した時は昇順**（Primer: "unsorted columns sort in
  ascending order on first click"）。3 段階は Carbon だけ
- 見出しは `<button>`（W3C APG / Primer / Carbon / Fluent が一致）。矢印は `aria-hidden`
- **セレクトは残す。** 幅 1024 未満で更新日時の列が畳まれると見出しから並べられず、公開日時と
  フィールドはそもそも列に無い。Primer も狭い画面では別の道を残せと書いている
- **既定（更新日時の降順）は URL に書かない。** 同じ並びを空と `updatedAt:desc` の 2 通りで
  表すと、見出しから並べ替えた時にセレクトの選択と食い違う

**並び替えの言葉**は「項目名 ＋ の ＋ 向き」で、**間に空白を入れない**（前は「題 の昇順」）。
向きは種類で言い分ける（この分け方は Excel の日本語）。

| 種類 | 昇順 | 降順 |
| --- | --- | --- |
| 日時（DATE / DATE_ONLY / 更新・作成・公開日時） | の古い順 | の新しい順 |
| 数 | の小さい順 | の大きい順 |
| 文字（TEXT / TEXT_AREA / SLUG） | の昇順 | の降順 |

### 20.7 参照の値は候補から選ぶ

**打つたびに引き直す**（`search` で 20 件）。先読みした固定の一覧は、参照先が増えると
静かに壊れる。候補を持つ 4 社（Payload / Sanity / Storyblok / microCMS）は全部これで、
打たせている 2 社（Strapi / Directus）はどちらも要望が立っている。

URL から戻した条件の見出しは `EntryWhere.id_in` で**要る id だけ**引く。

### 20.8 URL に持つ

条件は `f` の 1 つの query に畳む。区切りは `,` と `:` で、値は percent encode する。

**`~` は区切りに使えない**（`Url.percentEncode` が変えない文字なので、値に `~` が
入ると往復が壊れる。実際に壊れた）。apiId は lowerCamel、演算子は大文字と `_` だけなので、
そちらには出てこない。

保存ビュー（名前を付けて残す）は後回し。**URL に残る方が先**で、Directus は保存ビューを
持つのに URL に残らず不満が出ている。

## 21. 被リンク（このコンテンツはどこから参照されているか）

持っているのは調べた 9 社のうち Contentful / Sanity / microCMS の 3 社だけ。
どれも「エディタ体験で選ばれる CMS」で、Sanity は 2026 年に入ってから公式機能として入れた
（v5.8.0）。標準になりつつある領域。

### 21.1 なぜ要るか

**この CMS は既に「止める」側**だった。公開中の他のコンテンツから参照されていると、
CMS が公開の取り下げも削除も断る（`publishedReferrerViolations`）。microCMS と同じ
最も厳しい振る舞い。

なのに画面には何も出しておらず、**押して初めて理由を知る**状態だった。
9 社の中で最も強い制約を、最も説明しない形で課していた。

### 21.2 出し方

エディタの右のレールに出す。詳細画面から見えるのは 3 社とも同じ（Contentful は
サイドバー、Sanity は inspector、microCMS は右上のバッジ → モーダル）。一覧の列に出す社は無い。

```
参照されています（4）
  公開中の参照
   ETag で GraphQL の GET を返さない        tags
   予約公開をチャンクで回す                  tags
  下書きの参照
   ETag で GraphQL の GET を返さない        tags
   予約公開をチャンクで回す                  tags
  公開中の参照があるうちは、公開を終える事も削除する事もできません。
```

**下書きと公開を分ける。** Sanity は畳んでいるが、この CMS は**取り下げを止めるのは
公開側の参照だけ、削除は両方**と判定の根拠が stage で違うので、畳むと「なぜ止まったか」が
説明できない。

**どのフィールド経由かを出す**（右端の `tags`）。リッチテキストの本文中のリンクの事もある。

### 21.3 今は `impact` を借りている

素の被リンクの口が CMS に無いので、`impact(id, action: DELETE)` の `breaks` を使っている
（＝「公開側と下書き側の両方で参照している entry」＝被リンクそのもの）。

**制限**: ページングも件数の上限も無く、参照元 1 件ごとに entry と型を引く N+1。
参照は `entry_links` の写しの表にあり、逆引きの索引 `(to_entry_id, stage)` も既にあるので、
CMS に足すのは `LIMIT/OFFSET` と `COUNT(*)` だけ。

```graphql
type Entry {
  referencedBy(stage: ContentStage, first: Int = 100, skip: Int = 0): ReferrerPage!
  referencedByCount: Int!   # バッジ用。一覧を引かずに数だけ
}
```

入ったら差し替える。`impact` は「操作の影響」という別の意味を持つので残す。

## 22. API のアイコン

サイドバーと一覧に出る、API（content type）ごとのアイコン。**人が選び、何度でも選び直せる**
（Notion のページの絵文字、Directus のコレクションのアイコン、Sanity の `icon`、
Storyblok のブロックのアイコンと同じ）。

### 22.1 絵文字ではなく線のアイコン

Notion は絵文字だが、拡大と再着色ができず暗いテーマで沈む。仕様 8 章の決め
（絵文字を使わない・`currentColor` を継ぐ）に従って、用意した 18 個の線のアイコンから選ぶ。

一覧 / 1 枚 / 本 / お知らせ / タグ / 人 / 画像 / 動画 / 商品 / おすすめ / 場所 /
予定 / 声 / 質問 / 箱 / コード / 数字 / 目印。

### 22.2 持ち方

CMS の `ContentType.icon`（`String!`。null は返らない）に**名前**を入れる。
絵そのものは管理画面が持ち、サーバは名前の形しか見ない。

  - 受ける形は `[a-z][a-z0-9-]*` の 32 文字まで。規則外は INVALID
  - 既定は種類で決まる（`COLLECTION` → `list`、`SINGLETON` → `file`）。
    この列より前からある型にも既定が入っている
  - `Ui.Icon.byName` は**知らない名前を一覧のアイコンに落とす**（CMS が名前を増やしても壊れない）

### 22.3 選ぶ所

API スキーマの画面の**題の左**。押すと右のペインがアイコンのパレットに変わり、
押した時点で送る（選ぶだけの操作なので、別に保存を押させない）。

`updateContentType` は**省いた項目を触らない**ので、アイコンだけ送る時も `name` は
今の値をそのまま渡す。「既定に戻す」は空文字ではなく `list` / `file` を明示して送る
（空文字は INVALID）。

## 23. エディタのフィールドの見せ方（2026-09-09）

`src/Page/Editor.elm` の `viewField` が持つ、種類ごとの入力の形。
microCMS / Contentful / Sanity / Strapi / Payload / Storyblok / Notion の
入稿画面を調べて決めた。

### 23.1 動詞の表

同じ意味に同じ言葉を当てる。**言葉で可逆・不可逆を分け、色では分けない。**

| する事 | 言葉 | 見た目 |
|---|---|---|
| 空の欄に選ぶ | 「メディアを選ぶ」「日時を選ぶ」「日付を選ぶ」 | `Ui.ghostButton` |
| 1 件の値を入れ替える | 「選び直す」 | `Ui.ghostButton` |
| 複数の欄に足す | 「メディアを追加」／探す欄に打つ | `Ui.ghostButton` / `Ui.input` |
| 繋がっている物を外す（可逆） | 「外す」／チップの `×` | `Ui.quietActionLink`（**赤にしない**） |
| 値そのものを消す（可逆） | 「消す」 | `Ui.quietActionLink`（**赤にしない**） |
| 物を本当に消す（不可逆） | 「削除」 | `Ui.dangerLink` ＋ 確認 |

調べた 6 社のうち、フィールドから外す操作を赤くしているのは Sanity だけ。
Contentful / Strapi / Payload / microCMS は**語彙**（Remove / 解除 / `×` と
Delete / 削除）と**確認の有無**で分けている。赤を「外す」に使うと、
本当に消える操作と見分けが付かなくなる。

microCMS も解除に「削除」を使わず「選択が解除されます」と書き、
「削除」は繰り返しフィールドの「フィールドを削除」に取ってある。

### 23.2 空の時

**「選ばれていません」のような独立した行を置かない。** 調べた 6 社に 1 つも無い。
Contentful は追加ボタンだけ、Sanity と Strapi は入力欄の placeholder に畳む。

- 参照 → 探す欄の placeholder（「検索…」）が担う
- メディア → ボタンの文字（「メディアを選ぶ」）が担う
- 日時・日付 → 「日時が入っていません」を値の場所に出す（押す物ではないので文で出す）

**件数はラベルに付ける**（`タグ（2）`）。Strapi と同じ位置。0 件の時は付けない。

### 23.3 縦の並び

**ラベル（件数）→ 選んである物 → 足す・探す**（Contentful / microCMS と同じ）。

WhyNot: 探す欄を選んである物の上に置かない。開いた候補の一覧が下に垂れて、
今足した物を覆い隠す（実際に隠れて押せなくなった）。

### 23.4 種類ごと

| 種類 | 入力 | 選んだ物 | 空の時 |
|---|---|---|---|
| `TEXT` | 1 行の入力（`max-w-96`）。上限があればラベルの横に残り字数 | — | — |
| `TEXT_AREA` | `min-h-24` のテキストエリア | — | — |
| `SLUG` | 等幅の 1 行。元にするフィールドがあれば placeholder に出す | — | — |
| `NUMBER` | `type=number`（`max-w-40`） | — | — |
| `BOOLEAN` | `Ui.checkbox`（ラベルは「はい」） | — | — |
| `SELECT`（単一） | `Ui.select`。先頭は「選んでください」 | — | — |
| `SELECT`（複数） | 選択肢のチップを押して切り替え。**選んだ物は枠と文字色を変える** | チップ | — |
| `DATE` | 「日時を選ぶ」→ `Ui.DateTime.view`（暦＋時刻）→「この日時にする」 | 手元の時刻で `YYYY-MM-DD HH:MM` | 「日時が入っていません」 |
| `DATE_ONLY` | 「日付を選ぶ」→ `Ui.DateTime.viewDate`（**時刻の行なし**）→「この日付にする」 | `YYYY-MM-DD` をそのまま | 「日付が入っていません」 |
| `ASSET`（単一） | 見え姿 →「メディアを選ぶ」／「選び直す」＋「外す」 | サムネイル＋ファイル名＋大きさのカード | ボタンだけ |
| `ASSET`（複数） | カードを並べ、下に「メディアを追加」 | 同じカード。**1 枚ごとに「外す」を中に置く** | ボタンだけ |
| `REFERENCE` | チップ →「検索…」の欄 → 候補の一覧 | チップ（押すと外れる） | placeholder |
| `RICH_TEXT` | `tiptap-editor` の custom element | — | — |
| `OBJECT` / `BLOCKS` | **編集できない断りを出す**（値はそのまま保つ） | — | — |

### 23.5 日時と日付

- `DATE` の値は **`2026-09-09T00:00:00Z` ちょうど 1 通り**。CMS はミリ秒付き・
  オフセット付き・秒なし・日付だけを断る。`Ui.DateTime.toIso` がこの形を出す
- `<input type="datetime-local">` は使わない（`2026-09-09T09:00` を出すので必ず断られる。
  並びと言語がブラウザ任せなのは `Ui/DateTime.elm` の doc の通り）
- `DATE_ONLY` の値は **`YYYY-MM-DD`**。`Ui.DateTime.toIsoDate` が出す。
  **UTC に直さない**（時刻を持たない値を時差で動かすと日がずれる）。
  出す時も文字列のまま出す
- 暦を動かしただけでは値を書かない。「この日時にする」を押した時だけ書く
  （そうしないと、任意の欄が月送りだけで埋まって空に戻せない）
- 既に入っている非 canonical な値（`...T09:00:00.000Z` など）でも落ちない。
  `Ui.DateTime.formatLocal` は読めない形をそのまま出す

### 23.6 参照の候補は打つ度に引く

先読みした一覧を手元で絞る形にしない。**101 件目以降を選ぶ手段が画面から消える。**

- 欄に焦点が当たった時と、1 文字打つごとに `entries(search:)` を投げる（`first: 20`）
- **今 打ってある文字への答だけを採る**（先に投げた検索が後から返ると、絞った候補が広い方に戻る）
- 選んである物の見出しは `ids:` で名指しして引く。**検索の結果に居なくても必ず出す**
- 候補 0 件は 2 通りに分ける。打っていなければ「まだ 1 件もありません」＋その型を作る導線
  （**別のタブで開く**。同じタブだと書きかけを捨てる事になる）、打っていれば「見つかりません」
- 外を押したら閉じる層（`Ui.dismissLayer`）は **z-20 の入れ物に包む**。素の z-30 のまま置くと
  上の帯（z-30）と同じ高さになり、候補を開いている間は「下書き保存」が押せない

### 23.7 メディアは指している物が見つかるまで頁を追う

CMS のメディアの一覧は新しい順で、1 頁は 60 件。古いメディアを入れてある entry では
1 頁目に居らず、**サムネイルの代わりに id の文字が出ていた**（手元に 265 件ある状態で出た）。

`Page.Editor.assetCalls` が、この entry の指す id（フィールドの値と、本文の
`attrs.assetId`）が全部そろうまで次の頁を引く。上限は 600 件
（入れた物が消されていると、いつまでも見つからないため）。

**本筋の直し方は CMS 側**で、`assets(ids:)` か `asset(id:)` を Queries に足して
名指しで引けるようにする。今は一覧の頁送りで代用している。

### 23.8 バージョン履歴の言葉

版が積まれるのは**公開した時**と**保存した時**の 2 つで、1 つの一覧に混ざる。

- 見出しは「バージョン履歴」。1 行 1 行は差分ではなく**その時点の中身**（後で戻せる物）
- 行は `v3` ＋「公開した」／「下書きを保存した」。「版」は行の頭の `v3` が既に表している
- この行に後から「誰が」と「戻す」が並ぶ前提で選んだ

### 23.9 まだ足りない物

- `OBJECT` / `BLOCKS` の入力（今は断りを出すだけ）
- 複数の並び替え（microCMS / Contentful / Sanity / Strapi は全部ドラッグで並べ替えられる。
  参照とメディアの配列順は API の応答順になるので、いずれ要る）
- メディアのピッカーに検索と頁送り（今は引けている分だけを並べる）
- `Ui.checkbox` は四角。調べた CMS の多くは真偽値をトグルのスイッチで出す
