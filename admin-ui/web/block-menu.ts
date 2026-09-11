// 空の段落の左に出る「+」と、そこから開くブロックの一覧。`/` でも同じ一覧が開く。
//
// **「+」は空の段落にカーソルがある間は常時出す**（ホバーではない。note が 2023 年に変えた点。
// `docs/design/richtext-note-style.md` 6.1）。一覧は 画像 / 区切り線 / 引用 / コード / 表 / 数式 /
// チェックリスト / 埋め込み。
//
// **ブロックを入れる口はここに集める。** ヘッダは押すだけで入る物、浮く帯は文字に掛ける物
// （`docs/design/toolbar-split-mock.html` の案 D）なので、画像以外はここからしか入らない。
//
// WhyNot: 「+」を ProseMirror の DOM の中に入れない。段落の node view を作ると、打っている間に
// 作り直されて「知らない DOM」として戻される（表の掴みと同じ理由）。`.tt-mount` の層に置く。
//
// WhyNot: 表だけは一覧で終わらせない。行と列の数は入れる前に決めたい物なので、
// 升目（`tiptap-editor.ts` の `tableMenu`）に渡す。

import type { Editor } from "@tiptap/core";
import { field, iconButton, popover, type Popover } from "./ui";
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
  onTable: () => void;
};

const ICONS: Record<string, string> = {
  image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="9.5" r="1.5"/><path d="m4 17 4.5-4.5 3 3L15 12l5 5"/>',
  rule: '<path d="M3 12h18"/>',
  quote: '<path d="M9 6H5a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v2a2 2 0 0 1-2 2H4"/><path d="M19 6h-4a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v2a2 2 0 0 1-2 2h-1"/>',
  code: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M10 10l-2 2 2 2"/><path d="M14 10l2 2-2 2"/>',
  table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18"/><path d="M3 15h18"/><path d="M9 10v10"/>',
  embed: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  plus: '<path d="M12 5v14"/><path d="M5 12h14"/>',
  math: '<path d="M17 5H7l6 7-6 7h10"/>',
  taskList: '<path d="M11 6h10"/><path d="M11 12h10"/><path d="M11 18h10"/><path d="M3 6l1.5 1.5L7 5"/><path d="M3 12l1.5 1.5L7 11"/><path d="M3 18l1.5 1.5L7 17"/>',
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
  private mount: HTMLElement;
  private plus: HTMLButtonElement;
  // 一覧は開き直すたびに作らず、`.tt-mount` の中に 1 つ持って出し入れする
  // （親を基準に置く面なので、本文を送っても付いたまま動く）。
  private pop: Popover;
  private list: HTMLElement;
  private at = 0;
  private shown: Item[] = [];
  // `/` から開いた時は true。選んだら打った文字を消してから入れる。
  private bySlash = false;
  private items: Item[];
  // WhyNot: 「+」の位置を transaction の時だけ測らない。gallery のキャプションの開閉や
  // 画像の読み込みは transaction を伴わずに本文の高さを変えるので、測った位置が取り残され、
  // 本文の枠の外（下のフィールド）に出る。
  private watch: ResizeObserver | null = null;
  private alive = true;

  constructor(args: Args) {
    this.editor = args.editor;
    this.mount = args.mount;
    const chain = () => this.editor.chain().focus();
    this.items = [
      { label: "画像", keys: ["がぞう", "image", "img"], icon: ICONS.image, run: () => args.onImage() },
      { label: "区切り線", keys: ["くぎりせん", "hr", "rule", "divider"], icon: ICONS.rule, run: () => chain().setHorizontalRule().run() },
      { label: "引用", keys: ["いんよう", "quote"], icon: ICONS.quote, run: () => chain().toggleBlockquote().run() },
      { label: "コード", keys: ["こーど", "code"], icon: ICONS.code, run: () => chain().toggleCodeBlock().run() },
      { label: "表", keys: ["ひょう", "table", "てーぶる"], icon: ICONS.table, run: () => args.onTable() },
      { label: "数式", keys: ["すうしき", "math", "tex", "katex", "formula"], icon: ICONS.math, run: () => this.insertMath() },
      { label: "チェックリスト", keys: ["ちぇっくりすと", "task", "todo", "check"], icon: ICONS.taskList, run: () => chain().toggleTaskList().run() },
      { label: "埋め込み", keys: ["うめこみ", "embed", "url", "りんく", "link"], icon: ICONS.embed, run: () => this.askUrl() },
    ];

    // 押しても本文の選択を外さない（外れると「空の段落」の判定が消え、入れる所が無くなる）。
    this.plus = iconButton({
      className: "tt-plus",
      icon: svg(ICONS.plus),
      title: "ブロックを追加",
      onClick: () => (this.pop.isOpen ? this.close() : this.open(false)),
    });
    this.plus.hidden = true;
    this.mount.appendChild(this.plus);

    this.pop = popover({
      anchor: this.mount,
      place: { side: "below", align: "start" },
      className: "tt-menu tt-blocks",
      keep: [this.plus],
      bounds: this.editor.view.dom,
      onClose: () => this.afterClose(),
    });
    this.list = document.createElement("div");
    this.list.className = "tt-blocks-list";
    this.pop.dom.appendChild(this.list);

    if (typeof ResizeObserver === "function") {
      this.watch = new ResizeObserver(() => this.paintPlus());
      this.watch.observe(this.editor.view.dom);
      this.watch.observe(this.mount);
    }
  }

  /** transaction ごとに呼ぶ。「+」の出し入れと、`/` の一覧の絞り込み。 */
  update() {
    this.paintPlus();
    // node view が class を付け替えて高さを変えるのは、この transaction が描き終わった後。
    window.requestAnimationFrame(() => {
      if (this.alive) this.paintPlus();
    });
    if (!this.bySlash || !this.pop.isOpen) return;
    const text = slashText(this.editor);
    if (text === null) {
      this.close();
      return;
    }
    this.filter(text.slice(1));
  }

  /** `/` が打たれた。空の段落なら一覧を開く（`/` そのものは段落に入る）。 */
  onSlash(): boolean {
    if (!atEmptyParagraph(this.editor) || this.pop.isOpen) return false;
    // `/` が doc に入ってから開く（開いた直後の update が「/ で始まる段落」を見る）。
    window.setTimeout(() => this.open(true), 0);
    return false;
  }

  /** 一覧が開いている間のキー。上下・Enter・Escape を食べる。 */
  onKey(event: KeyboardEvent): boolean {
    if (!this.pop.isOpen || this.urlBox) return false;
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
    this.placePlus();
    // 本文の高さが変わっても面が付いたままになるよう、「+」を置いた後に面も置き直す。
    this.pop.place();
  }

  private placePlus() {
    const show = atEmptyParagraph(this.editor) && (this.editor.isFocused || this.pop.isOpen);
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
    this.at = 0;
    this.urlBox = null;
    // `/` で開いた時は「+」が消えている（段落が空でない）ので、段落そのものの下に置く。
    const { $from } = this.editor.state.selection;
    const paragraph = this.editor.view.nodeDOM($from.before()) as HTMLElement | null;
    this.pop.open(bySlash && paragraph ? paragraph : this.plus);
    this.filter("");
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
    if (this.shown.length === 0) {
      const none = document.createElement("span");
      none.className = "tt-blocks-none";
      none.textContent = "見つかりません";
      list.replaceChildren(none);
      this.pop.place();
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
    // 絞り込みで行数が変わると高さが変わるので、置き直す（下に入らなければ上へ返る）。
    this.pop.place();
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

  // 段落の数式。入れた後、その箱の TeX の欄を開いて焦点を入れる。
  //
  // WhyNot: 入れた後のカーソルに任せない。mathBlock は atom で、TeX の欄は node view の中の
  // textarea（`stopEvent` が鍵を食べる）なので、打った字が次の段落に流れる。箱を押した時と
  // 同じ道（mousedown）を通して欄を開く。
  private insertMath() {
    const editor = this.editor;
    const at = editor.state.selection.from;
    editor.chain().focus().insertContent({ type: "mathBlock", attrs: { tex: "" } }).run();
    window.setTimeout(() => {
      let found = -1;
      editor.state.doc.descendants((node, pos) => {
        if (node.type.name !== "mathBlock") return;
        if (found < 0 || Math.abs(pos - at) < Math.abs(found - at)) found = pos;
      });
      if (found < 0) return;
      const dom = editor.view.nodeDOM(found);
      if (!(dom instanceof HTMLElement)) return;
      dom.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    }, 0);
  }

  private urlBox: HTMLInputElement | null = null;

  // 埋め込みは URL を 1 つ聞く。判定は貼った時と同じ（YouTube / Vimeo / X は embed、他は linkCard）。
  private askUrl() {
    const input = field({
      className: "tt-blocks-url",
      type: "url",
      placeholder: "URL を入力",
      label: "埋め込む URL",
      onCommit: (value) => {
        // WhyNot: 空で赤を出さない。面を閉じると欄が焦点を失って確定が通るので、
        // 何も打たずに閉じただけで赤い枠が一瞬出る。
        if (value.trim() === "") return;
        const url = soleUrl(value);
        input.classList.toggle("is-bad", url === null);
        if (!url) return;
        this.close();
        placeUrl(this.editor, url);
      },
    });
    this.urlBox = input;
    this.list.replaceChildren(input);
    this.pop.place();
    input.focus();
  }

  private close() {
    this.pop.close();
  }

  // 面が閉じた後の後始末（外を押した / Esc でも通る）。
  private afterClose() {
    this.urlBox = null;
    this.bySlash = false;
    this.editor.commands.focus();
    this.placePlus();
  }

  destroy() {
    this.alive = false;
    this.watch?.disconnect();
    this.watch = null;
    this.pop.destroy();
    this.plus.remove();
  }
}
