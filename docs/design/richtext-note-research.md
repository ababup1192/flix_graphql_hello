# note（note.com）リッチテキストエディタ 調査

調査日: 2026-09-11
取得方法: WebSearch / WebFetch / curl。note ヘルプセンター（help-note.com）は Cloudflare のチャレンジで本文が取れなかった（WebFetch は 403、curl は「Just a moment...」）。ヘルプの記述は検索結果のスニペットに依る。公開記事の HTML は curl で 3 本取得して抜粋した。

## 0. 前提: エディタの世代と技術構成

- 旧エディタは MediumEditor ベース。新エディタは ProseMirror ベースで、コアは ProseMirror、表示は Next.js、Turborepo のモノレポ。2020 年 3 月に開発開始、2022 年 4 月にベータ公開、2022 年 11 月に全クリエイターが新エディタへ切り替わり、旧エディタは廃止。1 年で 1000 件以上のフィードバックを反映。
  - 出典: https://engineerteam.note.jp/n/n48cf05ad9784 （curl で本文取得）
  - 出典: https://note.com/info/n/ncb99a9be7db4 （11 月中に全て新バージョンへ）
  - 出典: https://note.com/info/n/nbd9ec2e0ade5 （正式リリース、「15 以上の機能」）
- 「Markdown ショートカット対応」「他のテキストエディタからスタイルを保持してコピペ」が正式リリース時の目玉。
  - 出典: https://note.com/info/n/nbd9ec2e0ade5

## 1. 使える書式・ブロックの一覧

| 項目 | 有無 | 内容 | 出典 |
|---|---|---|---|
| 見出し | あり（2 段） | 大見出し h2、小見出し h3 のみ。h1 は記事タイトル。h4〜h6 は無い | https://note.com/info/n/n611d3e257e54 、https://note.com/samurai_worker/n/n5dde9444a33f |
| 太字 | あり | `**` / `__` の Markdown ショートカット、Ctrl+B | https://note.com/info/n/naf341f23d0e5 |
| 斜体 | Markdown 記事では「対応」と書かれているが、公式のツールバー項目には無い。要確認（推測: 貼り付け時にだけ効く） | https://note.com/samurai_worker/n/n5dde9444a33f |
| 取り消し線 | あり | `~~ ~~`、Ctrl+Shift+X | https://note.com/info/n/n611d3e257e54 |
| 引用 | あり | 背景を薄グレーに。「出典元」を右下に書け、URL を埋め込める | https://note.com/info/n/n611d3e257e54 |
| コード | あり | 「コード用のエリアを埋め込む」ブロック。Ctrl+Alt+\\。インラインコードは `` ` `` の貼り付け変換のみ（推測）。シンタックスハイライトは「今後予定」として 2022 年に告知、編集画面では反映されず投稿後に反映との利用者報告 | https://www.help-note.com/hc/ja/articles/360012426133 、https://note.com/info/n/nbd9ec2e0ade5 、https://note.com/sumini/n/n9cc3d458f5a1 |
| 区切り線 | あり | + ボタン「区切り線」、`---` | https://note.com/info/n/n611d3e257e54 |
| 箇条書き / 番号付き | あり | `-` / `1.`、5 段階まで、Tab / Shift+Tab、Ctrl+] / Ctrl+[ | https://note.com/info/n/n611d3e257e54 |
| チェックボックス | なし | | https://note.com/samurai_worker/n/n5dde9444a33f |
| 目次 | あり | 公開設定で「目次」にチェックすると最初の見出しの上に自動生成。編集画面の左上に見出し一覧が出る | https://www.help-note.com/hc/ja/articles/360017021253 、https://note.com/melsimoon/n/n0eeaa28e74af |
| 画像 | あり | JPG / PNG / GIF / HEIC、1 枚 10MB、複数枚を一度にドラッグ＆ドロップ | https://www.help-note.com/hc/ja/articles/900000134923 、https://note.com/info/n/nedf8b9646b68 |
| 画像のキャプション | あり | 「説明文」。改行も可 | https://note.com/info/n/n611d3e257e54 |
| 画像の alt | あり | 画像選択時に設定 | 同上 |
| ギャラリー（複数枚の横並び） | 確認できず（推測: 無い。複数枚は縦に並ぶ） | | |
| 文字寄せ | あり | 左 / 中央 / 右（Ctrl+Shift+E / L）。公開 HTML では `<p style="text-align: right">` | https://note.com/info/n/naf341f23d0e5 、curl 取得の HTML |
| リンク | あり | 選択 → リンクアイコン → URL | https://www.help-note.com/hc/ja/articles/360008882854 |
| 埋め込み | あり | YouTube / ニコニコ / Vimeo / TikTok / Twitch / Netflix / Apple Music / Spotify / SoundCloud / Voicy / stand.fm / Apple Podcast / X / Instagram / Bluesky / Threads / note 記事 / 外部記事（リンクカード）/ YAMAP / Canva / Figma / SlideShare / GitHub Gist など。一覧外の URL も基本はカードになる | https://www.help-note.com/hc/ja/articles/360019596133 |
| ファイル添付 | あり | psd / zip / PDF など 50MB まで | https://note.com/yriica/n/n542b843228be |
| 数式 | あり | TeX 記法。インラインとディスプレイの 2 種 | https://www.help-note.com/hc/ja/articles/4410665086873 |
| ルビ | あり | `｜漢字《かんじ》`。保存・公開後に表示（編集中は記号のまま） | https://www.help-note.com/hc/ja/articles/4406430353817 |
| テーブル | なし | 画像化・数式（KaTeX の array）・Gist 埋め込み・スプレッドシートからの貼り付けで代用 | https://note.com/ktrito/n/ndb0a0517279b 、https://note.com/sugiponger_1405/n/n773a25ecc1e4 |
| 脚注 | なし | Markdown の脚注は素の文字列になる | https://note.com/honepoo/n/n229459310c9b |
| 色・フォントサイズ・下線 | なし（推測: 公式の一覧に無い） | | |
| 下書き共有 | あり | 非公開のまま共有用リンクで確認 | https://note.com/yriica/n/n542b843228be |
| 同時編集の競合 | あり | 複数デバイスで編集した時に競合した下書きを選べる | https://note.com/info/n/nedf8b9646b68 |

## 2. 書き心地の特徴

- ツールバーの出し方: テキストを選択すると浮くメニュー（太字・取り消し線・リンク・引用・コード・ゴミ箱、見出し、寄せ）。段落の左側に「+」ボタン（画像・ファイル・区切り線・箇条書き・埋め込み等）。2023 年 4〜5 月のカイゼンで「+」を段落選択時に常に出すようにした。
  - 出典: https://note.com/shimomayu/n/ne95a6c9de6c7 、https://note.com/info/n/n17fcf9ff4e37
- `/` コマンド: 確認できず（推測: 無い。「+」ボタンとキーボードショートカットが代わり）。
- Markdown ショートカット: `## ` `### ` `> ` `- ` `1. ` `---` `**` `~~`。h1・表・コードフェンス・チェックボックスは効かない。
  - 出典: https://note.com/info/n/nedf8b9646b68 、https://note.com/samurai_worker/n/n5dde9444a33f
- キーボードショートカット: Ctrl+Z / Y、Ctrl+B、Ctrl+Shift+>（引用）、Ctrl+Alt+0〜2（見出し）、Ctrl+Alt+\\（コード）、Ctrl+Shift+E / L（寄せ）、Ctrl+S（保存）、Ctrl+Shift+8 / 7（リスト）、Ctrl+Shift+↑↓（段落移動）、Ctrl+Shift+X（取り消し線）、選択中 Tab でメニューへフォーカス、Esc で離脱。
  - 出典: https://note.com/info/n/naf341f23d0e5
- 段落の移動: 左端のハンドルをドラッグ＆ドロップ、iOS は縦線を長押し。
  - 出典: 同上
- Enter の挙動: Enter 1 回で改行（`<br>`）、2 回で段落替え。Ctrl+Enter / Shift+Enter は段落内改行。見出しの中で Enter を押すと通常段落に戻る。日本語の書き手からは「エンター 1 回で改行、2 回で段落替えになりました！」と歓迎された。
  - 出典: https://note.com/info/n/nedf8b9646b68 、https://note.com/melsimoon/n/n0eeaa28e74af
- 画像の入れ方: 「+」→ 画像、またはドラッグ＆ドロップ（複数枚可）。画像を選ぶと alt とキャプション（説明文）の入力欄が出る。ペーストについては公式の記述を確認できず（推測: 可）。
  - 出典: https://note.com/info/n/n611d3e257e54 、https://note.com/yriica/n/n542b843228be
- URL を貼った時の挙動: URL を単独の行に貼って Enter（改行）するとカード / 埋め込みに変わる。文中に貼るとテキストのまま。「改行を 2 回するのがポイント」「複数 URL を一度に貼ると埋め込まれない、1 行に 1 URL」。解除は、カードを選んでゴミ箱で URL 表示に戻す。編集中は埋め込みの URL を表示・編集できる。相手サイトが bot を弾く（Cloudflare の Bot Fight Mode など）とカードにならず素のリンクになる。アプリの共有ボタンで得た「共有用 URL」もカードにならない。
  - 出典: https://note.com/riako/n/n4ec70806e3b6 、https://note.com/sumini/n/n9cc3d458f5a1 、https://note.com/hukugyoinfo/n/n5c7a770f997a 、https://note.com/minisuika/n/n15c04242fb83 、https://note.com/info/n/nedf8b9646b68
- 貼り付け: 他エディタからスタイル保持で貼れる。Ctrl+Shift+V でプレーン貼り付け。Markdown テキストを貼ると対応記法だけ変換される（安定しない、との報告）。
  - 出典: https://note.com/info/n/nedf8b9646b68 、https://note.com/honepoo/n/n229459310c9b
- 下書き自動保存: 編集を止めて約 10 秒後に自動保存。Ctrl+S でも保存。
  - 出典: https://www.help-note.com/hc/ja/articles/360009035633
- 文字数表示: 編集画面の右上に本文の文字数（PC ブラウザとアプリ。スマホブラウザは 2023 年に追加）。空白は 1 文字、埋め込みは 0 文字、タイトルは数えない。本文の上限は 20〜30 万字程度、タイトルは 100 文字。
  - 出典: https://note.com/shichaoji/n/n62141c15ca9d 、https://note.com/info/n/n17fcf9ff4e37 、https://note.com/sales_dx2/n/n143fc2bc2ed4
- フォーカスモード: 専用のモードは確認できず。編集画面そのものが見出し画像・タイトル・本文だけで、左上にガイドと見出し一覧（目次プレビュー）が出る構成。
  - 出典: https://note.com/info/n/n17fcf9ff4e37 、https://note.com/melsimoon/n/n0eeaa28e74af
- 今後予定として 2022 年に告知: 校正、Canva での画像作成、コードのハイライト、オフライン保存、下書きの履歴。
  - 出典: https://note.com/info/n/nbd9ec2e0ade5

## 3. 評判

### 高い点（「気持ちよく書ける」の中身）

- 画面がシンプルで、編集画面と公開の見た目が同じ（WYSIWYG）。プレビューを別に開かない。「広告も少なく、記事の見た目もシンプルで、書き手も読み手も余計なノイズがない」。
  - 出典: https://note.com/utsumit/n/n8227b34250be 、https://blogrou.com/note-vs-hatenablog/
- 日本語向けの改行: Enter 1 回で改行、2 回で段落。段落を変えずに改行できて楽。
  - 出典: https://note.com/shimomayu/n/ne95a6c9de6c7 、https://note.com/melsimoon/n/n0eeaa28e74af
- 自動保存で「急なブラウザ閉じも安心」。
  - 出典: https://blogrou.com/note-vs-hatenablog/
- URL を貼るだけでカード / 埋め込みになる。App Store や YouTube のリンク挿入が失敗しなくなった。
  - 出典: https://note.com/melsimoon/n/n0eeaa28e74af
- 見出し一覧が左上に出て、書きながら構成を把握できる。
  - 出典: 同上
- スマホでの執筆と親和性が高い（改行がスマホでも効く、アプリとブラウザで同じ機能）。
  - 出典: 同上、https://zenn.dev/soshi1234/articles/note-qiita-zenn-comparison
- 改善提案が「ものすごくちゃんと検討されている」、4 年で大きく改良された、という継続改善への信頼。
  - 出典: https://note.com/ayamesshi_free/n/ne6db3d95b4a4

### 低い点

- 表が無い。画像化（直すたびに再アップロード、コピーできない）、KaTeX の array（記法が難しい、大きい表は崩れる）、Gist 埋め込み（GitHub アカウントが要る）のどれも面倒。スプレッドシートからの貼り付けで代用する人も。
  - 出典: https://note.com/ktrito/n/ndb0a0517279b 、https://note.com/sumini/n/n9cc3d458f5a1 、https://note.com/chic_wren6567/n/n53d6a7be0529
- 見出しが h2 / h3 の 2 段しかない（h3 が付いたのが 2021 年のベータ）。
  - 出典: https://note.com/info/n/n611d3e257e54 、https://note.com/samurai_worker/n/n5dde9444a33f
- Markdown を「文書形式」として扱わない。貼り付け時の変換が不安定で、閉じ忘れ・全角スペース・不規則な改行があると素の文字列になる。表・コードフェンス・脚注は変換されない。Android アプリは Markdown の貼り付けが効かない。
  - 出典: https://note.com/honepoo/n/n229459310c9b 、https://note.com/ayatokura/n/n7034c566ac37 、https://note.com/galacta_dm/n/n5984294ad119
- コードのシンタックスハイライトが編集画面で反映されない（投稿後のみ）。
  - 出典: https://note.com/sumini/n/n9cc3d458f5a1
- 引用の中に空行を置けない（全角スペースで代用）。
  - 出典: 同上
- リンクカードが出ない時の原因が分かりにくい（相手サイトの bot 対策、共有用 URL、非公開）。
  - 出典: https://note.com/link_lab847/n/nd8481465199a 、https://note.com/minisuika/n/n15c04242fb83
- 文字の色・サイズ・下線が無い、見た目のカスタマイズができない（はてなブログとの比較で「見た目も作品の一部と捉えるならはてな」）。
  - 出典: https://note.com/hasek_life/n/ne6f619ad76ed

## 4. 公開記事ページの HTML 構造（実測）

取得した記事: https://note.com/info/n/n611d3e257e54 、https://note.com/ktrito/n/ndb0a0517279b 、https://note.com/melsimoon/n/n0eeaa28e74af （curl、Nuxt の SSR 出力）。

本文の入れ物:

```html
<div data-name="body" class="note-common-styles__textnote-body" data-v-62deca21>
```

各ブロック要素に UUID の `name`（新しい記事では `id` も）が付く。段落は `<p name=... id=...>`。

### 見出し

```html
<h2 name="6b466e6f-..." id="...">新機能の紹介</h2>
<h3 name="d71b41db-..."><br>1. 小見出し(h3)&nbsp;</h3>
```

h1 は本文に出ない。h4 以下も無い。

### 画像 + キャプション

```html
<figure name="399a3e38-...">
  <img src="https://assets.st-note.com/img/1635327155397-o3rHsXYFO7.png?width=1200" alt="" width="620" height="349" loading="lazy">
  <figcaption>noteの街イラスト。遠近感を演出する手前のカモメは、…</figcaption>
</figure>
```

キャプションが無い画像でも `<figcaption></figcaption>` が空で出る。

### 引用 + 出典

引用は `figure > blockquote > p` で、出典は `figcaption` に入る。出典に URL があれば `<a>` になる。

```html
<figure name="24efa9ce-...">
  <blockquote><p>だれもが創作をはじめ、続けられるようにする。</p></blockquote>
  <figcaption><a href="https://note.jp/n/n2f53a4aaa07d" target="_blank" rel="noopener nofollow">note株式会社のミッション</a></figcaption>
</figure>
```

出典が無い引用も `<figcaption></figcaption>` が空で付く。引用内の改行は `<br>`、リンクと `<strong>` を含められる。

### 外部リンクカード（`external-article`）

iframe ではなく、サーバ側で OGP を取って静的な `<a>` に展開している。画像は `background-image`。

```html
<figure embedded-content-key="embed6208f8255a" embedded-service="external-article" contenteditable="false" name="931c1890-...">
  <div data-name="embedContainer"><div data-embed-service="external-article"><span>
    <div class="external-article-widget">
      <a href="https://apps.apple.com/jp/app/ulysses/id1225571038" rel="noopener nofollow" target="_blank">
        <strong class="external-article-widget-title">‎Ulysses</strong>
        <em class="external-article-widget-description">‎UlyssesはMac、iPhone、iPad対応のワンストップライティング環境です。…</em>
        <em class="external-article-widget-url">apps.apple.com</em>
      </a>
      <a class="external-article-widget-image" href="https://apps.apple.com/jp/app/ulysses/id1225571038" rel="noopener nofollow"
         style="background-image: url('https://d2l930y2yx77uc.cloudfront.net/production/uploads/ext/….png');" target="_blank"></a>
    </div>
  </span></div></div>
</figure>
```

OGP 画像は note 側の CDN（cloudfront）に写している。説明文は途中で切られている。

### note 記事の埋め込み（`note`）

同じ figure の骨組みで、中身は iframe（`https://note.com/embed/notes/{key}`）。lazy load で `data-src`、`visibility: hidden` で読み込むまで隠す。

```html
<figure name="660125eb-..." data-src="https://note.com/info/n/nedf8b9646b68" data-identifier="nedf8b9646b68" embedded-service="note" embedded-content-key="embab76e0920122">
  <div data-name="embedContainer"><div data-embed-service="note">
    <iframe class="note-embed" height="210" scrolling="no" style="border: 0px; display: block; max-width: 99%; width: 494px; …; visibility: hidden;" loading="lazy" data-src="https://note.com/embed/notes/nedf8b9646b68"></iframe>
    <a href="https://note.com/info/n/nedf8b9646b68" target="_blank" style="visibility: hidden;" rel="noopener"></a>
  </div></div>
</figure>
```

### その他のサービス埋め込み（`gist` など）

Iframely を経由（`iframely-embed` + `cdn.iframe.ly/embed.js`）。YouTube / X は今回の 3 本に無く未確認だが、`embedded-service` 属性の値と Iframely の組で同じ形と推測。

```html
<figure … data-src="https://gist.github.com/…" embedded-service="gist" embedded-content-key="emb6121c17c8be3">
  <div data-name="embedContainer"><div data-embed-service="gist"><span>
    <div class="iframely-embed"><div class="iframely-responsive" style="padding-bottom: 50%;">
      <a href="https://gist.github.com/…" data-iframely-url="//cdn.iframe.ly/xcRDEus5"></a>
    </div></div>
    <script async="" src="//cdn.iframe.ly/embed.js" charset="utf-8"></script>
  </span></div></div>
</figure>
```

### コード

```html
<pre name="edc2e3bb-…" id="…" data-name="preCode"><code data-name="code">$$
\begin{array}{l|r}
…
$$</code></pre>
```

言語の属性は付いていない。

### 区切り線・リスト・寄せ・インライン

```html
<hr name="a9a67239-…">
<ul name="3d05da8d-…"><li><p>階層は5段階まで設定できます</p><ul><li><p>…</p></li></ul></li></ul>
<p style="text-align: right" name="…" id="…">…</p>
<strong>…</strong>  <s>…</s>  <a href="…" target="_blank" rel="noopener nofollow">…</a>
```

li の中は `<p>` で包まれる（ProseMirror の list schema の癖）。外部リンクは全て `target="_blank" rel="noopener nofollow"`。ルビ（`<ruby>`）と数式は今回の 3 本に無く未確認。

## 5. 他サービスの同じ観点

### Medium

- ツールバーは選択時に浮く。空行で左に「+」が出て画像・埋め込み・コードブロック・区切りを選ぶ。URL を単独行に貼って Enter で埋め込み（unfurl）。画像はクリックでキャプション入力、alt も付けられる。見出しは 2 段（Title / Subtitle 相当の T 大小）。引用は 2 種（blockquote と pull quote）。
  - 出典: https://help.medium.com/hc/en-us/articles/215194537-Using-the-story-editor （検索スニペット。本文は 403）、https://medium.com/@s.birntachas/medium-editor-keyboard-shortcuts-and-tips-b03d8520fe35
- 公開 HTML は `figure > img + figcaption`、リンクカードは `<a>` にタイトル・説明・ドメイン・画像を並べた mixtapeEmbed（推測: 一般知識。今回未取得）。

### Zenn

- Markdown が正。画像のキャプションは画像の直下の行を `*…*` で囲む。引用は `>`。リンクカードは `@[card](URL)`、または URL を単独行に置く。YouTube / X / GitHub などは URL だけで埋め込み。脚注 `[^1]`、表、KaTeX、`:::message` / `:::details` あり。変換は zenn-markdown-html。
  - 出典: https://zenn.dev/zenn/articles/markdown-guide 、https://zenn-dev.github.io/zenn-docs-for-developers/guides/zenn-editor/zenn-markdown-html
- リンクカードは iframe（zenn.dev/link-card）で描画される（推測: 一般知識）。

### Notion

- URL を貼ると「Dismiss / Create bookmark / Create embed / Mention」を選ぶメニューが出る。ブックマークはタイトル・説明・URL・画像のブロック、埋め込みは Iframely 経由で 1,900 ドメイン以上。画像・動画・ファイル・コードにキャプションを付けられる。引用はブロック。`/` コマンドでブロックを選ぶ。
  - 出典: https://www.notion.com/help/embed-and-connect-other-apps 、https://www.notion.com/help/guides/types-of-content-blocks

### はてなブログ

- はてな記法 `[URL:embed:cite]` でブログカード。`:embed` がカードのみ、`:embed:title` がカード + タイトル。カードは iframe（`class="embed-card embed-blogcard"`）で hatenablog-parts.com から描画。編集サイドバーの「リンク」からも挿入。oEmbed 対応サイトの動画・音楽も同じ記法。画像は `<img>` + 直後の段落で、`figure/figcaption` の専用機能は無い（推測）。引用は `>>` 〜 `<<` で `blockquote`、`cite` は記法 `[URL:cite]`。
  - 出典: https://staff.hatenablog.com/entry/2014/08/29/141633 、https://rubirubi.hateblo.jp/entry/hatena-embed-customization 、https://nujust.hatenablog.com/entry/2022/07/24/202935

## 設計に活かす要点

1. ブロックの語彙を絞る（段落 / h2 / h3 / 引用 / コード / 区切り / リスト / 画像 / 埋め込み）。note はこの範囲で「シンプルで気持ちよく書ける」と言われている。足りない不満は表・脚注・見出し段数の 3 つに集中しているので、そこだけ note より先に用意する。
2. 画像と引用は「本体 + キャプション」を 1 つの figure として持つ。note は画像は `figure > img + figcaption`、引用は `figure > blockquote + figcaption(出典、URL 可)`。出典が空でも figcaption を空で出す設計は真似しない方が良い（空要素が残る）。
3. 外部リンクカードは iframe ではなく、サーバ側で OGP を取って `title / description / url(ホスト) / image` の 4 つを静的 HTML（`<a>`）に展開し、画像は自前 CDN に写す。自社コンテンツ（note 記事）だけ iframe。
4. URL の貼り付けは「単独行 + Enter」でカード化、文中はテキストリンク、という 1 つの規則にする。カード化しなかった理由（bot 拒否、非公開、共有用 URL）は編集画面で見せる。カードは削除で素の URL に戻せる。
5. Enter 1 回で `<br>`、2 回で段落。日本語の書き手が最も歓迎した挙動。Shift+Enter / Ctrl+Enter も同じく段落内改行に。
6. Markdown はショートカット（入力時の変換）として持ち、貼り付けの Markdown 解釈は「見出し・強調・リスト・引用・区切り」に限るか、明示的に「Markdown として貼る」を用意して不安定さを避ける。Ctrl+Shift+V のプレーン貼り付けも。
7. 段落のドラッグハンドルと Ctrl+Shift+↑↓、選択時の浮くツールバー、段落選択時に常に出る「+」。`/` コマンドは note に無いが Notion の利用者は期待するので併設して良い。
8. 自動保存（約 10 秒の debounce）と Ctrl+S、複数デバイスの競合検知、下書きの共有 URL。文字数は右上に常時表示し、埋め込みは 0、空白は 1 で数える。
9. 編集画面の左上に見出し一覧（目次プレビュー）を出し、公開側の目次はそこから自動生成。
10. 公開 HTML は各ブロックに安定した id を付け（note は UUID）、`h2/h3`、`figure`、`pre > code`、`ul > li > p` の素直なタグで出す。コードには言語の属性を付けてハイライトは編集画面でも同じに出す（note で不満のあった点）。
