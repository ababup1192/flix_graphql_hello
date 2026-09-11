// 空の段落の左に出る「+」と、そこから開くブロックの一覧。`/` でも同じ一覧が開く。
//
// **「+」は空の段落にカーソルがある間は常時出す**（ホバーではない。note が 2023 年に変えた点。
// `docs/design/richtext-note-style.md` 6.1）。一覧は 画像 / 区切り線 / 引用 / コード / 表 / 埋め込み。
//
// WhyNot: 「+」を ProseMirror の DOM の中に入れない。段落の node view を作ると、打っている間に
// 作り直されて「知らない DOM」として戻される（表の掴みと同じ理由）。`.tt-mount` の層に置く。
//
// WhyNot: 表を升目で選ばせない。一覧は縦 1 列の速い道で、大きさは表の上の帯（大きさを変える）で
// 後から直せる。

import type { Editor } from "@tiptap/core";
import { dismissOn } from "./dismiss";
import { placeUnder } from "./place";
import { placeUrl, soleUrl } from "./url-cards";

type Item = {
  label: string;
  // `/` の後に打った文字で絞る時の見出し語（ひらがなと英語も受ける）。
  keys: string[];
  icon: string;
  run: () => void;
};

type Args = {
  editor: Editor;
  host: HTMLElement;
  mount: HTMLElement;
  onImage: () => void;
};

const ICONS: Record<string, string> = {
  image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="9.5" r="1.5"/><path d="m4 17 4.5-4.5 3 3L15 12l5 5"/>',
  rule: '<path d="M3 12h18"/>',
  quote: '<path d="M9 6H5a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v2a2 2 0 0 1-2 2H4"/><path d="M19 6h-4a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v2a2 2 0 0 1-2 2h-1"/>',
  code: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M10 10l-2 2 2 2"/><path d="M14 10l2 2-2 2"/>',
  table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18"/><path d="M3 15h18"/><path d="M9 10v10"/>',
  embed: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  plus: '<path d="M12 5v14"/><path d="M5 12h14"/>',
};

function svg(paths: string): string {
  return `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths}</svg>`;
}

/** カーソルが、他の block に包まれていない空の段落の中にあるか。 */
export function atEmptyParagraph(editor: Editor): boolean {
  const { $from, empty } = editor.state.selection;
  return empty && $from.depth === 1 && $from.parent.type.name === "paragraph" && $from.parent.content.size === 0;
}

// `/` で開いている時の、段落の中の文字（`/` を含む）。段落が `/` で始まっていなければ null。
function slashText(editor: Editor): string | null {
  const { $from, empty } = editor.state.selection;
  if (!empty || $from.depth !== 1 || $from.parent.type.name !== "paragraph") return null;
  const text = $from.parent.textContent;
  return text.startsWith("/") ? text : null;
}

export class BlockMenu {
  private editor: Editor;
  private host: HTMLElement;
  private mount: HTMLElement;
  private plus: HTMLButtonElement;
  private menu: HTMLElement | null = null;
  private list: HTMLElement | null = null;
  private unmenu: (() => void) | null = null;
  private at = 0;
  private shown: Item[] = [];
  // `/` から開いた時は true。選んだら打った文字を消してから入れる。
  private bySlash = false;
  private items: Item[];

  constructor(args: Args) {
    this.editor = args.editor;
    this.host = args.host;
    this.mount = args.mount;
    const chain = () => this.editor.chain().focus();
    this.items = [
      { label: "画像", keys: ["がぞう", "image", "img"], icon: ICONS.image, run: () => args.onImage() },
      { label: "区切り線", keys: ["くぎりせん", "hr", "rule", "divider"], icon: ICONS.rule, run: () => chain().setHorizontalRule().run() },
      { label: "引用", keys: ["いんよう", "quote"], icon: ICONS.quote, run: () => chain().toggleBlockquote().run() },
      { label: "コード", keys: ["こーど", "code"], icon: ICONS.code, run: () => chain().toggleCodeBlock().run() },
      { label: "表", keys: ["ひょう", "table", "てーぶる"], icon: ICONS.table, run: () => chain().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run() },
      { label: "埋め込み", keys: ["うめこみ", "embed", "url", "りんく", "link"], icon: ICONS.embed, run: () => this.askUrl() },
    ];

    this.plus = document.createElement("button");
    this.plus.type = "button";
    this.plus.className = "tt-plus";
    this.plus.title = "ブロックを追加";
    this.plus.setAttribute("aria-label", "ブロックを追加");
    this.plus.innerHTML = svg(ICONS.plus);
    this.plus.hidden = true;
    // 押しても本文の選択を外さない（外れると「空の段落」の判定が消え、入れる所が無くなる）。
    this.plus.addEventListener("mousedown", (event) => event.preventDefault());
    this.plus.addEventListener("click", () => (this.menu ? this.close() : this.open(false)));
    this.mount.appendChild(this.plus);
  }

  /** transaction ごとに呼ぶ。「+」の出し入れと、`/` の一覧の絞り込み。 */
  update() {
    this.paintPlus();
    if (!this.bySlash || !this.menu) return;
    const text = slashText(this.editor);
    if (text === null) {
      this.close();
      return;
    }
    this.filter(text.slice(1));
  }

  /** `/` が打たれた。空の段落なら一覧を開く（`/` そのものは段落に入る）。 */
  onSlash(): boolean {
    if (!atEmptyParagraph(this.editor) || this.menu) return false;
    // `/` が doc に入ってから開く（開いた直後の update が「/ で始まる段落」を見る）。
    window.setTimeout(() => this.open(true), 0);
    return false;
  }

  /** 一覧が開いている間のキー。上下・Enter・Escape を食べる。 */
  onKey(event: KeyboardEvent): boolean {
    if (!this.menu || this.urlBox) return false;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      const step = event.key === "ArrowDown" ? 1 : -1;
      this.at = (this.at + step + this.shown.length) % Math.max(this.shown.length, 1);
      this.paintList();
      return true;
    }
    if (event.key === "Enter") {
      const picked = this.shown[this.at];
      if (picked) this.pick(picked);
      return true;
    }
    return false;
  }

  private paintPlus() {
    const show = atEmptyParagraph(this.editor) && (this.editor.isFocused || this.menu !== null);
    this.plus.hidden = !show;
    if (!show) return;
    const { $from } = this.editor.state.selection;
    const dom = this.editor.view.nodeDOM($from.before()) as HTMLElement | null;
    if (!dom) return;
    const base = this.mount.getBoundingClientRect();
    const at = dom.getBoundingClientRect();
    const size = 24;
    this.plus.style.left = `${Math.max(at.left - base.left - size - 6, 2)}px`;
    this.plus.style.top = `${at.top - base.top + (at.height - size) / 2}px`;
  }

  private open(bySlash: boolean) {
    this.bySlash = bySlash;
    const menu = document.createElement("div");
    menu.className = "tt-menu tt-blocks";
    const list = document.createElement("div");
    list.className = "tt-blocks-list";
    menu.appendChild(list);
    this.menu = menu;
    this.list = list;
    this.at = 0;
    this.host.appendChild(menu);
    this.filter("");
    // `/` で開いた時は「+」が消えている（段落が空でない）ので、段落そのものの下に置く。
    const { $from } = this.editor.state.selection;
    const paragraph = this.editor.view.nodeDOM($from.before()) as HTMLElement | null;
    placeUnder(menu, bySlash && paragraph ? paragraph : this.plus, 200);
    this.unmenu = dismissOn({ inside: [menu, this.plus], onClose: () => this.close() });
  }

  private filter(query: string) {
    const needle = query.trim().toLowerCase();
    this.shown = needle
      ? this.items.filter((item) => item.label.includes(needle) || item.keys.some((key) => key.includes(needle)))
      : this.items;
    this.at = Math.min(this.at, Math.max(this.shown.length - 1, 0));
    this.paintList();
  }

  private paintList() {
    const list = this.list;
    if (!list) return;
    if (this.shown.length === 0) {
      const none = document.createElement("span");
      none.className = "tt-blocks-none";
      none.textContent = "見つかりません";
      list.replaceChildren(none);
      return;
    }
    list.replaceChildren(
      ...this.shown.map((item, index) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "tt-blocks-item" + (index === this.at ? " is-at" : "");
        button.innerHTML = svg(item.icon);
        const label = document.createElement("span");
        label.textContent = item.label;
        button.appendChild(label);
        button.addEventListener("mousedown", (event) => {
          event.preventDefault();
          this.pick(item);
        });
        button.addEventListener("mousemove", () => {
          if (this.at === index) return;
          this.at = index;
          this.paintList();
        });
        return button;
      }),
    );
  }

  private pick(item: Item) {
    // `/` で打った文字を消してから入れる（残すと「/ひょう」が表の前に残る）。
    if (this.bySlash) {
      // WhyNot: 消してから降ろさない。消した瞬間の transaction が `update()` を呼び、
      // まだ `/` から開いた事になっていると「段落が `/` で始まらない」と見て一覧を閉じる。
      // 面を残す物（埋め込みの URL の欄）は、閉じられた後では置き場を失って何も出ない。
      this.bySlash = false;
      const { $from } = this.editor.state.selection;
      if ($from.parent.textContent.startsWith("/")) {
        this.editor.view.dispatch(this.editor.state.tr.delete($from.start(), $from.end()));
      }
    }
    if (item.label === "埋め込み") {
      item.run();
      return;
    }
    this.close();
    item.run();
  }

  private urlBox: HTMLInputElement | null = null;

  // 埋め込みは URL を 1 つ聞く。判定は貼った時と同じ（YouTube / Vimeo / X は embed、他は linkCard）。
  private askUrl() {
    const list = this.list;
    if (!list) return;
    const input = document.createElement("input");
    input.type = "url";
    input.className = "tt-blocks-url";
    input.placeholder = "URL を入力";
    input.setAttribute("aria-label", "埋め込む URL");
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        const url = soleUrl(input.value);
        input.classList.toggle("is-bad", url === null);
        if (!url) return;
        this.close();
        placeUrl(this.editor, url);
      }
    });
    this.urlBox = input;
    list.replaceChildren(input);
    input.focus();
  }

  private close() {
    this.unmenu?.();
    this.unmenu = null;
    this.menu?.remove();
    this.menu = null;
    this.list = null;
    this.urlBox = null;
    this.bySlash = false;
    this.editor.commands.focus();
    this.paintPlus();
  }

  destroy() {
    this.close();
    this.plus.remove();
  }
}
