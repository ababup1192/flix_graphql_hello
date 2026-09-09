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
| **表** | ある（結合と分割も） | **入れた**（結合は無し） | `table` / `tableRow` / `tableCell` / `tableHeader` | 済。**結合は CMS 側の口が要る**（`toHtml` が colspan / rowspan を出さない） |
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
| コードブロックの言語 / ファイル名 | ある | **言語とファイル名** | `language` / `fileName` / `highlightLines` | ファイル名は済（受けない形は帯の中で断る）。強調行は画面が未対応 |
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

ボタンが 16 個になったので、狭い幅では**行を折り返す**（`flex-wrap: wrap`）。
「…」に畳まないのは、畳んだ物は押すまで何があるか分からず、本文の飾りは押す前に見えている方が速いため。

実測（2026-09-09、本文の枠の幅 = ツールバーの幅）:

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
| 変更履歴 / 差分 / この版に戻す | versions / diff / restoreVersion | |
| ステータス / 担当者 | workflow status / assignee | |
| レビュー | ステータスの既定の 1 つ（In review → 「レビュー中」） | 既定は「下書き → レビュー中 → 承認済み」 |
| メディア | asset | |
| メンバー / 権限 | members / role | 権限は「管理者 / 編集者 / 投稿者 / 閲覧者」（owner / editor / writer / viewer） |
| API キー / Webhook | apiKeys / webhooks | そのまま |
| API プレビュー | Playground（GraphiQL） | microCMS の語 |
| 検索（⌘K） | Cmd+K | 「コマンドパレット」とは呼ばない |

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
| 9 | 型編集の安全化（`fieldImpact` / `replaceSelectOption` / 子フィールドの並び替え） | API スキーマ | 中 1 日 |
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
- **フィールドの種類（kind）は後から変えられない**。`removeField` と選択肢の削除は影響を検査しない
- `createPreviewToken` の `url` は型に `previewUrl` が無いと null
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

node は doc / paragraph / heading(level 1〜4, id は `[A-Za-z0-9_-]{1,64}`) / bulletList / orderedList / listItem(checked) / blockquote / codeBlock(language `^[a-z0-9+#-]{1,32}$`, fileName, highlightLines `1,3-5`) / table / tableRow / tableCell / tableHeader / callout(**kind 必須**: note / tip / warning) / details(**summary 必須・空不可**) / gallery(**中は image のみ・1 つ以上**, columns 2〜4) / text / hardBreak / horizontalRule / image(assetId 必須) / video(assetId 必須) / embed(**YouTube・Vimeo・X の URL のみ**) / linkCard(http(s) のみ) / mathBlock(tex 空不可)。

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

### 16.1 保存は人が押す

**自動保存はしない。** 入力が止まって数秒で書く形をやめ、エディタの上の帯に置いた
「下書き保存」を押した時だけ CMS に書く。

理由:

- 書きかけが勝手に版になる。変更履歴が「打鍵の記録」になり、v1 から v40 まで意味の無い版が並ぶ
- 公開前の確認（必須の未入力、未公開の参照先）を挟む場所が無くなる。公開中のコンテンツを直すと、
  黙って「公開中 · 下書きあり」に落ちる
- 何が書かれたか人が決められない。CMS は複数人で触る物で、途中の状態を相手に見せたくない事がある

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

**Strapi / Payload / WordPress / microCMS 側を採る。** Contentful と Sanity は自動保存だが、
どちらも「下書き」と「公開版」が完全に分かれていて版が汚れても困らない作りで、
こちらの `ContentStage` はそこまで持っていない。

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
