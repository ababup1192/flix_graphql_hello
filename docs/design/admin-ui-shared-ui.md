# admin-ui の見た目の共通化（2026-09-11 の棚卸しと計画）

Elm の流儀に沿い、**状態を持たない view の関数**をファイルに分ける。Model / Msg は持たせない（コンポーネントにしない）。
分ける単位は「見た目の型」で、行数では分けない。

## 棚卸しの結論

`Ui.elm`（50 関数）は表・カード・空・読み込み・失敗・chip・callout・drawer・overlay をほぼ全画面が使っている。
重複は「Ui にある物の取りこぼし」と「Ui にまだ無い 6〜7 個の型」に分かれる。**日付・時刻（`Ui.DateTime` / `Ui.DateRange`）と表とアイコンは既に一本化**されていて、残るのは組み合わせ方だけ。

## 一番危ない所

状態バッジ「公開中 / 公開中 · 下書きあり / 下書き」の言葉・色・アイコンが 4 か所に別々にある
（Entries の一覧、Editor の帯、Board の列、Entries の絞り込みの選択肢）。言葉が食い違うと利用者が誤解する。

## 作る物（効果の大きい順）

| # | 置き場 | 関数 | 消える手組み |
|---|---|---|---|
| 1 | `Ui.Stage`（新規） | `chip : Stage -> Html msg` / `name : Stage -> String` / `icon` / `options`。Stage は既存の型か文字列 3 値 | Entries:1135、Editor:2370、Board:86、Entries:1035 |
| 2 | `Ui.Modal`（新規） | `dialog { title, onClose, error } children`（中央 440px、覆い /40、外クリックと Esc で閉じる、`keepOpen` 内蔵）/ `actions { confirm, tone, onConfirm, onCancel }`（右寄せ、危険は赤）/ `sheet`（上寄せ。上下の帯を固定し中だけスクロール。⌘K とメディア選択）/ `fullscreen { title, trailing, onClose }`（プレビュー）。`drawer` は `Ui` から移す | Ui/Confirm、Editor:1740/1808/1830、Board:403、Palette:285、Editor:2592、`keepOpen` の 4 か所 |
| 3 | `Ui` | `dangerButton`（Confirm の class を移す）/ `iconButton { size, title, onClick } shapes`（h-7 w-7、rounded-md、hover:bg-well hover:text-ink に統一） | 赤ボタンの生 1 か所、アイコンボタンの 7 変種 |
| 4 | `Ui` | 差し替えのみ: `failedCard` を手書きしている 3 か所 | TypeSettings:184、Board:336、Editor:1599 |
| 5 | `Loaded` | `table { empty, present }`（loading / missing / failed の 4 つ組を 1 行に。空の文言を 1 回だけ渡す） | 11 か所、二重の空文言 4 組 |
| 6 | `Ui.Menu`（新規） | `box { place } rows` / `row` / `link` / `divider`（Shell の private を引き上げ）/ `popoverAnchor`。↑↓ の移動は Palette の物を共通にして Editor の候補・Audit の書き出し・Shell のプロジェクト選びにも | Shell:452、Audit:452、Editor:2941、DateRange:207 |
| 7 | `Ui.DateTime` | `relative : Zone -> Today -> String -> Html msg`（相対 + hover で絶対）/ `localWithZone` | Keys:609、Account:390、Members:434、Audit の 4 か所 |
| 8 | `Ui` | `collapsedRows { label, open, onToggle, rows }` / `moreRow { onMore }`（語は「もっと見る」に統一） | Keys:490、Account:288、Audit:962、Media:401 |
| 9 | `Ui` | `removableChip { label, title, onRemove }` / `kbd : String -> Html msg` | Entries:669、Editor:2920、Shell:279、Editor:2624 の表記 |
| 10 | `Ui.Icon` ⇄ `web/icons.ts` | `expand` / `entry` / `image` / `link` / `table` の path をどちらか一方に揃える。長期的には `Ui.Icon.markupByName` を custom element の属性で渡し `icons.ts` を捨てる | 二重管理 |
| 11 | `Ui` | `searchInput { value, placeholder, onInput }`（虫眼鏡付き。語は「検索」に統一）/ `errorText` / `mono` / `faint` / `emptyIn` / `metaRow` / `chipRow` | 検索欄 5 種、赤い一行 10 か所、等幅 12 か所、極小 10 か所 |

通知（toast / `Ui.Reply` / banner）は既に一本化されているので触らない。ダイアログの中の失敗だけ `Ui.Modal.dialog` の `error` に寄せる。
カレンダーは `Ui.DateTime` と `Ui.DateRange` にマスと矢印が別々にあるので、`Ui.DateTime` 側に置いて `DateRange` から呼ぶ（見た目は変えない）。

## 順番

1. `Ui.Stage`、`Ui.Modal`、`dangerButton` / `iconButton`、`failedCard` の差し替え（#1〜#4）。ここで見た目のばらつきの大半が消える
2. `Loaded.table`、`Ui.Menu`、`Ui.DateTime.relative`、`collapsedRows`（#5〜#8）。行数が減る
3. `removableChip` / `kbd`、アイコンの揃え、細かい文字の関数（#9〜#11）

各段で `npm run check` と Playwright の全ページのスクリーンショット（前後で差分を目で見る）。見た目を変える所（確定ボタンの色、覆いの濃さ、アイコンボタンの大きさ）は**揃える先を 1 つ決めてから**置き換える。

## 決め（揃える先）

- 確認ダイアログ: 幅 440px、覆い /40、確定は右寄せ、危険（削除・公開を終える）は赤、それ以外は青
- アイコンボタン: h-7 w-7、rounded-md、hover は bg-well + text-ink
- 検索欄の placeholder: 「〜を検索」
- 「もっと見る」に統一（「もっと読む」は使わない）
- 空の文言: 「〜がありません」（既にほぼ揃っている）

## やらない事

- Model / Msg を持つ部品（入れ子の TEA）は作らない
- `Editor.elm` の分割は「データ型の抽出」（保存の状態、メディア選択の選択状態、版の履歴）として別に行う。この文書の範囲外

## 追記: Elm と TipTap の境界（2026-09-11 の調査）

エディタの中の UI は今すべて TS が DOM を組んでいる。調査の結論は「移す前に効く 2 つ」と「移す候補 5 つ」。

### 移す前に効く 2 つ

1. **文言の見張りを TS にも広げる**。`scripts/wording-check.mjs` が読むのは Elm だけで、`web/*.ts` の日本語 130 個が禁則の外。実際に「読み込み中」「…を送っています…」「取得に時間がかかっています」が規則を破っていた
2. **境界の値を 1 本の状態にまとめる**。今は属性ごとに JSON の文字列を渡し、TS 側が `catch {}` で握り潰す。Elm の型が境界で消える。`seq` 付きの `state` 1 本にして形を 1 か所に置く

### 移す候補（旨みの大きい順）

| # | 候補 | 行数 | 文言 | 選択への追従 | 寄せ方 |
|---|---|---|---|---|---|
| 1 | リンクの面（`link-dialog.ts`） | 316 | 16 | 開く位置だけ | **済み（2026-09-11）**。TS が `linkopen`（seq / mode / href / entryId / 矩形）を投げ、Elm が `Ui.Modal.anchored` で描き `linkchoice`（seq 付き）で返す。`applyLink` だけ TS に残した |
| 2 | コードの言語とファイル名 | 120 | 7+ | しない | `codeblockopen` → `Ui.select` / `Ui.input` → seq 付きで返す |
| 3 | 引用の出典欄 | 36 | 3 | しない | `Ui.fieldWith` の errors に `isHttpUrl` を乗せる |
| 4 | 「+」のブロック一覧 | 250 | 20 | ボタンだけ | ボタンは TS、一覧は `Ui.Menu.box`。アイコンの二重定義もここで消える |
| 5 | 画像の入力の面 | 40 | 6 | 開く位置だけ | 帯は TS、入れ替わった後の面だけ Elm |

### TS に残す物

ツールバーと BubbleMenu、段落の種類と列数の select、キャプションの帯と選択中の URL の表示、表の掴みと落とす先の予告、node view の中身すべて。いずれも打鍵や選択のたびに塗り直すか、ProseMirror が DOM を所有している。

### slot は使えない

custom element は shadow DOM を使っておらず slot が無い。Elm が子を書くと、TS が `connectedCallback` で足したツールバーと本体の箱を仮想 DOM が壊す。安全なのは **Elm が `tiptap-editor` の兄弟として面を描く**形（浮く面は既に `position: fixed`）。編集領域の内側には入れない。

### 順番

1. 文言の見張りを TS に広げる（移動なし）
2. 境界を `state` 1 本にまとめる（移動なし）
3. リンクの面を Elm に移す（候補 1 だけ先に試し、効果を見てから 2 以降を判断）

### 済み: リンクの面（2026-09-11）

`web/link-dialog.ts`（316 行）を消し、`src/LinkPick.elm` と `Ui.Modal.anchored` に移した。**後続の 4 つはこの形を真似る。**

境界は 2 本だけ:

- event `linkopen`（TS → Elm）: `{ seq, mode, href, entryId, rect: { left, top, bottom, spaceWidth, spaceHeight } }`。
  TS は「開きたい」と**押した物の矩形**しか渡さない。置き場所（下に入らなければ上へ返す・左右を画面に収める）は `Ui.Modal.anchored` が決める。
- property `linkchoice`（Elm → TS）: `{ seq, href, entryId, label, remove, cancel }`。
  `seq` が新しい時だけ TS が doc を触る。**何も選ばずに閉じた時も `cancel` で返す**（本文へ focus を戻すのは TS の仕事）。

決まり:

- **doc を変える物は `window.setTimeout(…, 0)` で 1 拍おく**（`insert` と同じ）。property が入るのは Elm が DOM を書いている最中で、その場で doc を変えると `docchange` が Elm の描き直しに飛び込み、画面には出るのに保存されない
- 面は `tiptap-editor` の兄弟として画面の view に 1 つだけ描く（項目ごとに描かない）。どの項目の面かは `apiId` で分ける
- Model と Msg は `Page.Editor` が持ち、`LinkPick` は**行の組み立て・上下の移動・描き方**だけ。純粋な `rows` / `move` / `chosen` を表駆動でテストする（`tests/LinkPickTest.elm`）
- 覆いは `Ui.dismissLayer`（透明）。外を押すと閉じるので、**開いたボタンを押し直す道は覆いが受ける**（TS の `dismissOn` は要らない）
- ↑↓ と Enter は入力欄の `preventDefaultOn "keydown"` で拾う。Esc は拾わず画面の `escapeOne` に配る（面を先頭に置く）
- 画面の言葉は Elm に移るので `wording-check` に乗る。公開の状態は `Ui.Stage` から引き、TS には**語にして**渡す（`stageName`）
- 手元の確かめの道具が掴む目印として `data-link-row` / `data-at` / `data-link-now` / `data-link-more` を置く
