// リッチエディタを custom element に包む。
//
// Elm からは `doc` 属性（doc の JSON の文字列）を渡し、変わったら `docchange` の
// CustomEvent で返す。Elm は TipTap の存在を知らない。
//
// doc の形は CMS の RichText が正。**知らない node は消さずに素通しする**
// （画面が対応していない node を含む記事を開いて保存しても壊さない）。

import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import Link from "@tiptap/extension-link";
import TaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";
import Underline from "@tiptap/extension-underline";
import Table from "@tiptap/extension-table";
import TableRow from "@tiptap/extension-table-row";
import TableCell from "@tiptap/extension-table-cell";
import TableHeader from "@tiptap/extension-table-header";
import { Node } from "@tiptap/core";
import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import { codeBlockView, ensureUsed } from "./code-block";
import { BlockEdges, hasPendingLine } from "./block-edges";
import { CodeEditing } from "./code-editing";
import { LinkDialog, type Candidate, type LinkChoice } from "./link-dialog";
import { dismissOn } from "./dismiss";
import { MathBlock, MathMark } from "./math";
import { AssetStore, galleryNode, imageDropExtension, imageNode, insertionOf, UploadingImage } from "./image-node";
import { createLowlight } from "lowlight";

// 色付けの入れ物。言語の文法は使われた時に入る（`web/code-languages.ts`）。
const lowlight = createLowlight();

// 対応していない node は「そのまま持つ」node として受け、保存で元の形に戻す。
const Passthrough = Node.create({
  name: "passthrough",
  group: "block",
  atom: true,
  addAttributes() {
    return { original: { default: null } };
  },
  parseHTML() {
    return [{ tag: "div[data-passthrough]" }];
  },
  renderHTML({ HTMLAttributes }) {
    const type = HTMLAttributes.original?.type ?? "?";
    return ["div", { "data-passthrough": "", class: "tt-passthrough" }, `（この画面では編集できません: ${type}）`];
  },
});

const EMPTY_DOC = { type: "doc", content: [] };

type Tool = {
  kind: "button" | "divider" | "spacer" | "block";
  label?: string;
  icon?: string;
  title?: string;
  run?: () => void;
  active?: () => boolean;
  // 押せるか。**押せない物は薄くする**（元に戻す物が無いのに押せるように見えない）。
  enabled?: () => boolean;
};

// 段落の種類。CMS は見出し 1〜4 まで受ける。
const BLOCKS: Array<[string, string]> = [
  ["paragraph", "本文"],
  ["h1", "見出し 1"],
  ["h2", "見出し 2"],
  ["h3", "見出し 3"],
  ["h4", "見出し 4"],
];

// ツールバーのアイコン。24px の枠、線 1.8（Ui.Icon と同じ流儀）。
const ICONS = {
  paragraph: '<path d="M13 4v16"/><path d="M17 4v16"/><path d="M19 4H9.5a4.5 4.5 0 0 0 0 9H13"/>',
  code: '<path d="M16 18l6-6-6-6"/><path d="M8 6l-6 6 6 6"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  bulletList: '<path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/>',
  orderedList: '<path d="M10 6h11"/><path d="M10 12h11"/><path d="M10 18h11"/><path d="M4 6h1v4"/><path d="M4 10h2"/><path d="M6 18H4c0-1 2-2 2-3s-1-1.5-2-1"/>',
  taskList: '<path d="M11 6h10"/><path d="M11 12h10"/><path d="M11 18h10"/><path d="M3 6l1.5 1.5L7 5"/><path d="M3 12l1.5 1.5L7 11"/><path d="M3 18l1.5 1.5L7 17"/>',
  quote: '<path d="M9 6H5a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v2a2 2 0 0 1-2 2H4"/><path d="M19 6h-4a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v2a2 2 0 0 1-2 2h-1"/>',
  codeBlock: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M10 10l-2 2 2 2"/><path d="M14 10l2 2-2 2"/>',
  rule: '<path d="M3 12h18"/>',
  underline: '<path d="M7 4v6a5 5 0 0 0 10 0V4"/><path d="M5 20h14"/>',
  table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18"/><path d="M3 15h18"/><path d="M9 10v10"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="9.5" r="1.5"/><path d="m4 17 4.5-4.5 3 3L15 12l5 5"/>',
  // WhyNot: 丸い矢印（rotate-ccw / rotate-cw）にしない。16px では左右の違いが読めず、
  // 2 つ並ぶと同じ印に見える。矢の頭が横を向く形にして、向きを一目で分かるようにする。
  undo: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5A5.5 5.5 0 0 1 20 14.5 5.5 5.5 0 0 1 14.5 20H11"/>',
  redo: '<path d="m15 14 5-5-5-5"/><path d="M20 9H9.5A5.5 5.5 0 0 0 4 14.5 5.5 5.5 0 0 0 9.5 20H13"/>',
};

function svg(paths: string): string {
  return `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths}</svg>`;
}

// TipTap が知らない node を Passthrough に畳む。
function foldUnknown(node: any, known: Set<string>): any {
  if (!node || typeof node !== "object") return node;
  if (node.type && node.type !== "doc" && !known.has(node.type)) {
    return { type: "passthrough", attrs: { original: node } };
  }
  if (Array.isArray(node.content)) {
    return { ...node, content: node.content.map((child: any) => foldUnknown(child, known)) };
  }
  return node;
}

// 保存の時に Passthrough を元の形に戻す。
function unfold(node: any): any {
  if (!node || typeof node !== "object") return node;
  if (node.type === "passthrough") return node.attrs?.original ?? node;
  const next = { ...node };
  // 送っている途中の仮の見た目は保存に出さない（CMS が知らない node で、断られる）。
  if (Array.isArray(node.content)) {
    next.content = node.content.filter((child: any) => child?.type !== "uploading").map(unfold);
  }
  return dropEmptyAttrs(next);
}

// **値の無い attrs を落とす。**
// TipTap は指定していない属性も `null` で持つ（codeBlock の language など）。
// そのまま送ると CMS が「language は小文字英数字で 1〜32 文字」と断る（実際に断られた）。
function dropEmptyAttrs(node: any): any {
  if (!node.attrs) return node;
  const attrs: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(node.attrs)) {
    if (value !== null && value !== undefined && value !== "") attrs[key] = value;
  }
  if (Object.keys(attrs).length === 0) {
    const { attrs: _dropped, ...rest } = node;
    return rest;
  }
  return { ...node, attrs };
}

// 言語は使われた時に読む（`web/code-languages.ts`）。**最初に全部読まない**
// （70 以上あるので、エディタを開くだけで重くなる）。


class TiptapEditor extends HTMLElement {
  private editor: Editor | null = null;
  private lastSent = "";
  private dialog: LinkDialog | null = null;
  private undismiss: (() => void) | null = null;
  private menu: HTMLElement | null = null;
  private unmenu: (() => void) | null = null;
  private unwatchScroll: (() => void) | null = null;
  private candidates: Candidate[] = [];
  private assets = new AssetStore();
  private insertedAt = -1;
  private handled = new Set<string>();

  // **送るのは 1 つずつ。** 隠した input は 1 件しか持てないので、
  // 前の 1 枚が片付くまで次を渡さない。
  private queue: Array<{ token: string; file: File }> = [];
  private sending = false;

  static get observedAttributes() {
    return ["doc", "entries", "assets", "insert", "resolved"];
  }

  connectedCallback() {
    const bar = document.createElement("div");
    bar.className = "tt-bar";
    this.appendChild(bar);

    const mount = document.createElement("div");
    mount.className = "tt-mount";
    this.appendChild(mount);

    const extensions = [
      // codeBlock は色付きの物に差し替える。
      StarterKit.configure({ heading: { levels: [1, 2, 3, 4] }, codeBlock: false }),
      CodeBlockLowlight.extend({
        addNodeView: () => codeBlockView(lowlight),
        // CMS の codeBlock は language の他に fileName と highlightLines を受ける
        // （`RichText.checkCodeBlock`）。node の属性に無いと setNodeMarkup が黙って捨てる。
        addAttributes() {
          return {
            ...this.parent?.(),
            fileName: {
              default: null,
              parseHTML: (element: HTMLElement) => element.getAttribute("data-file-name"),
              renderHTML: (attributes: Record<string, unknown>) =>
                attributes.fileName ? { "data-file-name": String(attributes.fileName) } : {},
            },
            highlightLines: {
              default: null,
              parseHTML: (element: HTMLElement) => element.getAttribute("data-highlight-lines"),
              renderHTML: (attributes: Record<string, unknown>) =>
                attributes.highlightLines ? { "data-highlight-lines": String(attributes.highlightLines) } : {},
            },
          };
        },
      }).configure({
        lowlight,
        defaultLanguage: null,
      }),
      // **コンテンツへのリンクは `entryId`。** CMS は `link` の href に `entry:` を許さず、
      // 別の属性で受ける（そうすると被リンクの表 `entry_links` に載る）。
      Link.extend({
        addAttributes() {
          return {
            ...this.parent?.(),
            entryId: {
              default: null,
              parseHTML: (element: HTMLElement) => element.getAttribute("data-entry-id"),
              renderHTML: (attributes: Record<string, unknown>) =>
                attributes.entryId ? { "data-entry-id": String(attributes.entryId) } : {},
            },
          };
        },
      }).configure({ openOnClick: false }),
      imageNode(this.assets),
      galleryNode(this.assets),
      UploadingImage,
      imageDropExtension((files) => this.take(files)),
      TaskList,
      TaskItem.configure({ nested: true }),
      Underline,
      // WhyNot: resizable を on にしない。CMS の richText は tableCell の colwidth を
      // 持たず、HTML にも幅を出さない。画面でだけ動く幅は保存されず、消えたように見える。
      Table.configure({ resizable: false, renderWrapper: true }),
      TableRow,
      TableHeader,
      TableCell,
      CodeEditing,
      BlockEdges,
      MathMark,
      MathBlock,
      Passthrough,
    ];

    this.editor = new Editor({
      element: mount,
      extensions,
      content: this.docFromAttribute(extensions),
      editorProps: { attributes: { class: "tt-body" } },
      onUpdate: () => {
        this.emit();
        this.paint();
        this.paintGrips();
      },
      onSelectionUpdate: () => {
        this.paint();
        this.paintGrips();
      },
    });

    this.buildBar(bar);
    this.watchTableHover(mount);
    this.paint();
    this.syncAssets();
    this.applyInsert();
    this.applyResolved();

    // 開いた時点で入っているコードに色を付ける。読み終わってから塗り直す。
    void ensureUsed(lowlight, this.editor.getJSON()).then(() => this.repaintCode());
  }

  // ツールバーの中身。**群に分けて区切り線で束ねる**（Contentful と同じ並び）:
  // 種類のドロップダウン | 文字の飾り | リンク | かたまり | 元に戻す
  private tools(): Array<Tool> {
    const chain = () => this.editor!.chain().focus();
    const is = (name: string, attrs?: Record<string, unknown>) => () => this.editor!.isActive(name, attrs);
    return [
      { kind: "block" },
      { kind: "divider" },
      { kind: "button", label: "B", title: "太字", run: () => chain().toggleBold().run(), active: is("bold") },
      { kind: "button", label: "I", title: "斜体", run: () => chain().toggleItalic().run(), active: is("italic") },
      { kind: "button", icon: ICONS.underline, title: "下線", run: () => chain().toggleUnderline().run(), active: is("underline") },
      { kind: "button", label: "S", title: "打ち消し", run: () => chain().toggleStrike().run(), active: is("strike") },
      { kind: "button", icon: ICONS.code, title: "コード（文の中）", run: () => chain().toggleCode().run(), active: is("code") },
      { kind: "divider" },
      { kind: "button", icon: ICONS.link, title: "リンク", run: () => this.link(), active: is("link") },
      // 選ぶ面は Elm が持つ（メディアの一覧は API から来る）。押した事だけ外に出す。
      {
        kind: "button",
        icon: ICONS.image,
        title: "画像",
        run: () => this.dispatchEvent(new CustomEvent("mediapick")),
        active: is("image"),
      },
      { kind: "divider" },
      { kind: "button", icon: ICONS.bulletList, title: "箇条書き", run: () => chain().toggleBulletList().run(), active: is("bulletList") },
      { kind: "button", icon: ICONS.orderedList, title: "番号付き", run: () => chain().toggleOrderedList().run(), active: is("orderedList") },
      { kind: "button", icon: ICONS.taskList, title: "チェックリスト", run: () => chain().toggleTaskList().run(), active: is("taskList") },
      { kind: "button", icon: ICONS.quote, title: "引用", run: () => chain().toggleBlockquote().run(), active: is("blockquote") },
      { kind: "button", icon: ICONS.codeBlock, title: "コードブロック", run: () => chain().toggleCodeBlock().run(), active: is("codeBlock") },
      { kind: "button", icon: ICONS.rule, title: "区切り線", run: () => chain().setHorizontalRule().run() },
      { kind: "button", icon: ICONS.table, title: "表", run: () => this.tableMenu(), active: is("table") },
      { kind: "spacer" },
      {
        kind: "button",
        icon: ICONS.undo,
        title: "元に戻す（⌘Z）",
        run: () => chain().undo().run(),
        enabled: () => Boolean(this.editor?.can().undo()),
      },
      {
        kind: "button",
        icon: ICONS.redo,
        title: "やり直す（⇧⌘Z）",
        run: () => chain().redo().run(),
        enabled: () => Boolean(this.editor?.can().redo()),
      },
    ];
  }

  private buildBar(bar: HTMLElement) {
    for (const tool of this.tools()) {
      if (tool.kind === "divider") {
        const line = document.createElement("span");
        line.className = "tt-divider";
        bar.appendChild(line);
        continue;
      }
      if (tool.kind === "spacer") {
        const gap = document.createElement("span");
        gap.className = "tt-spacer";
        bar.appendChild(gap);
        continue;
      }
      if (tool.kind === "block") {
        bar.appendChild(this.buildBlockSelect());
        continue;
      }
      const button = document.createElement("button");
      button.type = "button";
      button.className = tool.icon ? "tt-tool tt-tool-icon" : "tt-tool";
      if (tool.icon) {
        button.innerHTML = svg(tool.icon);
      } else {
        button.textContent = tool.label ?? "";
      }
      button.title = tool.title ?? "";
      button.setAttribute("aria-label", tool.title ?? "");
      // mousedown で選択が外れないようにする。
      button.addEventListener("mousedown", (event) => event.preventDefault());
      button.addEventListener("click", () => tool.run?.());
      bar.appendChild(button);
    }
  }

  // 段落と見出しは**ドロップダウンで選ぶ**（ボタンを 5 つ並べるより、今どれかが一目で分かる）。
  private buildBlockSelect(): HTMLElement {
    const select = document.createElement("select");
    select.className = "tt-block";
    select.setAttribute("aria-label", "段落の種類");
    for (const [value, label] of BLOCKS) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      select.appendChild(option);
    }
    select.addEventListener("mousedown", (event) => event.stopPropagation());
    select.addEventListener("change", () => {
      const chain = this.editor!.chain().focus();
      if (select.value === "paragraph") chain.setParagraph().run();
      else chain.toggleHeading({ level: Number(select.value.slice(1)) as 1 | 2 | 3 | 4 }).run();
    });
    return select;
  }

  // 今の位置に合わせて、押されている物に印を付ける。ドロップダウンも今の種類に合わせる。
  private paint() {
    if (!this.editor) return;
    const buttons = this.querySelectorAll<HTMLButtonElement>(".tt-tool");
    const pressable = this.tools().filter((tool) => tool.kind === "button");
    pressable.forEach((tool, index) => {
      const button = buttons[index];
      if (!button) return;
      button.classList.toggle("is-on", Boolean(tool.active?.()));
      if (tool.enabled) button.disabled = !tool.enabled();
    });

    const select = this.querySelector<HTMLSelectElement>(".tt-block");
    if (select) {
      const level = [1, 2, 3, 4].find((n) => this.editor!.isActive("heading", { level: n }));
      select.value = level ? `h${level}` : "paragraph";
    }
  }

  // リンクを張る面。**URL とコンテンツを 1 つの面で切り替える。**
  private link() {
    if (!this.editor) return;
    if (this.dialog) {
      this.closeDialog();
      return;
    }
    const current = this.editor.isActive("link") ? this.editor.getAttributes("link") : null;
    const dialog = new LinkDialog({
      current,
      onSearch: (query) => this.dispatchEvent(new CustomEvent("linksearch", { detail: query })),
      onDone: (choice) => this.applyLink(choice),
    });
    this.dialog = dialog;
    this.appendChild(dialog.dom);
    this.placeDialog(dialog.dom);
    dialog.setCandidates(this.candidates);
    dialog.focusInput();
    // 開いたボタンも「面の中」に数える。外さないと、外のクリックで閉じた直後に
    // 同じクリックのボタン側の click が面を開き直す。
    const button = this.querySelector<HTMLElement>('.tt-tool[title="リンク"]');
    this.undismiss = dismissOn({ inside: button ? [dialog.dom, button] : [dialog.dom], onClose: () => this.closeDialog() });
  }

  // 表を作る面。**大きさを升目で選ぶ**（Word / Google ドキュメント / Notion の `/table` と同じ）。
  // WhyNot: 行と列の足し引きをここに並べない。触りたい行・列から遠く、面が表そのものを覆う。
  // 足し引きは表の上に出す掴み（tt-grip）が持つ。
  private tableMenu() {
    if (!this.editor) return;
    if (this.menu) {
      this.closeMenu();
      return;
    }
    const dom = document.createElement("div");
    dom.className = "tt-menu tt-size";

    const grid = document.createElement("div");
    grid.className = "tt-size-grid";
    const label = document.createElement("div");
    label.className = "tt-size-label";
    label.textContent = "大きさを選ぶ";
    const MAX = 8;
    const cells: HTMLElement[] = [];
    const mark = (rows: number, cols: number) => {
      cells.forEach((cell, index) => {
        const row = Math.floor(index / MAX) + 1;
        const col = (index % MAX) + 1;
        cell.classList.toggle("is-on", row <= rows && col <= cols);
      });
      label.textContent = rows > 0 ? `${rows} 行 × ${cols} 列` : "大きさを選ぶ";
    };
    for (let row = 1; row <= MAX; row += 1) {
      for (let col = 1; col <= MAX; col += 1) {
        const cell = document.createElement("span");
        cell.className = "tt-size-cell";
        cell.addEventListener("mousemove", () => mark(row, col));
        cell.addEventListener("mousedown", (event) => {
          event.preventDefault();
          this.editor!.chain().focus().insertTable({ rows: row, cols: col, withHeaderRow: true }).run();
          this.closeMenu();
        });
        cells.push(cell);
        grid.appendChild(cell);
      }
    }
    grid.addEventListener("mouseleave", () => mark(0, 0));
    dom.append(label, grid);

    // 表そのものへの操作（行・列ではないので掴みには置けない）。
    if (this.editor.isActive("table")) {
      for (const [text, run] of [
        ["見出しの行を切り替える", () => this.editor!.chain().focus().toggleHeaderRow().run()],
        ["表を消す", () => this.editor!.chain().focus().deleteTable().run()],
      ] as Array<[string, () => void]>) {
        dom.appendChild(this.menuItem(text, run));
      }
    }

    this.menu = dom;
    this.appendChild(dom);
    this.placeUnder(dom, '.tt-tool[title="表"]', 220);
    const button = this.querySelector<HTMLElement>('.tt-tool[title="表"]');
    this.unmenu = dismissOn({ inside: button ? [dom, button] : [dom], onClose: () => this.closeMenu() });
  }

  private menuItem(text: string, run: () => void): HTMLElement {
    const item = document.createElement("button");
    item.type = "button";
    item.className = "tt-menu-item";
    item.textContent = text;
    item.addEventListener("mousedown", (event) => {
      event.preventDefault();
      run();
      this.closeMenu();
    });
    return item;
  }

  private closeMenu() {
    this.unmenu?.();
    this.unmenu = null;
    this.menu?.remove();
    this.menu = null;
    this.editor?.commands.focus();
    this.paintGrips();
  }

  // 掴み。**セルにカーソルがある時か、表にマウスが乗っている時だけ**、列の上端と行の左端に出る。
  //
  // 見えているのは 4px の細い線で、当たり判定だけ 10px 取る（Notion / Google ドキュメントの実物が
  // どちらもそう。塗った太い棒にすると、表の中身より枠が目立つ）。
  //
  // WhyNot: 掴みを ProseMirror の DOM の中に入れない。表の node view は書き換えの度に
  // 中を作り直すので、入れた物が消えるか、PM が「知らない変更」として拾う。
  private paintGrips(hovered?: HTMLTableElement | null) {
    if (!this.editor) return;
    const mount = this.querySelector<HTMLElement>(".tt-mount");
    if (!mount) return;
    let layer = this.querySelector<HTMLElement>(".tt-grips");
    const table = hovered ?? this.currentTable();
    if (!table) {
      layer?.remove();
      this.unwatchScroll?.();
      this.unwatchScroll = null;
      return;
    }
    if (!layer) {
      layer = document.createElement("div");
      layer.className = "tt-grips";
      mount.appendChild(layer);
    }
    const rows = Array.from(table.rows);
    const head = rows[0];
    if (!head) return;
    const base = mount.getBoundingClientRect();
    const wrap = (table.closest(".tableWrapper") as HTMLElement | null) ?? table;
    const clip = wrap.getBoundingClientRect();
    // 罫線 1 本ぶん短くして、隣の掴みとの切れ目が列・行の境目に重なるようにする。
    const inset = 1;

    const made: HTMLElement[] = [];
    Array.from(head.cells).forEach((cell, index) => {
      const at = cell.getBoundingClientRect();
      const left = Math.max(at.left, clip.left);
      const right = Math.min(at.right, clip.right);
      if (right - left < 6) return;
      made.push(this.grip("col", index, {
        left: left - base.left + inset,
        top: at.top - base.top - 10,
        width: right - left - inset * 2,
        height: 10,
      }));
    });
    rows.forEach((row, index) => {
      const at = row.getBoundingClientRect();
      made.push(this.grip("row", index, {
        left: clip.left - base.left - 10,
        top: at.top - base.top + inset,
        width: 10,
        height: at.height - inset * 2,
      }));
    });
    layer.replaceChildren(...made);

    // 横に長い表はスクロールするので、掴みも付いて動く。
    this.unwatchScroll?.();
    const again = () => this.paintGrips(hovered);
    wrap.addEventListener("scroll", again);
    this.unwatchScroll = () => wrap.removeEventListener("scroll", again);
  }

  // 表にマウスが乗った時にも掴みを出す。
  private watchTableHover(mount: HTMLElement) {
    mount.addEventListener("mouseover", (event) => {
      const table = (event.target as Element | null)?.closest?.("table") as HTMLTableElement | null;
      if (table) this.paintGrips(table);
    });
    mount.addEventListener("mouseout", (event) => {
      const to = (event as MouseEvent).relatedTarget as Element | null;
      if (to?.closest?.("table") || to?.closest?.(".tt-grips")) return;
      if (this.menu) return;
      this.paintGrips();
    });
  }

  // カーソルが入っている表の DOM。
  private currentTable(): HTMLTableElement | null {
    if (!this.editor || !this.editor.isActive("table")) return null;
    const at = this.editor.view.domAtPos(this.editor.state.selection.from);
    const node = at.node instanceof Element ? at.node : at.node.parentElement;
    return (node?.closest("table") as HTMLTableElement | null) ?? null;
  }

  private grip(kind: "col" | "row", index: number, box: { left: number; top: number; width: number; height: number }): HTMLElement {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `tt-grip tt-grip-${kind}`;
    button.title = kind === "col" ? `${index + 1} 列目` : `${index + 1} 行目`;
    button.setAttribute("aria-label", button.title);
    button.style.left = `${Math.round(box.left)}px`;
    button.style.top = `${Math.round(box.top)}px`;
    button.style.width = `${Math.round(box.width)}px`;
    button.style.height = `${Math.round(box.height)}px`;
    button.addEventListener("mousedown", (event) => {
      event.preventDefault();
      this.gripMenu(kind, index, button);
    });
    return button;
  }

  // 掴みを押した時。**その行・列に対する操作だけ**を出す。
  private gripMenu(kind: "col" | "row", index: number, at: HTMLElement) {
    if (!this.editor) return;
    this.closeMenu();
    if (!this.moveInto(kind, index)) return;
    const chain = () => this.editor!.chain().focus();
    const items: Array<[string, () => void]> =
      kind === "col"
        ? [
            ["左に列を足す", () => chain().addColumnBefore().run()],
            ["右に列を足す", () => chain().addColumnAfter().run()],
            ["この列を消す", () => chain().deleteColumn().run()],
          ]
        : [
            ["上に行を足す", () => chain().addRowBefore().run()],
            ["下に行を足す", () => chain().addRowAfter().run()],
            ["この行を消す", () => chain().deleteRow().run()],
          ];
    const dom = document.createElement("div");
    dom.className = "tt-menu";
    for (const [text, run] of items) dom.appendChild(this.menuItem(text, run));
    this.menu = dom;
    this.appendChild(dom);
    at.classList.add("is-open");
    this.shade(kind, index);
    const box = at.getBoundingClientRect();
    dom.style.position = "fixed";
    dom.style.top = `${Math.round(Math.min(box.bottom + 4, window.innerHeight - 130))}px`;
    dom.style.left = `${Math.round(Math.min(box.left, window.innerWidth - 190))}px`;
    this.unmenu = dismissOn({ inside: [dom, at], onClose: () => this.closeMenu() });
  }

  // 押した行・列に薄い網掛けを敷く。**どこに効くのかを押した時点で見せる。**
  private shade(kind: "col" | "row", index: number) {
    const layer = this.querySelector<HTMLElement>(".tt-grips");
    const table = this.currentTable();
    const mount = this.querySelector<HTMLElement>(".tt-mount");
    if (!layer || !table || !mount) return;
    const rows = Array.from(table.rows);
    const boxes =
      kind === "row"
        ? [rows[index]?.getBoundingClientRect()]
        : rows.map((row) => row.cells[index]?.getBoundingClientRect());
    const base = mount.getBoundingClientRect();
    for (const box of boxes) {
      if (!box) continue;
      const shade = document.createElement("span");
      shade.className = "tt-grip-shade";
      shade.style.left = `${Math.round(box.left - base.left)}px`;
      shade.style.top = `${Math.round(box.top - base.top)}px`;
      shade.style.width = `${Math.round(box.width)}px`;
      shade.style.height = `${Math.round(box.height)}px`;
      layer.appendChild(shade);
    }
  }

  // 操作の前に、その行・列のセルへカーソルを移す（コマンドは今のセルを見る）。
  private moveInto(kind: "col" | "row", index: number): boolean {
    const table = this.currentTable();
    if (!table || !this.editor) return false;
    const row = kind === "row" ? table.rows[index] : table.rows[0];
    const cell = kind === "row" ? row?.cells[0] : row?.cells[index];
    if (!cell) return false;
    const pos = this.editor.view.posAtDOM(cell, 0);
    if (pos < 0) return false;
    this.editor.commands.setTextSelection(pos + 1);
    return true;
  }

  // 選んだリンクを本文に入れる。
  //
  // **選択が空なら、選んだ物の名前を文字として入れてからリンクにする。**
  // WhyNot: 「先に文字を選んでから押す」を強いない。setMark は範囲が無いと何もしないので、
  // 押しても何も起きない画面になる（Notion / Craft / Zenn / Google ドキュメントは
  // どれも選んだ物の題を入れる）。
  //
  // WhyNot: entry へのリンクに setLink を使わない。setLink は href を URL として検査し、
  // href の無い（entryId だけの）リンクを弾く。
  private applyLink(choice: LinkChoice) {
    if (!this.editor) return;
    const chain = this.editor.chain().focus();
    if (choice === null) {
      chain.extendMarkRange("link").unsetLink().run();
      this.closeDialog();
      return;
    }
    const attrs = "href" in choice ? { href: choice.href, entryId: null } : { href: null, entryId: choice.entryId };
    const bare = this.editor.state.selection.empty && !this.editor.isActive("link");
    if (bare) chain.insertContent({ type: "text", text: choice.label, marks: [{ type: "link", attrs }] }).run();
    else chain.extendMarkRange("link").setMark("link", attrs).run();
    this.closeDialog();
  }

  // 押したボタンの下に付ける。
  //
  // **押した所から離れた場所に出さない。** 面の中身（コンテンツの候補）は打つ度に変わるので、
  // 目がボタンと面を往復する。ツールバーは本文の上にも下にも来る（本文が長いと下）ため、
  // 位置は開く時に測る。
  //
  // WhyNot: エディタの箱を基準にした `absolute` にしない。箱は本文の長さで伸びるので、
  // ボタンが箱の下端にあっても面は箱の上端に出る（実際に画面の右上に出ていた）。
  private placeDialog(dom: HTMLElement) {
    this.placeUnder(dom, '.tt-tool[title="リンク"]', 300);
  }

  private placeUnder(dom: HTMLElement, selector: string, width: number) {
    const button = this.querySelector<HTMLButtonElement>(selector);
    if (!button) return;
    const at = button.getBoundingClientRect();
    const gap = 6;

    // 下に入らなければ上へ返す。左右は画面の中に収める。
    const below = at.bottom + gap;
    const height = dom.offsetHeight || 260;
    const top = below + height > window.innerHeight - 8 ? Math.max(8, at.top - gap - height) : below;
    const left = Math.min(Math.max(8, at.left), window.innerWidth - width - 8);

    dom.style.position = "fixed";
    dom.style.top = `${Math.round(top)}px`;
    dom.style.left = `${Math.round(left)}px`;
    dom.style.right = "auto";
  }

  private closeDialog() {
    this.undismiss?.();
    this.undismiss = null;
    this.dialog?.dom.remove();
    this.dialog = null;
    this.editor?.commands.focus();
  }

  disconnectedCallback() {
    this.editor?.destroy();
    this.editor = null;
  }

  attributeChangedCallback(name: string) {
    if (name === "entries") {
      try {
        this.candidates = JSON.parse(this.getAttribute("entries") ?? "[]");
      } catch {
        this.candidates = [];
      }
      this.dialog?.setCandidates(this.candidates);
      return;
    }
    if (name === "assets") {
      this.syncAssets();
      return;
    }
    // **doc を変える物は 1 拍おく。** 属性が変わるのは Elm が DOM を書いている
    // 最中で、その場で doc を変えると `docchange` が Elm の描き直しの中に飛び込み、
    // 入れた物が Elm 側に残らない（実際に、画面には出るのに保存されなかった）。
    if (name === "insert") {
      window.setTimeout(() => this.applyInsert(), 0);
      return;
    }
    if (name === "resolved") {
      window.setTimeout(() => this.applyResolved(), 0);
      return;
    }
    // 外から新しい doc が来た時だけ入れ直す。
    //
    // **今の中身と同じなら何もしない。** 読み込みの後に別の応答（被リンク・履歴・
    // メディア）が返ると Elm が描き直し、同じ内容でも文字の並びが変わった doc が
    // 来る事がある。入れ直すと選択が消え、押してもカーソルが出ない
    // （打つと戻るので気づきにくい。実際にそうなった）。
    if (name !== "doc" || !this.editor) return;
    const incoming = this.getAttribute("doc") ?? "";
    if (incoming === this.lastSent) return;
    if (incoming === JSON.stringify(unfold(this.editor.getJSON()))) return;
    this.editor.commands.setContent(this.docFromAttribute(this.editor.extensionManager.extensions), false);
  }

  private parsed(name: string): unknown {
    try {
      return JSON.parse(this.getAttribute(name) ?? "null");
    } catch {
      return null;
    }
  }

  // id → URL の対応。**エディタは URL を作れない**（asset の置き先は CMS が決める）。
  private syncAssets() {
    const list = this.parsed("assets");
    this.assets.set(Array.isArray(list) ? list : []);
  }

  // Elm が選んだメディアを本文に入れる。`seq` で 1 回だけ入れる
  // （属性は同じ値のまま描き直される事がある）。
  private applyInsert() {
    const order = this.parsed("insert") as { seq?: number; assetIds?: string[] } | null;
    if (!this.editor || !order || typeof order.seq !== "number") return;
    if (order.seq <= this.insertedAt) return;
    this.insertedAt = order.seq;
    const content = insertionOf(Array.isArray(order.assetIds) ? order.assetIds : []);
    if (!content) return;
    this.editor.chain().focus().insertContent(content).run();
  }

  // 上がり終わった物を、仮の見た目と差し替える。`assetId` が空なら失敗なので取り除く。
  private applyResolved() {
    const list = this.parsed("resolved") as Array<{ token?: string; assetId?: string }> | null;
    if (!this.editor || !Array.isArray(list)) return;
    for (const done of list) {
      if (!done?.token || this.handled.has(done.token)) continue;
      this.handled.add(done.token);
      this.replaceUploading(done.token, done.assetId ?? "");
      this.sending = false;
    }
    this.pump();
  }

  private replaceUploading(token: string, assetId: string) {
    const view = this.editor!.view;
    let at = -1;
    let size = 0;
    view.state.doc.descendants((node, pos) => {
      if (node.type.name === "uploading" && node.attrs.token === token) {
        at = pos;
        size = node.nodeSize;
      }
    });
    if (at < 0) return;
    const tr = view.state.tr;
    if (assetId) tr.replaceWith(at, at + size, view.state.schema.nodes.image.create({ assetId }));
    else tr.delete(at, at + size);
    view.dispatch(tr);
  }

  // 貼られた・落とされた画像。**その場に仮の見た目を出してから**外に渡す。
  private take(files: File[]) {
    if (!this.editor) return;
    for (const file of files) {
      const token = "up-" + Math.random().toString(36).slice(2);
      this.editor.chain().focus().insertContent({ type: "uploading", attrs: { token, name: file.name } }).run();
      this.queue.push({ token, file });
    }
    this.pump();
  }

  // **ファイルの中身は Elm に渡さない**（port は File を通せない）。
  // `DataTransfer` で隠した input に移し、既にある `uploadAsset_Media_JS` の道に乗せる。
  //
  // WhyNot: File を運ぶ port を新しく足さない。足すと署名付き URL に PUT する所が
  // メディアの画面と本文の画像で 2 本になり、進み具合の扱いも 2 通りになる。
  private pump() {
    if (this.sending) return;
    const next = this.queue.shift();
    if (!next) return;
    const input = document.getElementById(this.getAttribute("uploadinput") ?? "") as HTMLInputElement | null;
    if (!input) {
      this.replaceUploading(next.token, "");
      return;
    }
    const box = new DataTransfer();
    box.items.add(next.file);
    input.files = box.files;
    this.sending = true;
    this.dispatchEvent(
      new CustomEvent("mediaupload", {
        detail: { token: next.token, fileName: next.file.name, mime: next.file.type, size: next.file.size },
      }),
    );
  }

  private knownNames(extensions: any[]): Set<string> {
    const names = new Set<string>(["text", "doc"]);
    for (const extension of extensions) {
      if (extension?.name) names.add(extension.name);
    }
    // StarterKit がまとめて入れる node は名前で並べる。
    for (const name of [
      "paragraph",
      "heading",
      "bulletList",
      "orderedList",
      "listItem",
      "blockquote",
      "codeBlock",
      "horizontalRule",
      "hardBreak",
      "image",
      "gallery",
      "uploading",
      "taskList",
      "taskItem",
    ]) {
      names.add(name);
    }
    return names;
  }

  private docFromAttribute(extensions: any[]) {
    const raw = this.getAttribute("doc");
    if (!raw) return EMPTY_DOC;
    try {
      const parsed = JSON.parse(raw);
      if (!parsed || parsed.type !== "doc") return EMPTY_DOC;
      return foldUnknown(parsed, this.knownNames(extensions));
    } catch {
      return EMPTY_DOC;
    }
  }

  // 文法を後から読んだ時に色を塗り直す。**doc は変えない**
  // （同じ属性で置き直すだけ。`emit` が中身を見て同じなら送らないので、未保存にならない）。
  private repaintCode() {
    if (!this.editor) return;
    const view = this.editor.view;
    const tr = view.state.tr;
    let touched = false;
    view.state.doc.descendants((node, pos) => {
      if (node.type.name !== "codeBlock") return;
      tr.setNodeMarkup(pos, undefined, { ...node.attrs });
      touched = true;
    });
    if (touched) view.dispatch(tr.setMeta("addToHistory", false));
  }

  private emit() {
    if (!this.editor) return;
    // **疑似行がある間は出さない。** 打たずに離れれば消える行なので、
    // 出すと触っていないのに「未保存」になる。
    if (hasPendingLine(this.editor.state)) return;
    const doc = unfold(this.editor.getJSON());
    const text = JSON.stringify(doc);
    if (text === this.lastSent) return;
    this.lastSent = text;
    this.dispatchEvent(new CustomEvent("docchange", { detail: text }));
  }
}

if (!customElements.get("tiptap-editor")) {
  customElements.define("tiptap-editor", TiptapEditor);
}
