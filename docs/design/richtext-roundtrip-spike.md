# richText の往復スパイク: caption + 出典 / 引用の出典 / リンクカード / caption 内リンク

- 調査日: 2026-09-11。設計は [richtext-note-style.md](richtext-note-style.md)
- 正: `src/cms/rules/RichText.flix`（ホワイトリスト・HTML・平文）、`src/cms/rules/Markdown.flix`（doc ↔ Markdown）
- スパイクのテスト: `test/cms/rules/TestRichTextSpike.flix`（src は変えていない）
- 既存テスト: `test/cms/TestRichText.flix`、`test/cms/TestMarkdown.flix`

## 1. 現状の表

| ノード | (a) doc の attrs | (b) HTML | (c) Markdown | (d) Markdown → doc |
|---|---|---|---|---|
| image | `assetId`（必須）, `alt`, `caption`, `width`, `height` | caption 無し: `<img src alt [width height]>`。caption 有り: `<figure><img …><figcaption>…</figcaption></figure>`。class 無し。asset が無ければ出ない | `![alt](asset:ID "caption"){width=W height=H}`（caption は CommonMark の title の位置。無い物は書かない） | `![…](asset:…)` **だけ**の段落を image に。`{...}` は `width=W height=H` の固定形のみ。`![alt](URL)`（asset: 以外）は alt を URL へのリンクにした文字に落ちる |
| gallery | `columns`（2〜4。無ければ 2）。中は image のみ | `<div data-gallery="N"><figure><img…>[<figcaption>]</figure>…</div>`（中の image は caption が無くても figure） | 1 行に image を空白区切りで 2 つ以上。枚数と違う columns は行末 `{columns=N}` | 段落が image だけで 2 つ以上なら gallery |
| blockquote | attrs 無し（中に blockquote は不可） | `<blockquote>…</blockquote>` | 各行に `> `。ブロック間の空行は `>` だけの行 | `> ` の続く行。1 行目が `[!NOTE]` 等なら callout。入れ子は 1 段に潰す |
| callout | `kind`（note / tip / warning） | `<aside data-kind="…">…</aside>` | GitHub alerts `> [!NOTE]` | 同左 |
| linkCard | `url`（http(s) のみ） | `<a data-link-card href="URL">URL</a>`（OGP の取得と見た目はサイト側） | URL だけの段落（`https://example.com/`） | URL だけの段落で提供元でない物 → linkCard。**段落の中の URL は書き出しで `https\://` に守られる**ので区別は付く |
| embed | `url`（YouTube / Vimeo / X の形のみ） | `<figure data-embed="youtube\|vimeo\|x">` の中に iframe（X は `<blockquote class="twitter-tweet">`） | URL だけの段落 | URL だけの段落で `RichText.embedOf` が判れば embed |
| details | `summary`（空でない） | `<details><summary>…</summary>…</details>` | `<details><summary>…</summary>` 〜 `</details>` の行 | 同左（summary 無しは「詳細」） |
| video | `assetId`（必須）, `caption`, `poster`（asset id） | `<figure><video controls src [poster]></video>[<figcaption>…</figcaption>]</figure>` | `@[video](asset:ID "caption"){poster=asset:ID}` | 同左 |

共通: `validate` は**知らない attr を見ない**（image は assetId / alt、blockquote は子だけ、linkCard は url だけ）。attr を足しても検査は通り、HTML / Markdown / 平文には出ない。

## 2. 足したい 4 つの形

### 2-1. image に caption と source（出典。テキストと任意の URL）

| 観点 | 結果 |
|---|---|
| 今の doc で表せるか | caption は表せる。source は attr に**入れられる**（validate は通る）が、どこにも出ない |
| doc → HTML | caption は figcaption に出る。source / sourceUrl は**落ちる**（`testToHtmlCurrentForms`） |
| doc → Markdown → doc | caption は往復する。**source / sourceUrl は落ちる**（`testRoundTripDropsAttrsAbsentFromMarkdown` 2 行目） |
| 壊れ方 | Markdown の title の位置（`"caption"`）が 1 つしか無い。`{width=W height=H}` は固定形の正規表現で、`{source=…}` を足すと **image でなくなり段落の文字に落ちる**（`testFromMarkdownCandidateForms` 4 行目: `![](asset:asset001 "写真"){source=出典社}` → paragraph） |

提案:

- doc の attrs 案: `image.attrs.source`（String）、`image.attrs.sourceUrl`（http(s)。`isHttpUrl` で検査）。caption と同じく任意。gallery の中の image も同じ attrs で良さそう（Picture の enum に 2 つ足す）
- HTML 案（class 無し・data 属性の方針のまま）:
  `<figure><img …><figcaption>写真<cite><a href="URL">出典社</a></cite></figcaption></figure>`。URL 無しなら `<cite>出典社</cite>`。caption 無しで source だけの時も figcaption を出す（figcaption の中身が cite だけ）。サイト側は `.prose figcaption cite` で当てられる
- Markdown 記法案（既存の `{key=value}` 方言に寄せる）:
  `![alt](asset:ID "caption"){width=W height=H source="出典社" sourceUrl=https://…}`。`{...}` を「key=value の並び」に読み替える（今は固定形）。値に空白や `"` が入るので source は `"…"` で囲い、`escapeTitle` と `unescape` を使い回す。読む側は知らない key を捨てれば、古い Markdown も新しい Markdown も同じ関数で読める
- 別案: `![alt](asset:ID "caption")` の直後の行に `— 出典` を置く。人には書きやすいが、image の次の段落と区別できず、gallery（1 行に複数）に付けられないので、`{...}` の方が安全

### 2-2. blockquote に cite（出典。テキストと任意の URL）

| 観点 | 結果 |
|---|---|
| 今の doc で表せるか | attrs に `cite` を入れても validate は通るが、`Block.Blockquote` が attrs を持たないので Markdown でも HTML でも出ない |
| doc → HTML | `<blockquote><p>引用</p></blockquote>`。cite は**落ちる** |
| doc → Markdown → doc | **cite / citeUrl は落ちる**（`dropPairs` 3 行目） |
| 段落で持つ場合 | 引用の最後に `— [出典](URL)` の段落を置けば doc / Markdown / HTML の全部で往復する（`dropPairs` 5 行目、`writePairs` 5 行目、`htmlPairs` 4 行目）。ただし**構造としては段落**で、HTML は `<p>— <a …>出典</a></p>` |
| 壊れ方 | `> 引用\n> — 出典`（空行無し）は**1 つの段落の中に改行込みで繋がる**（`readPairs` 1 行目: text が `"引用\n— 出典"`）。空行を挟めば 2 段落になるが cite にはならない。`<cite>` を書いても `<` は文字なので段落の文字のまま（`readPairs` 8 行目） |

提案:

- doc の attrs 案: `blockquote.attrs.cite`（String）、`blockquote.attrs.citeUrl`（http(s)）。image と揃えた名前にするなら `source` / `sourceUrl` でも良い（HTML の要素名に合わせるなら cite）
- HTML 案: `<blockquote><p>引用</p><footer><cite><a href="URL">出典</a></cite></footer></blockquote>`。`<footer>` は blockquote の中で出典を置く HTML の慣用で、class 無しの方針と合う。`<blockquote cite="URL">` 属性は表示されないので、テキストを出すには要素が要る
- Markdown 記法案: 引用の最後の行を `> — 出典` / `> — [出典](URL)` にし、**読む時に「引用の最後のブロックが `— ` で始まる段落」なら cite に畳む**。書く時は `>\n> — [出典](URL)`（空行を挟む）で出す。人が書きやすい形と往復が両立する。
  - 危ない所: 本文として `— ` で始まる段落を引用の最後に書いた人の物が cite に化ける。逃げ道は `\—`（backslashStep は ASCII の記号しか逃がさないので、`—`（U+2014）は今のままだと逃がせない。`-- ` を印にするなら ASCII で逃がせる）
  - 別案: `> [!CITE] 出典`（alerts に寄せる）。既存の callout の 1 行目と同じ場所なので実装は易しいが、他の Markdown 処理系で読むと `[!CITE]` の文字が残る

### 2-3. linkCard（OGP を持つか、url だけ持つか）

| 観点 | 結果 |
|---|---|
| 今の doc で表せるか | url だけ。title 等を attrs に入れても validate は通るが、Markdown / HTML / 平文の全部で**落ちる**（`dropPairs` 4 行目、`writePairs` 3 行目、`htmlPairs` 5 行目） |
| Markdown での区別 | URL だけの行が linkCard、段落の URL は `https\://` と書き出される（`writePairs` 4 行目）ので、**doc → Markdown → doc では paragraph と linkCard が混ざらない**（`dropPairs` 7 行目）。人が書いた Markdown で「URL だけの行」を段落にしたい時は逃げ道が `\:` しか無い |
| `[title](url)` だけの行 | 段落のリンク（`readPairs` 7 行目）。linkCard にはならない |

提案:

- **url だけ持ち、表示時（またはコンテンツ API の HTML 化の前段）で解決する**方に寄せるのが往復には安全。OGP は変わる物なので、doc に写すと古くなり、Markdown に出せば往復の対象が増える
- ただし HTML を「スタイルを当てやすいシンプルな形」にするなら、`<a data-link-card href>URL</a>` のままではサイト側が fetch しないとカードにならない。折衷案は、**OGP の写しを doc でなく別の表（url → title / description / imageUrl / siteName / 取得日時）に持ち、`toHtml` に `images` と同じ形で `cards: Map[String, LinkCardRef]` を渡す**。HTML は
  `<a data-link-card href="URL"><img src="IMG" alt=""><span>TITLE</span><span>DESCRIPTION</span><span>SITE</span></a>`
  のように、無い物は出さない。doc と Markdown は変えず、往復も壊れない
- doc に持たせるなら attrs は `title` / `description` / `imageUrl` / `siteName` で、Markdown は `https://example.com/ {title="…" siteName="…"}` のように `{...}` を足す形になるが、URL だけの行の判定（`^https?://\S+$`）が変わり、description のような長文を 1 行に押し込む形になる。勧めにくい

### 2-4. 画像・引用の caption 内にリンク（inline marks）

| 観点 | 結果 |
|---|---|
| 今の doc | caption は **String の attr**。marks を持てない。Markdown 記法や HTML を書いても文字のまま（`dropPairs` 6 行目、`htmlPairs` 6 行目: `<a>` はエスケープされて出る） |
| Markdown | title の中で `[` `]` は `\[` `\]` に逃がされる（`writePairs` 6 行目）。往復で文字は残る |

提案:

- caption の中にリンクを許すなら、**caption を attr から子ノードに変える**（`image` を `content: "caption?"` の container にする、または `figure` ノードを足して `image` + `figcaption`（inline+）を並べる）。これは image の doc の形が変わるので既存 entry の移行（attr → 子）が要り、TipTap 側も atom でなくなる
- 2-1 / 2-2 の「出典（テキスト + URL）」だけが目的なら、**caption は文字のまま、source / sourceUrl（cite / citeUrl）を別 attr に持つ**方が、doc の形・Markdown・TipTap のどれも小さく済む。note.com の見た目（キャプションの下に出典のリンク）はこの 2 attr で作れる
- caption 全体に自由なリンクを入れたい要望が本当にあるかを先に確かめるのが良さそう

## 3. テスト結果

`make test`（`bin/flix test`、DB 無し）: **Passed 720 / Failed 0**（スパイクの 6 本を含む）。

スパイクの 6 本は最初から「現状はこうなる」を期待値にして書き、**1 回目の実行で 6 本とも通った**（書き換えは無し）。往復で**元と違う形になる行**は次の 3 つで、それが「落ちる物」:

| 落ちる物 | テスト | 中身 |
|---|---|---|
| image の `source` / `sourceUrl` | `testRoundTripDropsAttrsAbsentFromMarkdown` 2 行目 | doc → Markdown → doc で `{caption}` だけになる |
| blockquote の `cite` / `citeUrl` | 同 3 行目 | attrs が消え、素の blockquote になる |
| linkCard の `title` / `description` / `imageUrl` / `siteName` | 同 4 行目 | `url` だけになる |

「壊れる」と分かった読み方:

| Markdown | 今の doc | テスト |
|---|---|---|
| `> 引用\n> — 出典` | 1 段落の text `"引用\n— 出典"` | `testFromMarkdownCandidateForms` 1 行目 |
| `<figure>…</figure>` | 段落の文字（image が失われる） | 同 3 行目 |
| `![](asset:asset001 "写真"){source=出典社}` | 段落の文字（image でなくなる） | 同 4 行目 |
| `<cite>著者</cite>` を引用の中に | 段落の文字 | 同 8 行目 |

壊れない（区別が付く）と分かった物: 段落の URL は `https\://` で書き出され linkCard と混ざらない（`writePairs` 4 行目、`dropPairs` 7 行目）。

## 4. TipTap 側（admin-ui）

- doc の受け渡しは **getJSON**（`admin-ui/web/tiptap-editor.ts` の `emit()`: `unfold(this.editor.getJSON())` を `docchange` で Elm へ。getHTML は使っていない）。CMS が知らない node は `passthrough` に畳んで保存時に戻す（`foldUnknown` / `unfold`）ので、doc に attr を足す分には壊れない
- image は `admin-ui/web/image-node.ts` の自前 node（`atom: true`、`addNodeView` で `<figure>` を作り、`alt` の欄を `noteInput` で置く）。**caption の欄は意図して置いていない**（WhyNot コメント: ヘッドレス CMS の編集画面は caption を持たない）。`attrs.caption` は default null で往復だけする
- 見立て（5 行以内）:
  1. caption / source / sourceUrl を attr で持つなら、`image-node.ts` の `addAttributes` に 3 つ足し、`noteInput` を 2〜3 本並べるだけ（alt と同じ作り。自前 node のまま）
  2. caption の中にリンクを許すなら atom を外し `content: "inline*"` の figcaption 子ノード（または figure / figcaption の 2 node）を自前で作る必要があり、node view の書き直しになる
  3. blockquote の cite は StarterKit の Blockquote を `extend` して `addAttributes` に cite / citeUrl を足し、node view で末尾に入力欄を置く（自前 node にはしなくて良い）
  4. linkCard は今は passthrough（「この画面では編集できません」）。url だけの自前 node にすれば挿入と表示が足りる

## 5. 結論

- **今の doc / Markdown / HTML は、caption までは往復するが、出典（テキスト + URL）は image / blockquote / linkCard のどれにも持ち場が無い。** attrs に足すと validate は通るが、Markdown / HTML / 平文の全部で黙って落ちる（3 本のテストで確認）
- 小さく進めるなら、次の順が良さそう:
  1. `image.attrs.source` / `sourceUrl`、`blockquote.attrs.cite` / `citeUrl` を足し、`Picture` と `Block.Blockquote` に運び、HTML は `figcaption > cite` と `blockquote > footer > cite` に出す
  2. Markdown は image を `{key=value …}` の一般形に、blockquote は末尾の `> — [出典](URL)` 段落と cite の相互変換にする（`—` を逃がせないので、印を `-- ` にするか、`\—` を逃がせるように backslashStep を広げるかを決める）
  3. linkCard は url だけを持ち続け、OGP は別の表 + `toHtml` の引数で足す
  4. caption 内の inline marks は、要望が確かになるまで見送る（doc の形と TipTap の node view が両方変わる）
- スパイクのテスト `test/cms/rules/TestRichTextSpike.flix` は残してある。消すか、実装後に期待値を新しい挙動へ書き換えるかは本体の判断
