# richText を note 風にする設計（2026-09-11）

richText のエディタの書き心地と、公開側の HTML を note（note.com）に寄せる設計。
「画像や引用に出典を付けられる」「外部リンクがカードになる」を、**HTML はスタイルを後から当てやすい
シンプルな形のまま**、doc ↔ Markdown ↔ HTML の往復を壊さずに足す。

- 調査（note の機能・書き心地・評判・公開 HTML の実測、他社比較）: [richtext-note-research.md](richtext-note-research.md)
- 往復のスパイク（何が落ちるか、テストで確認）: [richtext-roundtrip-spike.md](richtext-roundtrip-spike.md)、`test/cms/TestRichTextRoundTrip.flix`
- HTML と CSS のモック: [richtext-mock.html](richtext-mock.html)（ブラウザで開くだけで見られる）
- エディタの段階と doc の制約は [admin-ui-spec.md](admin-ui-spec.md) の 1 章と 10.5 が正。この文書はそこに足す差分

## 1. note の書き心地を言葉にする

note が「気持ちよく書ける」と言われる中身は、機能の多さではなく次の 6 つに集約できる（出典は調査文書）。

| 何が | note の実装 | 利用者の言葉 |
|---|---|---|
| 語彙が少ない | 段落 / h2 / h3 / 引用 / コード / 区切り / リスト / 画像 / 埋め込み。表・脚注・色・下線は無い | 「余計なノイズがない」「編集と公開の見た目が同じ」 |
| 改行が日本語向け | Enter 1 回で `<br>`、2 回で段落 | 「エンター 1 回で改行になった」と最も歓迎された |
| URL を貼るだけ | 単独行 + Enter でカード / 埋め込み。文中は文字のまま。カードは削除で URL に戻る | 「貼るだけで埋め込める」。ただし「カードにならない理由が分からない」 |
| 出典が付く | 画像は figure + figcaption、引用は figure + blockquote + figcaption（URL 可） | 引用の右下に出典、が定番の見た目 |
| 道具が邪魔しない | 選択時に浮くツールバー、段落左の「+」、ドラッグハンドル、Ctrl+Shift+↑↓ | 「シンプル」 |
| 消えない・迷わない | 約 10 秒の自動保存、右上の文字数、左上の見出し一覧 | 「急に閉じても安心」 |

不満は「表が無い」「見出しが 2 段」「Markdown 貼り付けが不安定」「コードの色が編集中に出ない」に集中している。
この CMS は表・h1〜h4・コードの色付けを既に持つので、**語彙を note に絞るのではなく、note の書き心地の 6 つを
既存の語彙の上に載せる**のが方針になる。

## 2. 足す物と足さない物

### 2.1 足す（この設計の範囲）

| 何を | doc | 備考 |
|---|---|---|
| 画像の出典 | `imageItem.attrs.source`（文字）/ `sourceUrl`（http(s)） | caption は `imageItem.content`（inline）。1 枚でも複数枚でも同じ |
| 引用の出典 | `blockquote.attrs.cite`（文字）/ `citeUrl`（http(s)） | 名前は HTML の要素名 `cite` に合わせる |
| 外部リンクのカード | doc は今のまま `linkCard.attrs.url` だけ | OGP は doc に写さない（3 章） |
| 書き心地 | 浮くツールバーと「+」、URL 貼り付けの規則、自動保存、Enter の挙動、ハンドル、文字数、見出し一覧、Markdown として貼る | 5 章に差分、6 章に体験 |

### 2.2 足さない（理由付き）

- ~~**caption の中のリンク（inline marks）。**~~ 2026-09-11 に足した（3.1 章）。note はキャプションにリンクを書く文化で、文字列のままだと移行した人が最初に躓く
- **note のように出典が空でも `<figcaption></figcaption>` を出す。** 空要素が残り、サイト側の CSS が余白を出す。無い物は出さない
- **リンクカードを iframe で出す。** note も外部記事は iframe でなく静的な `a` に展開している。iframe は CSP と読み込みの遅さ、サイト側でスタイルを当てられない、の 3 つで不利
- **見出しを h2 / h3 に絞る。** note の不満の上位。h1〜h4 のまま

## 3. HTML の形

方針は今の `RichText.toHtml` と同じ。**class を使わず、要素名と data 属性だけ**にする。サイト側は
`.prose figcaption cite` のような素の selector で当てられる。モックの CSS がその見本。

### 3.1 画像 + キャプション + 出典

キャプションは **`image.content` の inline（text with marks）**。マークは bold / italic / strike / code / link の 5 つで、hardBreak は無い。

```json
{ "type": "image", "attrs": { "assetId": "…", "source": "撮影: 山田太郎", "sourceUrl": "https://…" },
  "content": [ { "type": "text", "text": "夕方の港。" }, { "type": "text", "text": "西日", "marks": [ { "type": "link", "attrs": { "href": "https://…" } } ] } ] }
```

```html
<figure>
  <img src="…" alt="夕方の港" width="800" height="450">
  <figcaption>夕方の港。<a href="https://…" target="_blank" rel="noopener noreferrer">西日</a> <cite><a href="https://…" target="_blank" rel="noopener noreferrer">撮影: 山田太郎</a></cite></figcaption>
</figure>
```

- figcaption の中は本文と同じマークの HTML（`<a>` `<strong>` `<em>` `<s>` `<code>`）+ 出典の `<cite>`
- caption も source も無ければ今まで通り `<img>` だけ（figure で包まない）。content が空（`[]` や空文字だけ）も「無い」と同じ
- source だけで caption が無い時は figcaption の中身が `<cite>` だけ
- sourceUrl が無ければ `<cite>撮影: 山田太郎</cite>`
- 平文（toText）は 2 枚以上の時だけ画像ごとのキャプションを出す（inline を素の文字に）。1 枚の image は出さない（今まで通り）

**旧 doc の `image.attrs.caption`（文字列）は読む側でだけ受ける。** validate は通し、content が無い時だけ text 1 つのキャプションとして扱う（HTML・平文・Markdown の書き出しで同じ）。両方ある時は content が勝つ。書く側（`Markdown.fromMarkdown` の出力）は content だけを出し、attrs.caption は出さない。理由:

- キャプションの形を 1 つに固定する。2 つの持ち方を書く側でも許すと、画面・API・取り込みが別の形を書き、往復の期待値が 2 通りになる
- 既存 entry の doc を一斉に書き換えなくて済む。読む側の互換だけで、保存し直した時に自然と content に寄る
- note はキャプションにリンクを書く文化で、文字列のままだと移行した人が最初に躓く（2.2 章の見送りを覆した理由）

画像のリンク・縮小・配置（`image.attrs.href` / `size` / `align`。2026-09-11 に追加）:

```html
<figure data-size="small" data-align="left">
  <a href="https://…" target="_blank" rel="noopener noreferrer"><img src="…" alt="夕方の港"></a>
  <figcaption>夕方の港 <cite>撮影: 山田太郎</cite></figcaption>
</figure>

<!-- caption も出典も無く href だけ: figure は作らない -->
<a href="https://…" target="_blank" rel="noopener noreferrer"><img src="…" alt="" data-size="small"></a>
```

- href は img を `a` で巻く。属性は本文の外部リンクと同じ（`target="_blank" rel="noopener noreferrer"`）。http(s) だけ（linkCard と同じ判定）
- size / align は figure の `data-size` / `data-align`。figure が無い時（caption も出典も無い）は img に付ける。無い時は attr 自体が出ない（既定は本文の幅で中央）
- **size は "small" の 1 段だけ**。幅の数値や 3 段階は見た目の決めが本文に埋まり、リニューアルと狭い画面で崩れる（文字色を持たないのと同じ理由）。「小さくしたい」の意図だけを渡し、実際の幅はサイトの CSS が決める
- **align は "left" / "right"**（既定は中央。note が縮小した画像を左 / 中央 / 右に置けるのに合わせる）。"center" は値に持たない。既定が中央なので、値があると「無い」と「center」が同じ見た目になり往復で揺れる
- href だけの時に figure を作らないのは、中身が img 1 つの figure に意味が無く、サイト側の `figure` の CSS（余白・キャプションの下線）が空の figure にも当たるため。複数枚の中でも同じで、キャプションのある画像だけ figure で包む

### 3.2 引用 + 出典

出典は **blockquote の外**の figcaption に置く。HTML の仕様が「出典は blockquote の外」と定めていて、note の実測も
`figure > blockquote + figcaption`。画像と同じ figure なので CSS の当て方も揃う。

```html
<figure data-quote>
  <blockquote><p>Simplicity is the ultimate sophistication.</p></blockquote>
  <figcaption><cite><a href="https://…" target="_blank" rel="noopener noreferrer">Leonardo da Vinci</a></cite></figcaption>
</figure>
```

- cite が無い blockquote は今まで通り素の `<blockquote>`（figure で包まない）。サイト側は `blockquote` に当てた CSS が両方に効く
- **出典は doc では内容（inline）**で、`blockquote` の content の最後に置く `quoteCite` ノードの中身。中は text と
  マーク（`captionMarkNames`: bold / italic / strike / code / link。hardBreak は無し）で、**画像のキャプションと同じ仕組み**。
  URL は出典の文字に掛けた link マークで、`<cite>` の中はそのマークの HTML（本文のリンクと同じ `a`）になる。
  文字列の attr（`cite` / `citeUrl`）にしないのは、HTML（`<cite><a>…</a></cite>`）も Markdown（`> — [出典](URL)`）も
  文字とマークなのに doc だけが平たく、画面に「URL を入れる別の口」が要るため
- 旧い `blockquote.attrs.cite` / `citeUrl` は**読む側だけの互換**。`quoteCite` が無い時に、`cite` を text 1 つ、`citeUrl` が
  あればその文字に link マークを掛けた物として扱う（`cite` が無く `citeUrl` だけなら URL を文字にする）。両方あれば content が勝つ。
  書き出し（HTML / Markdown / doc）は content だけ
- 平文（`toText`）は `— 出典` の 1 行で、URL は出さない（画像のキャプションと同じで、出るのは見える文字だけ）
- 別案は `<blockquote><p>…</p><footer><cite>…</cite></footer></blockquote>`（スパイクの提案）。blockquote 1 つで済み、TipTap の DOM とも近い。採らなかった理由は、仕様上は footer が「引用の一部」になり、引用の平文化で出典が本文に混ざる点と、画像の figcaption と CSS が揃わない点。ただし実装の軽さでは footer が勝つので、実装時にもう一度天秤にかけてよい

### 3.3 外部リンクのカード

`a` 1 つ。中身は `span` と `img` だけで、JavaScript も iframe も無し。**OGP が無い時も同じ `a` で、中身が URL だけ**になる。

```html
<a data-link-card href="https://example.com/articles/how-to-write" target="_blank" rel="noopener noreferrer">
  <span data-title>読みやすい文章を書くための 7 つの習慣</span>
  <span data-description>一文を短くする、主語を隠さない、…</span>
  <span data-site><img src="…favicon…" alt="">example.com</span>
  <img data-thumbnail src="…" alt="">
</a>

<!-- OGP が取れていない / 取れなかった時 -->
<a data-link-card href="https://example.com/no-ogp-yet">https://example.com/no-ogp-yet</a>
```

OGP の持ち方は **doc に写さず、url → (title, description, imageUrl, siteName, fetchedAt) の別の表**に置き、
`toHtml` に `images` と同じ形で `cards` を渡す。理由:

- OGP は変わる物で、doc に写すと古くなる。Markdown に出せば往復の対象が増え、URL だけの行の判定（`^https?://\S+$`）も変わる
- doc と Markdown を変えずに済むので、往復は今のまま壊れない（スパイクで確認済み）
- 取得は**編集画面が貼った瞬間に管理 API（`fetchLinkCard`）に頼み、その場で** `OutboundHttp.runWith` から行う（2026-09-11 に変更。note の実物が貼った瞬間に「…」のローディングを出してカードにするため。細部は richtext-note-linkcard-ui.md §6）。仕事（BackgroundJobs）は古い行と失敗した行の取り直しだけ。失敗の理由（bot 拒否、404、OGP 無し）を表に残し、**編集画面はその理由を見せる**（note の不満「カードにならない理由が分からない」への答え）
- OGP 画像は自前の asset の置き先（MinIO / R2）に写す。相手の画像 URL をそのまま出すと hotlink と消失の問題がある。note も cloudfront に写している

### 3.4 その他（note に寄せるが HTML は変えない）

- 区切り線は素の `<hr>`。見た目はサイト側の CSS が決める。note は 1 本の横線（2026-09-11 に実物で確認。当初「＊　＊　＊」と書いていたのは調査の誤り）
- 目次はエディタに入れず、`heading.attrs.id` からサイト側（または将来のコンテンツ API のフィールド）が作る
- ブロックごとの安定 id は note は UUID を全ブロックに振るが、今は heading の id だけで足りる

## 4. Markdown の方言（往復を壊さない形）

スパイクで確認した「壊れる書き方」を避けて決める。詳しい根拠はスパイク文書の 2 章。

| 何を | 書き出し | 読み | 根拠 |
|---|---|---|---|
| image の出典 | `![alt](asset:ID){width=W height=H source="出典社" sourceUrl=https://…}` | `{...}` を **key=value の並び**として読む（今は `width= height=` の固定形で、他の key が混ざると image でなくなる）。知らない key は捨てる | 直後の行に `— 出典` を置く案は次の段落と区別できず、複数枚（1 行に複数）に付けられない |
| image のキャプション | 画像の直後の行（空行を挟まない）に `*キャプション*`。中は普通の inline Markdown（`[t](u)`、`**b**`、`~~s~~`、`` `c` ``）。`*` は `\*`。複数枚は画像の枚数だけ `*…*` を空白区切りで並べ、無い画像は `**`（どの画像にも無ければ行自体が無い） | 直後の行が `*` で始まり `*` で終わる時だけキャプション。直前に空行があれば普通の段落（斜体）。複数枚の `*…*` の閉じは「後ろが空白 + `*` か行末」の `*`（`***太字***` の中で切らない）。枚数より少なければ前から詰める。**古い `"caption"` の title は読む時だけ受け**、行があればそちらが勝つ | Zenn と同じ形で、GFM の読み手にも斜体の 1 行として見える。title（`"…"`）は文字列しか持てず、リンク付きのキャプションが落ちる。複数枚で 1 行 1 キャプションにすると何枚目の物か読めない |
| blockquote の出典 | 引用の最後に空行を挟んで `> — [出典](URL)`（URL 無しは `> — 出典`）。`— ` の後ろは普通の inline Markdown なので `> — **著者** より` も書ける | 引用の最後のブロックが `— ` で始まる段落なら、`— ` を外した残りを `quoteCite` の中身にする。出典に付けられないマーク（underline / highlight / math / sub / sup）は落とす | `> 引用\n> — 出典`（空行無し）は 1 段落に繋がるので、書き出しは必ず空行を挟む。マークを落とすのは、`fromMarkdown` の「必ず validate に通る doc を返す」約束を守るため |
| linkCard | 今まで通り URL だけの段落 | 今まで通り | 段落中の URL は `https\://` で書き出されるので混ざらない |
| image のリンク | 標準のリンク付き画像 `[![alt](asset:ID){…}](https://…)`（キャプションはその次の行） | `[` で始まれば image を読み、直後の `](URL)` が http(s) なら href。他は段落の文字 | GFM の読み手にもリンク付き画像として見える |
| image の縮小・配置 | `{width=W height=H size=small align=left source="…" sourceUrl=…}`（順は固定。align は left / right） | `{...}` の key=value。small / left / right 以外の値は捨てる | 既存の `{...}` の一般解析に乗る |
| codeBlock のフェンス | 常に `` ` ``。数は**中身に並ぶ `` ` `` の最大 + 1**（最小は 3）なので、中身の ` ``` ` や ` ```` ` をそのまま書き出せる | CommonMark に合わせ `` ``` `` でも `~~~` でも、3 個以上ならいくつでも開く。閉じられるのは**同じ記号で開いた数以上**の行だけ。閉じないまま終われば末尾まで | 読む側だけ CommonMark に合わせる。書き出しを 2 通り（`` ` `` と `~`）にすると同じ doc に 2 通りの Markdown が対応し、手で書いた物の diff が揺れる |
| codeBlock の折り返し | 今の `{…}` の中に `wrap` を足す。`` ```ts:a.ts {1,3-5 wrap} ``、折り返しだけなら `` ``` {wrap} `` | `{…}` の中身を空白で区切り、`wrap` の語があれば折り返し。残りの先頭 1 つを強調する行として見る | `{…}` を 2 つ並べる（`{1,3-5} {wrap}`）案より方言が少ない。Docusaurus も情報行の `{…}` の後ろに語を並べる形 |

image の `{...}` は **画像の直後（リンクの括弧の内側）に固定**し、`[![alt](asset:ID)](URL){size=small}` のように外側に置いた形は
image として読まず段落の文字に落とす。往復の形を 1 つにするためで、両方を読むと同じ doc に 2 通りの Markdown が対応し、
手で書いた物の diff が揺れる。この読みのために `[…](…)` の label は最初の `](` でなく対応する `]` で切る
（内側の `](asset:ID)` で切ると `asset:` への link になり validate に通らない）。

`—`（U+2014）は `backslashStep` が ASCII の記号しか逃がさないので、本文として `— ` で始まる段落を引用の
最後に置くと cite に化ける。逃げ道は 2 つあり、**`\—` を逃がせるように `backslashStep` を広げる**方を勧める。
もう 1 つは印を `-- ` にする案で、ASCII で逃がせるが人が書く時に不自然。

## 5. 今のエディタと note の差分（2026-09-11 の棚卸し）

今の admin-ui のエディタ（TipTap、`admin-ui/web/*.ts`）を note の書き心地と項目ごとに突き合わせた。
「出典」と「カード」以外にも差は広く、逆にこちらが上の物もある。括弧内は根拠のファイルと行。

| 観点 | note | 今のエディタ | 差 |
|---|---|---|---|
| 書きながら出る道具 | 選択で浮くツールバー。段落左の「+」 | 上部の固定ツールバー 1 か所（`tiptap-editor.ts:395`）。BubbleMenu も「+」も `/` も無い | **大** |
| Enter | 1 回で改行、2 回で段落 | TipTap 標準（Enter で段落、Shift+Enter で改行） | 中 |
| URL の貼り付け | 単独行 + Enter でカード / 埋め込み。文中は文字 | 素の文字のまま。linkCard / embed にする口が無い | **大** |
| 画像 | ドロップ、複数枚、alt とキャプション | ボタン（asset ピッカー）/ ドロップ / ペースト（`image-node.ts:331`）。alt だけ。caption は「置かない」と WhyNot | 中 |
| 引用の出典 | 右下に出典、URL 可 | 無い | 中 |
| 自動保存 | 約 10 秒 | 無い。⌘S と `beforeunload` の警告（`Editor.elm:602`） | **大** |
| 文字数 | 右上に常時 | 無い（text フィールドの maxLength だけ） | 小 |
| 見出し一覧 | 左上に目次プレビュー | 無い | 小 |
| ブロックの移動 | ドラッグハンドル、Ctrl+Shift+↑↓ | 画像と表の行列だけドラッグ | 中 |
| Markdown ショートカット | `## - > 1. --- ** ~~` | StarterKit 既定 + `- [ ]` `1)` `[文字](URL)` `~ ^ ==` `$…$` `$$`（`markdown-rules.ts`）。**こちらが多い** | 逆 |
| 貼り付け | 他エディタのスタイル保持。Markdown は不安定 | ProseMirror 既定（schema にある物だけ残る）。Markdown の解釈は無し | 同等 |
| 見出し | h2 / h3 | h1〜h4 | 逆 |
| 表 / 数式 / コード | 表無し。コードは言語無し、編集中に色が付かない | 表（8×8 グリッド、帯で操作）、数式（`$$`）、コードは言語検索・fileName・mermaid・編集中のハイライト（`code-block.ts`） | 逆 |
| CMS にあって画面に無い node | 該当なし | callout / details / video / linkCard / embed は passthrough の灰色枠（`tiptap-editor.ts:39`） | 中 |
| 編集と公開の見た目 | 同じ（WYSIWYG） | 別物。エディタは `.tt-body` の管理画面向け CSS で、公開の見た目はサイトが決める | 方針の差 |
| スマホ | アプリとブラウザで同じ | 配慮なし（表の帯やリンクの面は mouseover 前提） | 中（spec 10 章に既に方針あり） |
| 衝突 | 複数デバイスの競合を選ぶ | CONFLICT で「自分 / 相手」の 2 択（`Editor.elm:2279`） | 同等 |

まとめると、**note との一番大きな違いは 3 つ**。「書きながら出る道具が無い」「自動保存が無い」「記事の見た目でなく
データの形を編集している（URL がカードにならない、caption 欄が無い、CMS の node が灰色枠）」。
逆に表・数式・コード・見出しの段数・Markdown ショートカットは note より上なので、削らない。

## 6. エディタの体験（書く人の目で）

場面ごとに「今」と「こうする」を書く。doc の形は変えず、admin-ui と CMS の小さな追加で届く物に絞る。

### 6.1 書き始め

- **今**: 上のツールバーを見て段落種別を選ぶ。空段落の左に何も出ない
- **こうする**: 本文にカーソルを置くと、空の段落の左に「+」が出る（ホバーでなく、空段落にカーソルがある間は常時。note が 2023 年に変えた点）。押すと画像 / 区切り線 / 引用 / コード / 表 / 埋め込み（URL を貼る欄）が縦に並ぶ。同じ一覧は `/` でも開く（Notion の利用者が期待するので併設。絞り込みは日本語の見出し語で）
- 固定ツールバーは残す（見出しの段数の切り替え、上付き・下付き・蛍光ペンのように選択が要る物の置き場）。ただし出番が減るので、画面幅が狭い時は畳んでよい

### 6.2 文字を選んだ時

- **今**: 上のツールバーまで視線を上げる
- **こうする**: 選択の直上に浮くツールバー（BubbleMenu）。中身は note と同じ順で **太字 / 斜体 / 取り消し / インラインコード / リンク / 引用 / 見出し（h2 / h3）**。上付き・下付き・蛍光ペン・下線は固定ツールバーに残す（浮く方に全部入れると note の「シンプル」が消える）
- 表のセルの中とコードブロックの中では出さない（既に帯と言語の面がある）

### 6.3 Enter と改行

- **今**: Enter で段落、Shift+Enter で改行
- **こうする**: プロジェクトの設定（型の設定でなくプロジェクト単位）で「Enter 1 回で改行、2 回で段落」を選べるようにする。既定は今のまま。理由は、note が読み物向けの設定を全員に強いているのに対し、この CMS は見出しとリストの多い技術文書も書くため。note 風を望むプロジェクトだけ切り替える
- 切り替えた時の挙動: 空の段落で Enter を押すと直前の `hardBreak` を消して段落を割る（note と同じ）。見出しの中の Enter は常に段落に戻す。リストの中の Enter は常に次の項目

### 6.4 画像

- **今**: ボタン / ドロップ / ペーストで入り、選ぶと alt の欄。caption は無い
- **こうする**: 画像を選ぶと下に **alt / キャプション / 出典 / 出典の URL** の 4 欄（`noteInput` を並べる。`image-node.ts` の WhyNot「caption を持たない」を書き換える）。キャプションは 1 行で、改行は許さない（note は許すが、Markdown の `*…*` の 1 行に写す都合で hardBreak を持たない）。中にリンク・太字・斜体・取り消し・コードを付けられる。出典は「撮影: 山田太郎」のような短い文字で、URL を入れると公開側でリンクになる
- 複数枚のドロップは同じ image に imageItem を並べる。複数枚の中でも同じ 4 欄

### 6.5 引用

- **今**: `> ` かツールバーで blockquote。出典の置き場が無い
- **こうする**: 引用の本文は**本文より濃い面の箱**（左の縦線も枠も無い。note の実物。モックは `richtext-quote-mock.html`）。**出典は箱の外の下、右寄せ**で、箱との間は 18px。欄は 1 つだけで placeholder は「出典を入力」、入れた出典は本文と同じ濃さ（下線も枠も出さない）。**URL は出典の文字にリンクとして掛ける**（欄を横に 2 つ並べない。`citeUrl` があると出典が下線付きになり、乗せると URL が読める）。**出典の行に出すのは出典の文字だけで、印もボタンも置かない**（モックのどの状態にも無い）。URL を画面から入れる口は当面持たず、Markdown と API から入れる。入れる口は部品の整理（`editor-dom-parts.md`）の後に、出典の文字を選ぶと出る帯として作る。焦点が引用の外にあり出典も URL も空なら、行ごと出さない。空のままなら doc に書かない。attrs は `cite` / `citeUrl` のまま（Markdown の `> — [出典](URL)` の往復も変わらない）。出典の欄では ↑ も ↓ も引用の外の行へ出る。引用の中で Enter を 2 回押すと引用を抜ける（今と同じ）

### 6.6 URL を貼った時

- **今**: 素の文字
- **こうする**: 規則は 1 つ。**空の段落に URL だけを貼る → その場でカード（linkCard）か埋め込み（embed）になる。文中に貼る → リンク付きの文字**。note の「単独行 + Enter」より 1 手少ない（貼った時点で判定できる）。YouTube / Vimeo / X は embed、他は linkCard。カードを消すと素の URL の段落に戻る（note と同じ逃げ道）
- カードは編集画面では **URL とサイト名だけの薄い枠**で出す。OGP は保存後に仕事が取るので、編集中には無い。保存してから開き直すと、取れていれば title と画像が出る。取れなかった時は枠の中に理由（「相手のサイトが自動取得を拒んでいます」「404」「OGP がありません」）を出す。note の不満「なぜカードにならないか分からない」への答え
- 文中の URL は Link 拡張の autolink に任せる（打ってスペースでリンクになる。今も既定で効いている可能性が高い。確かめる）

### 6.7 ブロックの移動

- **今**: 画像と表の行列だけドラッグ
- **こうする**: どのブロックにも、ホバーで左にハンドル（⋮⋮）。ドラッグで移動、Ctrl+Shift+↑ / ↓ でも動く。TipTap の DragHandle 拡張が使える

### 6.8 保存

- **今**: ⌘S。未保存で離れると警告
- **こうする**: 入力が止まって数秒後に自動で下書きを保存し、右上に「保存済み 12:34」を出す。⌘S は残す。CONFLICT は今の 2 択のまま（note の「競合した下書きを選ぶ」と同じ形）。自動保存は `Effect.Autosave` が spec 11 章に既にあるので、その口を使う。debounce の秒数は note の 10 秒より短く 3〜5 秒（10 秒は「閉じたら消えた」の窓が広い）
- 自動保存で **公開中の entry を勝手に更新しない**。下書きだけ。公開は今まで通り人が押す

### 6.9 文字数と見出し一覧

- 右上に本文の文字数（TipTap の CharacterCount。埋め込みは 0、空白は 1。note と同じ数え方にしておくと移行した人が混乱しない）
- 左に見出し一覧（h1〜h4 を階段で）。押すとその見出しに送る。公開側の目次はこの一覧と同じ物になる

### 6.10 貼り付け

- 他エディタからの貼り付けは ProseMirror の既定で schema にある物だけ残る（今と同じ。note の「スタイル保持」と同じ結果）
- Markdown の文字列は既定では解釈しない。「Markdown として貼る」を「+」の一覧に置き、明示した時だけ `Markdown.flix` と同じ方言で読む（note の「不安定に変換される」を避ける）。⌘⇧V のプレーン貼り付けはそのまま

### 6.11 CMS にあって画面に無い node

callout / details / video / linkCard / embed は今は灰色枠。linkCard と embed は 6.6 で自前 node にする。
callout と details は「+」の一覧に入れる（spec 1 章の段階 2 と同じ）。video は asset ピッカーで動画を選んだ時に入る。
**灰色枠は「知らない node」のためだけに残す**。

### 6.12 見た目の一致

note は編集と公開が同じ見た目で、それが「気持ちよさ」の中心にある。この CMS は「見た目はサイトが決める」が方針で、
編集画面は管理画面向けの CSS を持つ。両方は取れないので、**編集画面の本文は「素直な記事の見た目」に寄せる**
（本文の幅を 40rem に絞る、行間 1.9、画像は中央、キャプションは小さく灰色、引用は左の細い線、カードは枠）。
モックの CSS と同じ設計なので、`.tt-body` にモックの値を写せば済む。サイト側の CSS を読み込む案は、
サイトごとに違う CSS が管理画面に混ざり、壊れた時に切り分けられないので採らない。

### 6.13 スマホ

spec 10 章の方針（段落・見出し・リスト・リンク・画像まで）のまま。浮くツールバーはスマホでは OS の選択メニューと
重なるので、選択時は画面下に固定の帯で出す。「+」はそのまま使える。

## 7. 実装の順

1. CMS: `image.attrs.source` / `sourceUrl`、`blockquote.attrs.cite` / `citeUrl` を `RichText.validate` のホワイトリストと `Picture` / `Block.Blockquote` に足し、HTML（3 章）と Markdown（4 章）を通す。`TestRichTextRoundTrip.flix` の期待値を新しい挙動に書き換えて残す
2. admin-ui: 画像の 4 欄と引用の出典欄（6.4 / 6.5）。編集画面の本文の見た目をモックに寄せる（6.12）
3. admin-ui: URL の貼り付けで linkCard / embed（6.6）、自動保存（6.8）、浮くツールバーと「+」（6.1 / 6.2）
4. CMS: OGP の表と仕事、`toHtml` の `cards`、失敗の理由を管理 API に出す（3.3）。admin-ui はカードに title と理由を出す
5. admin-ui: ハンドル（6.7）、文字数と見出し一覧（6.9）、Enter の設定（6.3）、Markdown として貼る（6.10）、callout / details / video の挿入（6.11）

1 と 2 で「出典が付く」、3 で note の書き心地の中心（道具・自動保存・URL）、4 で「カードがいい感じに出る」、5 で残りが揃う。
