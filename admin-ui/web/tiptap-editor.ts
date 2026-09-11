// リッチエディタを custom element に包む。
//
// Elm からは `doc` 属性（doc の JSON の文字列）を渡し、変わったら `docchange` の
// CustomEvent で返す。Elm は TipTap の存在を知らない。
//
// doc の形は CMS の RichText が正。**知らない node は消さずに素通しする**
// （画面が対応していない node を含む記事を開いて保存しても壊さない）。

import { Editor, posToDOMRect } from "@tiptap/core";
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
import { MarkdownRules } from "./markdown-rules";
// 本文が指しているコンテンツ（`linked` の属性で Elm から来る）。**乗せた時の吹き出し**に出す。
// 公開の状態の語は Elm の `Ui.Stage` が作った物をそのまま受ける（TS 側で言い換えない）。
type Linked = {
  id: string;
  title: string;
  type: string;
  // 型に人が選んだアイコン。`<svg>` の中身の markup で、Elm の `Ui.Icon` の表から来る。
  icon?: string;
  stageName?: string;
  path?: string | null;
};

// Elm が返す「決まった物」。`seq` は `linkopen` で投げた番号。
type LinkChoice = { seq: number; href: string; entryId: string; label: string; remove: boolean; cancel: boolean };
import { dismissOn } from "./dismiss";
import { placeUnder } from "./place";
import { isDraggingTable, tableHandles } from "./table-drag";
import { Highlight, RaisedCaret, Subscript, Superscript } from "./text-marks";
import { type Align, alignColumn, columnAlign, resizeTable, tableSize } from "./table-tools";
import { MathBlock, MathMark } from "./math";
import { AssetStore, galleryNode, imageDropExtension, imageNode, insertionOf, insideImage, liftCaption, trimCaption, UploadingImage } from "./image-node";
import { QuoteNode } from "./quote-node";
import { ICONS, svg } from "./icons";
import { CardStore, linkCardNode } from "./link-card-node";
import { EmbedNode } from "./embed-node";
import { UrlPaste } from "./url-cards";
import { BlockMenu } from "./block-menu";
import BubbleMenu from "@tiptap/extension-bubble-menu";
import { NodeSelection } from "@tiptap/pm/state";
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

// 空でも段落を 1 つ持たせる。
//
// **中身が 0 個だと、打つ場所そのものが無い。** 押しても入る所が無いので、新規作成を開いた
// 直後にツールバーの引用・コードブロック・表・箇条書きを押しても何も起きなかった
// （文字を打つと段落ができて、そこから先は効く）。
const EMPTY_DOC = { type: "doc", content: [{ type: "paragraph" }] };

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

//
// 表のセルの中を段落だけにする。上付きと下付きは重ねない。
//
// **入れ子は schema では止まらない。** ProseMirror は JSON を読む時に content の形を
// 見ないので、外から来た「セルの中の表」も「上付き＋下付き」もそのまま読み込まれ、
// 画面には出るのに保存では断られる。読む時に平らにして、見えている物と保存できる物を
// 揃える。文字は残し、構造だけ落とす。
//
function flatten(node: any): any {
  if (!node || typeof node !== "object") return node;
  if (node.type === "text") return dropRaised(node);
  if (!Array.isArray(node.content)) return node;
  const content = node.content.map(flatten);
  if (node.type !== "tableCell" && node.type !== "tableHeader") return { ...node, content };
  const lines = content.flatMap((child: any) => {
    if (child?.type === "paragraph") return [child];
    const text = textOf(child);
    return text ? [{ type: "paragraph", content: [{ type: "text", text }] }] : [];
  });
  return { ...node, content: lines.length > 0 ? lines : [{ type: "paragraph" }] };
}

function textOf(node: any): string {
  if (!node || typeof node !== "object") return "";
  if (typeof node.text === "string") return node.text;
  if (!Array.isArray(node.content)) return "";
  return node.content.map(textOf).join(" ").trim();
}

// 上付きと下付きが両方付いていたら、先に書いてある方だけ残す。
function dropRaised(node: any): any {
  const marks = node.marks;
  if (!Array.isArray(marks)) return node;
  const raised = marks.filter((mark: any) => mark?.type === "sub" || mark?.type === "sup");
  if (raised.length < 2) return node;
  const keep = raised[0].type;
  return { ...node, marks: marks.filter((mark: any) => mark?.type === keep || (mark?.type !== "sub" && mark?.type !== "sup")) };
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
  return dropEmptyAttrs(trimCaption(next));
}

// セルの寄せ。**CMS は attrs.align、画面は style の text-align。**
// 属性に持たせないと setNodeMarkup が黙って捨てる（codeBlock の fileName と同じ）。
function alignAttribute() {
  return {
    align: {
      default: null,
      parseHTML: (element: HTMLElement) => element.style.textAlign || element.getAttribute("data-align") || null,
      renderHTML: (attributes: Record<string, unknown>) =>
        attributes.align ? { style: `text-align: ${attributes.align}` } : {},
    },
  };
}

// チェックリストの形を、CMS と TipTap の間で写す。
//
// **CMS は `bulletList > listItem(attrs.checked)`、TipTap は `taskList > taskItem`。**
// 写さないと、ツールバーのチェックリストも `- [ ] ` も「知らないノード 'taskList' です」で
// 断られ、書いた物が保存できない（実際に断られた）。
//
// **項目のどれか 1 つでも checked を持っていたら、そのリストごとチェックリストにする。**
// TipTap にも CMS にも「一部だけチェックの付いた箇条書き」は無い。
function toTaskList(node: any): any {
  if (!node || typeof node !== "object") return node;
  const next = Array.isArray(node.content) ? { ...node, content: node.content.map(toTaskList) } : { ...node };
  if (next.type !== "bulletList" || !Array.isArray(next.content)) return next;
  if (!next.content.some((item: any) => typeof item?.attrs?.checked === "boolean")) return next;
  return {
    ...next,
    type: "taskList",
    content: next.content.map((item: any) => ({
      ...item,
      type: "taskItem",
      attrs: { ...(item?.attrs ?? {}), checked: item?.attrs?.checked === true },
    })),
  };
}

function fromTaskList(node: any): any {
  if (!node || typeof node !== "object") return node;
  const next = Array.isArray(node.content) ? { ...node, content: node.content.map(fromTaskList) } : { ...node };
  if (next.type !== "taskList" || !Array.isArray(next.content)) return next;
  return {
    ...next,
    type: "bulletList",
    content: next.content.map((item: any) => ({
      ...item,
      type: "listItem",
      attrs: { ...(item?.attrs ?? {}), checked: item?.attrs?.checked === true },
    })),
  };
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
  // リンクの面は Elm が描く。TS は「開きたい」を投げた番号と、実行した番号だけ持つ。
  private linkSeq = 0;
  private linkDoneAt = -1;
  private menu: HTMLElement | null = null;
  private unmenu: (() => void) | null = null;
  private unwatchScroll: (() => void) | null = null;
  // 本文が指しているコンテンツ。**面とツールチップで「今どこを指しているか」を出す。**
  // 候補（探した結果）とは別で、id から引く。
  private linked = new Map<string, Linked>();
  private asked = "";
  private tip: HTMLElement | null = null;
  private assets = new AssetStore();
  // 外部リンクのカードの OGP。**エディタは API を知らない**（`linkresolve` と同じ決まり）。
  // 開いた時に doc に居る URL は `linkcardlookup`（表から引く）、貼った瞬間の 1 つは
  // `linkcardfetch`（その場で取る）で外に出し、答えは `cards` の属性で受ける。
  private cards = new CardStore((urls, mode) => {
    if (mode === "lookup") this.dispatchEvent(new CustomEvent("linkcardlookup", { detail: urls }));
    else for (const url of urls) this.dispatchEvent(new CustomEvent("linkcardfetch", { detail: url }));
  });
  private insertedAt = -1;
  private handled = new Set<string>();
  private blocks: BlockMenu | null = null;
  private bubble: HTMLElement | null = null;
  // キャプションの帯の中身。3 つの道具か、リンクの URL の入力（入れ替わる）。
  private captionTools: HTMLElement | null = null;
  private captionLink: HTMLElement | null = null;
  private captionLinkOpen = false;
  // キャプションのリンクの掛かった文字を選んだ時、選択の下に出す URL の面。
  private captionUrl: HTMLElement | null = null;

  // **送るのは 1 つずつ。** 隠した input は 1 件しか持てないので、
  // 前の 1 枚が片付くまで次を渡さない。
  private queue: Array<{ token: string; file: File }> = [];
  private sending = false;

  static get observedAttributes() {
    return ["doc", "assets", "insert", "resolved", "linked", "cards"];
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
      // gapcursor は切る。**置ける所と置けない所ができ、見た目も横一本の線で
      // 区切り線と紛れる。** ブロックの間は `BlockEdges` が疑似行で揃える。
      StarterKit.configure({ heading: { levels: [1, 2, 3, 4] }, codeBlock: false, gapcursor: false, blockquote: false }),
      // blockquote は出典（cite / citeUrl）を持つ物に差し替える（`web/quote-node.ts`）。
      QuoteNode,
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
      Subscript,
      Superscript,
      Highlight,
      RaisedCaret,
      // WhyNot: resizable を on にしない。CMS の richText は tableCell の colwidth を
      // 持たず、HTML にも幅を出さない。画面でだけ動く幅は保存されず、消えたように見える。
      Table.configure({ resizable: false, renderWrapper: true }),
      TableRow,
      // **セルの中は段落だけ。** 既定の `block+` だと表の中に表・引用・コードブロック・
      // 箇条書きが入るが、Markdown の表のセルは inline しか持てないので、書き出すと
      // 黙って消える（`Markdown.renderCell` が段落と見出しの中身しか拾わない）。
      TableHeader.extend({ content: "paragraph+", addAttributes() { return { ...this.parent?.(), ...alignAttribute() }; } }),
      TableCell.extend({ content: "paragraph+", addAttributes() { return { ...this.parent?.(), ...alignAttribute() }; } }),
      CodeEditing,
      BlockEdges,
      MarkdownRules,
      MathMark,
      MathBlock,
      // linkCard / embed は自前の node（`web/link-card-node.ts` / `web/embed-node.ts`）。
      // 灰色枠（Passthrough）は他の知らない node のためだけに残す。
      linkCardNode(this.cards),
      EmbedNode,
      UrlPaste,
      // 文字を選んだ時に選択の下に浮く帯。note の本文の帯と同じ 7 つ（`bubbleTools`）。
      // 画像のキャプションの中ではカーソルがある間ずっと、キャプションの真上に 3 つ（太字 / 打ち消し / リンク）。
      // 表のセルとコードブロックの中では出さない（既に帯と言語の面がある）。
      BubbleMenu.configure({
        element: this.buildBubble(),
        updateDelay: 80,
        tippyOptions: {
          placement: "bottom",
          duration: 80,
          offset: [0, 6],
          // WhyNot: キャプションでは placement を top にしない。placement は configure で固定なので、
          // 基準の矩形をキャプションの上に持ち上げて、bottom のまま「キャプションの真上」に置く。
          getReferenceClientRect: () => {
            const view = this.editor!.view;
            const { from, to } = this.editor!.state.selection;
            if (!insideImage(this.editor!.state)) return posToDOMRect(view, from, to);
            // 文字の端では domAtPos が figcaption そのものを返す（text node ではない）。
            const at = view.domAtPos(from).node as globalThis.Node;
            const figcaption = (at.nodeType === 3 ? at.parentElement : (at as Element))?.closest("figcaption");
            if (!figcaption) return posToDOMRect(view, from, to);
            const cap = figcaption.getBoundingClientRect();
            const height = this.bubble?.offsetHeight ?? 52;
            const top = cap.top - 12 - height;
            return new DOMRect(cap.left, top, cap.width, 0);
          },
        },
        shouldShow: ({ state, from, to }) => {
          if (state.selection instanceof NodeSelection) return false;
          if (insideImage(state)) return true;
          if (from === to) return false;
          // 選択の端のどちらかが表かコードブロックの中なら出さない（セルから外へ伸びた選択も含む）。
          const inBlocked = ($pos: { depth: number; node: (depth: number) => { type: { name: string } } }) => {
            for (let depth = $pos.depth; depth > 0; depth -= 1) {
              const name = $pos.node(depth).type.name;
              if (name === "table" || name === "codeBlock") return true;
            }
            return false;
          };
          if (inBlocked(state.selection.$from) || inBlocked(state.selection.$to)) return false;
          return state.doc.textBetween(from, to).trim().length > 0;
        },
      }),
      Passthrough,
    ];

    // カードの node view は作られた時に OGP を頼む。開いた時の分は表から引く物なので、まとめる。
    this.cards.batch(() => this.buildEditor(mount, extensions));

    this.blocks = new BlockMenu({
      editor: this.editor!,
      host: this,
      mount,
      onImage: () => this.dispatchEvent(new CustomEvent("mediapick")),
    });
    this.buildBar(bar);
    this.watchTableHover(mount);
    this.watchLinkHover(mount);
    this.paint();
    this.syncAssets();
    this.syncCards();
    this.applyInsert();
    this.askLinked();
    this.applyResolved();

    // 開いた時点で入っているコードに色を付ける。読み終わってから塗り直す。
    void ensureUsed(lowlight, this.editor!.getJSON()).then(() => this.repaintCode());
  }

  private buildEditor(mount: HTMLElement, extensions: any[]) {
    this.editor = new Editor({
      element: mount,
      extensions,
      content: this.docFromAttribute(extensions),
      editorProps: {
        attributes: { class: "tt-body" },
        // 「+」の一覧（`web/block-menu.ts`）。開いている間は上下と Enter を先に取り、`/` で開く。
        handleKeyDown: (_view, event) => {
          if (this.blocks?.onKey(event)) return true;
          if (event.key === "/") return this.blocks?.onSlash() ?? false;
          return false;
        },
        // 画像のキャプションの中では入力規則を効かせない。
        // WhyNot: schema に任せない。「# 」の見出しや「> 」の引用は画像の node ごと置き換えたり包んだりして、
        // キャプションを打っていたつもりの画像が消える（doc は見出しを受けるので schema では止まらない）。
        handleTextInput: (view, from, to, text) => {
          if (!insideImage(view.state)) return false;
          view.dispatch(view.state.tr.insertText(text, from, to));
          return true;
        },
      },
      onUpdate: () => {
        this.emit();
        this.askLinked();
      },
      onFocus: () => this.blocks?.update(),
      onBlur: () => {
        this.blocks?.update();
        this.paint();
      },

      // **道具の押した状態は、どの変化でも塗り直す。**
      // 文字を選ばずに太字を押した時は、本文も選択も動かず「次に打つ文字の印」だけが変わる。
      // onUpdate と onSelectionUpdate ではどちらも起きないので、押しても見た目が変わらなかった。
      onTransaction: () => {
        this.paint();
        this.paintTableTools();
        this.blocks?.update();
      },
    });
  }

  // ツールバーの中身。**群に分けて区切り線で束ねる**（Contentful と同じ並び）:
  // 種類のドロップダウン | 文字の飾り | リンク | かたまり | 元に戻す
  private tools(): Array<Tool> {
    const chain = () => this.editor!.chain().focus();
    const is = (name: string, attrs?: Record<string, unknown>) => () => this.editor!.isActive(name, attrs);
    // 画像のキャプションの中では、かたまりを変える物は押せない（キャプションは 1 行の文字だけ）。
    const outsideImage = () => !insideImage(this.editor!.state);
    return [
      { kind: "block" },
      { kind: "divider" },
      { kind: "button", label: "B", title: "太字", run: () => chain().toggleBold().run(), active: is("bold") },
      { kind: "button", label: "I", title: "斜体", run: () => chain().toggleItalic().run(), active: is("italic") },
      { kind: "button", icon: ICONS.underline, title: "下線", run: () => chain().toggleUnderline().run(), active: is("underline") },
      { kind: "button", label: "S", title: "打ち消し", run: () => chain().toggleStrike().run(), active: is("strike") },
      { kind: "button", icon: ICONS.highlight, title: "蛍光ペン", run: () => chain().toggleMark("highlight").run(), active: is("highlight") },
      { kind: "button", icon: ICONS.sup, title: "上付き", run: () => chain().toggleMark("sup").run(), active: is("sup") },
      { kind: "button", icon: ICONS.sub, title: "下付き", run: () => chain().toggleMark("sub").run(), active: is("sub") },
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
        enabled: outsideImage,
      },
      { kind: "divider" },
      { kind: "button", icon: ICONS.bulletList, title: "箇条書き", run: () => chain().toggleBulletList().run(), active: is("bulletList"), enabled: outsideImage },
      { kind: "button", icon: ICONS.orderedList, title: "番号付き", run: () => chain().toggleOrderedList().run(), active: is("orderedList"), enabled: outsideImage },
      { kind: "button", icon: ICONS.taskList, title: "チェックリスト", run: () => chain().toggleTaskList().run(), active: is("taskList"), enabled: outsideImage },
      { kind: "button", icon: ICONS.quote, title: "引用", run: () => chain().toggleBlockquote().run(), active: is("blockquote"), enabled: outsideImage },
      { kind: "button", icon: ICONS.codeBlock, title: "コードブロック", run: () => chain().toggleCodeBlock().run(), active: is("codeBlock"), enabled: outsideImage },
      { kind: "button", icon: ICONS.rule, title: "区切り線", run: () => chain().setHorizontalRule().run(), enabled: outsideImage },
      { kind: "button", icon: ICONS.table, title: "表", run: () => this.tableMenu(), active: is("table"), enabled: outsideImage },
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

  // 選択の下に浮く帯の中身。note の本文の帯と同じ順。押した状態は `paint` が aria-pressed で塗る。
  //
  // **見出しの 2 つは段落ごとに効く**（部分文字列には掛からない）。title の文言でそれを伝える。
  private bubbleTools(): Array<{ label?: string; icon?: string; title: string; extra?: string; run: () => void; active: () => boolean }> {
    const chain = () => this.editor!.chain().focus();
    return [
      { label: "T", extra: "tt-bubble-h2", title: "段落を H2 に", run: () => chain().toggleHeading({ level: 2 }).run(), active: () => this.editor!.isActive("heading", { level: 2 }) },
      { label: "T", extra: "tt-bubble-h3", title: "段落を H3 に", run: () => chain().toggleHeading({ level: 3 }).run(), active: () => this.editor!.isActive("heading", { level: 3 }) },
      { label: "B", title: "太字", run: () => chain().toggleBold().run(), active: () => this.editor!.isActive("bold") },
      { label: "S", title: "打ち消し", run: () => chain().toggleStrike().run(), active: () => this.editor!.isActive("strike") },
      { icon: ICONS.code, title: "コード（文の中）", run: () => chain().toggleCode().run(), active: () => this.editor!.isActive("code") },
      { icon: ICONS.quote, title: "引用", run: () => chain().toggleBlockquote().run(), active: () => this.editor!.isActive("blockquote") },
      { icon: ICONS.link, title: "リンク", run: () => this.link(this.bubble?.querySelector<HTMLElement>('[data-bubble="リンク"]') ?? undefined), active: () => this.editor!.isActive("link") },
    ];
  }

  private buildBubble(): HTMLElement {
    const dom = document.createElement("div");
    dom.className = "tt-bubble";
    for (const tool of this.bubbleTools()) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "tt-bubble-tool" + (tool.icon ? " tt-bubble-icon" : "") + (tool.extra ? " " + tool.extra : "");
      if (tool.icon) button.innerHTML = svg(tool.icon);
      else button.textContent = tool.label ?? "";
      button.title = tool.title;
      button.setAttribute("aria-label", tool.title);
      button.setAttribute("aria-pressed", "false");
      button.dataset.bubble = tool.title;
      button.addEventListener("mousedown", (event) => event.preventDefault());
      button.addEventListener("click", tool.run);
      dom.appendChild(button);
    }
    // キャプションの帯（3 つ）。本文の 7 つとは別の要素で、paint が出し分ける。
    const caption = document.createElement("div");
    caption.className = "tt-bubble-caption";
    caption.hidden = true;
    for (const tool of this.captionBubbleTools()) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "tt-bubble-tool tt-bubble-icon";
      button.innerHTML = svg(tool.icon, 22);
      button.title = tool.title;
      button.setAttribute("aria-label", tool.title);
      button.setAttribute("aria-pressed", "false");
      button.dataset.caption = tool.title;
      button.addEventListener("mousedown", (event) => event.preventDefault());
      button.addEventListener("click", tool.run);
      caption.appendChild(button);
    }
    // キャプションのリンク: 帯が URL の欄 + 適用 + × に入れ替わる（note と同じ。コンテンツの候補は出さない）。
    const link = document.createElement("div");
    link.className = "tt-bubble-link";
    link.hidden = true;
    const input = document.createElement("input");
    input.type = "text";
    input.inputMode = "url";
    input.className = "tt-bubble-field";
    input.placeholder = "https://";
    input.setAttribute("aria-label", "リンクの URL");
    const apply = document.createElement("button");
    apply.type = "button";
    apply.className = "tt-bubble-apply";
    apply.textContent = "適用";
    apply.addEventListener("mousedown", (event) => event.preventDefault());
    apply.addEventListener("click", () => this.applyCaptionLink(input.value.trim()));
    const close = document.createElement("button");
    close.type = "button";
    close.className = "tt-bubble-close";
    close.textContent = "×";
    close.title = "閉じる";
    close.setAttribute("aria-label", "閉じる");
    close.addEventListener("mousedown", (event) => event.preventDefault());
    close.addEventListener("click", () => this.closeCaptionLink());
    // 欄の中のキーはエディタにも Elm（Esc で画面を閉じる）にも漏らさない。
    input.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.key === "Enter") {
        event.preventDefault();
        this.applyCaptionLink(input.value.trim());
      } else if (event.key === "Escape") {
        event.preventDefault();
        this.closeCaptionLink();
      }
    });
    link.append(input, apply, close);
    dom.append(caption, link);
    this.captionTools = caption;
    this.captionLink = link;
    this.bubble = dom;
    return dom;
  }

  private captionBubbleTools(): Array<{ icon: string; title: string; run: () => void; active: () => boolean }> {
    const chain = () => this.editor!.chain().focus();
    return [
      { icon: ICONS.bold, title: "太字", run: () => chain().toggleBold().run(), active: () => this.editor!.isActive("bold") },
      { icon: ICONS.strike, title: "打ち消し", run: () => chain().toggleStrike().run(), active: () => this.editor!.isActive("strike") },
      { icon: ICONS.link, title: "リンク", run: () => this.openCaptionLink(), active: () => this.editor!.isActive("link") },
    ];
  }

  private openCaptionLink() {
    if (!this.editor || !this.captionLink) return;
    const input = this.captionLink.querySelector<HTMLInputElement>("input");
    if (!input) return;
    const current = this.editor.isActive("link") ? this.editor.getAttributes("link").href : null;
    input.value = typeof current === "string" ? current : "";
    this.captionLinkOpen = true;
    this.paint();
    input.focus();
    input.select();
  }

  private closeCaptionLink() {
    this.captionLinkOpen = false;
    this.paint();
    this.editor?.commands.focus();
  }

  // 空なら外す。選択が無ければリンクの範囲ごと掛け直す。
  private applyCaptionLink(href: string) {
    if (!this.editor) return;
    const chain = this.editor.chain().focus().extendMarkRange("link");
    if (href === "") chain.unsetLink().run();
    else chain.setLink({ href }).run();
    this.captionLinkOpen = false;
    this.paint();
  }

  // キャプションでリンクの掛かった文字にいる時、選択の下に URL を文字で出す。
  // WhyNot: 本文のリンクの hover の面（`showLinkTip`）を使い回さない。あれは乗せた時だけで、
  // note はキャプションの選択に対して出す。
  private paintCaptionUrl(inCaption: boolean) {
    if (!this.editor) return;
    const { from, to } = this.editor.state.selection;
    const href = inCaption && from !== to && !this.captionLinkOpen && this.editor.isActive("link") ? this.editor.getAttributes("link").href : null;
    if (typeof href !== "string" || href === "" || !this.editor.isFocused) {
      this.captionUrl?.remove();
      this.captionUrl = null;
      return;
    }
    if (!this.captionUrl) {
      this.captionUrl = document.createElement("div");
      this.captionUrl.className = "tt-caption-url";
      this.appendChild(this.captionUrl);
    }
    this.captionUrl.textContent = href;
    const at = posToDOMRect(this.editor.view, from, to);
    const width = this.captionUrl.offsetWidth;
    this.captionUrl.style.top = `${Math.round(at.bottom + 6)}px`;
    this.captionUrl.style.left = `${Math.round(Math.max(8, at.left + at.width / 2 - width / 2))}px`;
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

    // 画像のキャプションの中では本文の 7 つを出さず、3 つ（太字 / 打ち消し / リンク）に入れ替える。
    const inImage = insideImage(this.editor.state);
    if (!inImage) this.captionLinkOpen = false;
    if (this.bubble && this.captionTools && this.captionLink) {
      const bubble = this.bubble;
      bubble.classList.toggle("is-caption", inImage);
      bubble.classList.toggle("is-input", inImage && this.captionLinkOpen);
      for (const tool of this.bubbleTools()) {
        const button = bubble.querySelector<HTMLElement>(`[data-bubble="${tool.title}"]`);
        if (!button) continue;
        const on = tool.active();
        button.classList.toggle("is-on", on);
        button.setAttribute("aria-pressed", on ? "true" : "false");
        button.hidden = inImage;
      }
      this.captionTools.hidden = !inImage || this.captionLinkOpen;
      this.captionLink.hidden = !inImage || !this.captionLinkOpen;
      for (const tool of this.captionBubbleTools()) {
        const button = this.captionTools.querySelector<HTMLElement>(`[data-caption="${tool.title}"]`);
        if (!button) continue;
        const on = tool.active();
        button.classList.toggle("is-on", on);
        button.setAttribute("aria-pressed", on ? "true" : "false");
      }
    }
    this.paintCaptionUrl(inImage);

    const select = this.querySelector<HTMLSelectElement>(".tt-block");
    if (select) {
      const level = [1, 2, 3, 4].find((n) => this.editor!.isActive("heading", { level: n }));
      select.value = level ? `h${level}` : "paragraph";
      select.disabled = inImage;
    }
  }

  // リンクを張る面。**TS は「開きたい」だけを投げる。**
  //
  // 面そのもの（URL の欄・コンテンツの候補・上下キー）は Elm が持つ（`src/LinkPick.elm`）。
  // 候補は API から来る物で、エディタは API を知らない。
  //
  // `anchor` は押した物（浮く帯のボタン）。無ければツールバーのリンクのボタン。
  // **押した所から離れた場所に出さない**ので、置き場所の元になる矩形をここで測って渡す。
  private link(anchor?: HTMLElement) {
    if (!this.editor) return;
    const button = anchor ?? this.querySelector<HTMLElement>('.tt-tool[title="リンク"]') ?? this;
    const box = button.getBoundingClientRect();
    const current = this.editor.isActive("link") ? this.editor.getAttributes("link") : null;
    this.linkSeq += 1;
    this.dispatchEvent(
      new CustomEvent("linkopen", {
        detail: {
          seq: this.linkSeq,
          // 本文のリンクは URL とコンテンツの両方。URL しか受けない所は "url"。
          mode: "link",
          href: typeof current?.href === "string" ? current.href : "",
          entryId: typeof current?.entryId === "string" ? current.entryId : null,
          rect: {
            left: box.left,
            top: box.top,
            bottom: box.bottom,
            spaceWidth: window.innerWidth,
            spaceHeight: window.innerHeight,
          },
        },
      }),
    );
  }

  // Elm が決めた物。**`seq` が新しい時だけ実行する**（property は同じ値のまま
  // 描き直される事がある）。
  set linkchoice(value: unknown) {
    const choice = value as LinkChoice | null;
    if (!choice || typeof choice.seq !== "number" || choice.seq <= this.linkDoneAt) return;
    this.linkDoneAt = choice.seq;
    // **doc を変える物は 1 拍おく**（`insert` と同じ）。property が入るのは Elm が DOM を
    // 書いている最中で、その場で doc を変えると `docchange` が Elm の描き直しの中に飛び込み、
    // 入れた物が Elm 側に残らない（画面には出るのに保存されなかった）。
    window.setTimeout(() => this.applyLink(choice), 0);
  }

  // 表を**作る**面。大きさを升目で選ぶ（Word / Google ドキュメント / Notion の `/table` と同じ）。
  // WhyNot: 既にある表への操作をここに並べない。触りたい表から遠く、面が表そのものを覆う。
  // 表への操作は表の上に出す帯（tt-tablebar）が持つ。
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

    this.menu = dom;
    this.appendChild(dom);
    this.placeUnder(dom, '.tt-tool[title="表"]', 220);
    const button = this.querySelector<HTMLElement>('.tt-tool[title="表"]');
    this.unmenu = dismissOn({ inside: button ? [dom, button] : [dom], onClose: () => this.closeMenu() });
  }

  private closeMenu() {
    this.unmenu?.();
    this.unmenu = null;
    this.menu?.remove();
    this.menu = null;
    this.editor?.commands.focus();
    this.paintTableTools();
  }

  //
  // 表の道具（帯と、縮める時の印）。**セルにカーソルがある時か、表にマウスが乗っている時だけ**出す。
  //
  // WhyNot: ProseMirror の DOM の中に入れない。表の node view は書き換えの度に中を作り直すので、
  // 入れた物が消えるか、PM が「知らない変更」として拾って戻す（実際に戻された）。
  //
  private paintTableTools(hovered?: HTMLTableElement | null) {
    if (!this.editor) return;
    // 動かしている最中は描き直さない（掴んだ物と塊と線を消してしまう）。
    if (isDraggingTable()) return;
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
    const base = mount.getBoundingClientRect();
    const wrap = (table.closest(".tableWrapper") as HTMLElement | null) ?? table;
    const clip = wrap.getBoundingClientRect();
    layer.replaceChildren(
      this.tableBar(table, base, clip),
      ...tableHandles({
        editor: this.editor,
        table,
        layer,
        base,
        clip,
        onDone: () => this.paintTableTools(),
      })
    );

    // 横に長い表はスクロールするので、帯も付いて動く。
    this.unwatchScroll?.();
    const again = () => this.paintTableTools(hovered);
    wrap.addEventListener("scroll", again);
    this.unwatchScroll = () => wrap.removeEventListener("scroll", again);
  }

  // 表にマウスが乗った時にも掴みを出す。
  private watchTableHover(mount: HTMLElement) {
    mount.addEventListener("mouseover", (event) => {
      const table = (event.target as Element | null)?.closest?.("table") as HTMLTableElement | null;
      if (table) this.paintTableTools(table);
    });
    mount.addEventListener("mouseout", (event) => {
      const to = (event as MouseEvent).relatedTarget as Element | null;
      if (to?.closest?.("table") || to?.closest?.(".tt-grips")) return;
      if (this.menu) return;
      this.paintTableTools();
    });
  }

  //
  // リンクに乗せたら、指し先を吹き出しで出す。
  //
  // **押さないと分からない、では遅い。** 本文の見た目はどちらも下線なので、
  // 外部かコンテンツか、どのコンテンツかが読んでいる間に分からなかった。
  // Notion・WordPress・Payload も、乗せる／押すと指し先を出す。
  //
  private watchLinkHover(mount: HTMLElement) {
    mount.addEventListener("mouseover", (event) => {
      const anchor = (event.target as Element | null)?.closest?.("a") as HTMLAnchorElement | null;
      if (!anchor) return;
      this.showLinkTip(anchor);
    });
    mount.addEventListener("mouseout", (event) => {
      const to = (event as MouseEvent).relatedTarget as Element | null;
      if (to?.closest?.("a")) return;
      this.tip?.remove();
      this.tip = null;
    });
  }

  private showLinkTip(anchor: HTMLAnchorElement) {
    this.tip?.remove();
    const entryId = anchor.getAttribute("data-entry-id");
    const tip = document.createElement("div");
    tip.className = "tt-link-tip";

    const icon = document.createElement("span");
    icon.className = "tt-link-icon";
    const body = document.createElement("span");
    body.className = "tt-link-tip-body";
    const name = document.createElement("span");
    name.className = "tt-link-tip-name";
    const where = document.createElement("code");
    where.className = "tt-link-tip-path";
    if (entryId) {
      const found = this.linked.get(entryId);
      icon.innerHTML = svg(ICONS.entry);
      if (found) {
        name.textContent = `${found.title}（${found.type} · ${found.stageName ?? ""}）`;
        where.textContent = found.path ?? `#entry:${entryId}`;
        // **型紙が無ければ、出るのは `#entry:{id}` だとそのまま見せる。** 配信で
        // 何が出るかを隠すと、サイト側が置き換えを書いていない事に気付けない。
        if (!found.path) where.classList.add("is-weak");
      } else {
        tip.classList.add("is-bad");
        name.textContent = "見つかりません";
        where.textContent = `#entry:${entryId}`;
      }
    } else {
      icon.innerHTML = svg(ICONS.external);
      name.textContent = "外部リンク";
      where.textContent = anchor.getAttribute("href") ?? "";
    }
    body.append(name, where);
    tip.append(icon, body);
    this.appendChild(tip);

    const at = anchor.getBoundingClientRect();
    const base = this.getBoundingClientRect();
    tip.style.left = `${Math.max(at.left - base.left, 4)}px`;
    tip.style.top = `${at.bottom - base.top + 6}px`;
    this.tip = tip;
  }

  // カーソルが入っている表の DOM。
  private currentTable(): HTMLTableElement | null {
    if (!this.editor || !this.editor.isActive("table")) return null;
    const at = this.editor.view.domAtPos(this.editor.state.selection.from);
    const node = at.node instanceof Element ? at.node : at.node.parentElement;
    return (node?.closest("table") as HTMLTableElement | null) ?? null;
  }

  //
  // 表の上の帯。**表そのものを相手にする操作**（大きさ・列の寄せ・削除）を置く。
  //
  // 掴みは行と列を相手にするので、帯には出さない。削除だけ右端に離すのは、
  // 押し間違いが一番痛い物を他と隣り合わせにしないため（Notion / Confluence も同じ置き方）。
  //
  private tableBar(table: HTMLTableElement, base: DOMRect, clip: DOMRect): HTMLElement {
    const bar = document.createElement("div");
    bar.className = "tt-tablebar";
    const at = table.getBoundingClientRect();
    bar.style.left = `${Math.max(at.left, clip.left) - base.left}px`;
    bar.style.top = `${at.top - base.top - 26}px`;
    bar.style.width = `${Math.min(at.right, clip.right) - Math.max(at.left, clip.left)}px`;

    const left = document.createElement("div");
    left.className = "tt-tablebar-left";
    left.appendChild(this.barButton(ICONS.size, "大きさを変える", (button) => this.sizeMenu(button)));

    const now = this.editor ? columnAlign(this.editor) : null;
    const aligns: Array<[Align, string, string]> = [
      ["left", ICONS.alignLeft, "左に寄せる"],
      ["center", ICONS.alignCenter, "中央に寄せる"],
      ["right", ICONS.alignRight, "右に寄せる"],
    ];
    for (const [align, icon, title] of aligns) {
      // **押した列全体に効く**（マークダウンの寄せは列の属性）。もう一度押すと外す。
      const button = this.barButton(icon, title, () => {
        if (!this.editor) return;
        alignColumn(this.editor, columnAlign(this.editor) === align ? null : align);
        this.paintTableTools();
      });
      button.classList.toggle("is-on", now === align);
      left.appendChild(button);
    }

    const remove = this.barButton(ICONS.trash, "表を消す", () => {
      this.editor?.chain().focus().deleteTable().run();
      this.paintTableTools();
    });
    remove.classList.add("tt-tablebar-remove");

    bar.append(left, remove);
    return bar;
  }

  private barButton(icon: string, title: string, run: (button: HTMLElement) => void): HTMLElement {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "tt-tablebar-button";
    button.title = title;
    button.innerHTML = svg(icon);
    button.addEventListener("mousedown", (event) => {
      event.preventDefault();
      run(button);
    });
    return button;
  }

  //
  // 大きさを選び直す面。**升目をなぞると、消える行・列が表の上で赤く出る。**
  // 出さないと、縮めた時に何が消えたか押した後にしか分からない。
  //
  private sizeMenu(at: HTMLElement) {
    if (!this.editor) return;
    if (this.menu) {
      this.closeMenu();
      return;
    }
    const size = tableSize(this.editor);
    if (!size) return;

    const dom = document.createElement("div");
    dom.className = "tt-menu tt-size";
    const label = document.createElement("div");
    label.className = "tt-size-label";
    label.textContent = `${size.rows} 行 × ${size.cols} 列`;
    const grid = document.createElement("div");
    grid.className = "tt-size-grid";

    const MAX = 8;
    const cells: HTMLElement[] = [];
    const mark = (rows: number, cols: number) => {
      cells.forEach((cell, index) => {
        const row = Math.floor(index / MAX) + 1;
        const col = (index % MAX) + 1;
        cell.classList.toggle("is-on", rows > 0 && row <= rows && col <= cols);
      });
      label.textContent = rows > 0 ? `${rows} 行 × ${cols} 列` : `${size.rows} 行 × ${size.cols} 列`;
      this.markDropped(rows, cols);
    };
    for (let row = 1; row <= MAX; row += 1) {
      for (let col = 1; col <= MAX; col += 1) {
        const cell = document.createElement("span");
        cell.className = "tt-size-cell";
        cell.addEventListener("mousemove", () => mark(row, col));
        cell.addEventListener("mousedown", (event) => {
          event.preventDefault();
          resizeTable(this.editor!, row, col);
          this.closeMenu();
          this.paintTableTools();
        });
        cells.push(cell);
        grid.appendChild(cell);
      }
    }
    grid.addEventListener("mouseleave", () => mark(0, 0));
    dom.append(label, grid);
    mark(size.rows, size.cols);

    this.menu = dom;
    this.appendChild(dom);
    this.placeUnder(dom, at, 220);
    this.unmenu = dismissOn({
      inside: [dom, at],
      onClose: () => {
        this.markDropped(0, 0);
        this.closeMenu();
      },
    });
  }

  //
  // 縮めた時に消える行・列を、表の上に赤く敷く。
  //
  // WhyNot: セルに class を付けない。**ProseMirror が「知らない DOM 変更」として戻す**
  // （実際に戻されて、印が 1 つも出なかった）。掴みと同じで、層の側に描く。
  //
  private markDropped(rows: number, cols: number) {
    const mount = this.querySelector<HTMLElement>(".tt-mount");
    const layer = this.querySelector<HTMLElement>(".tt-grips");
    if (!mount || !layer) return;
    layer.querySelectorAll(".tt-drop").forEach((node) => node.remove());
    const table = this.currentTable();
    if (!table || rows <= 0) return;

    const base = mount.getBoundingClientRect();
    const wrap = (table.closest(".tableWrapper") as HTMLElement | null) ?? table;
    const clip = wrap.getBoundingClientRect();
    const at = table.getBoundingClientRect();
    const left = Math.max(at.left, clip.left);
    const right = Math.min(at.right, clip.right);
    const shade = (box: { left: number; top: number; width: number; height: number }) => {
      if (box.width <= 0 || box.height <= 0) return;
      const dom = document.createElement("div");
      dom.className = "tt-drop";
      dom.style.left = `${box.left - base.left}px`;
      dom.style.top = `${box.top - base.top}px`;
      dom.style.width = `${box.width}px`;
      dom.style.height = `${box.height}px`;
      layer.appendChild(dom);
    };

    const rowList = Array.from(table.rows);
    if (rows < rowList.length) {
      const top = rowList[rows].getBoundingClientRect().top;
      shade({ left, top, width: right - left, height: at.bottom - top });
    }
    const head = rowList[0];
    if (head && cols < head.cells.length) {
      const start = Math.max(head.cells[cols].getBoundingClientRect().left, clip.left);
      shade({ left: start, top: at.top, width: right - start, height: at.height });
    }
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
  // ProseMirror の mark を掛けるのはここに残る（面がどこにあっても doc を触るのは TS）。
  private applyLink(choice: LinkChoice) {
    if (!this.editor) return;
    // 何も選ばずに畳んだ時は、本文に focus を戻すだけ。
    if (choice.cancel) {
      this.editor.commands.focus();
      return;
    }
    const chain = this.editor.chain().focus();
    if (choice.remove) {
      chain.extendMarkRange("link").unsetLink().run();
      return;
    }
    const attrs = choice.entryId ? { href: null, entryId: choice.entryId } : { href: choice.href, entryId: null };
    // 選んだ物には**入れる文字**を添える。選択が空の時にこれを本文へ挿し込む
    // （Notion / Craft / Zenn / Google ドキュメントが揃って、選んだ物の名前を入れる）。
    const bare = this.editor.state.selection.empty && !this.editor.isActive("link");
    if (bare) chain.insertContent({ type: "text", text: choice.label, marks: [{ type: "link", attrs }] }).run();
    else chain.extendMarkRange("link").setMark("link", attrs).run();
  }

  private placeUnder(dom: HTMLElement, anchor: string | HTMLElement, width: number) {
    const button = typeof anchor === "string" ? this.querySelector<HTMLElement>(anchor) : anchor;
    if (!button) return;
    placeUnder(dom, button, width);
  }

  disconnectedCallback() {
    this.blocks?.destroy();
    this.blocks = null;
    this.editor?.destroy();
    this.editor = null;
  }

  attributeChangedCallback(name: string) {
    if (name === "assets") {
      this.syncAssets();
      return;
    }
    if (name === "linked") {
      this.syncLinked();
      return;
    }
    if (name === "cards") {
      this.syncCards();
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
    this.cards.batch(() => this.editor!.commands.setContent(this.docFromAttribute(this.editor!.extensionManager.extensions), false));
    this.askLinked();
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

  // url → OGP の対応。**エディタは相手のサイトを読みに行かない**（CMS が取って表に残す）。
  private syncCards() {
    const list = this.parsed("cards");
    this.cards.set(Array.isArray(list) ? list : []);
  }

  private syncLinked() {
    const list = this.parsed("linked");
    if (!Array.isArray(list)) return;
    this.linked = new Map((list as Linked[]).filter((found) => found?.id).map((found) => [found.id, found]));
  }

  //
  // 本文が指しているコンテンツを引き直してもらう。
  //
  // **エディタは API を知らない**（`linkopen` と同じ決まり）。doc に居る entryId を
  // `linkresolve` の event で外に出し、答えは `linked` の属性で受ける。
  //
  private askLinked() {
    if (!this.editor) return;
    const ids = new Set<string>();
    this.editor.state.doc.descendants((node) => {
      for (const mark of node.marks) {
        const entryId = mark.attrs?.entryId;
        if (mark.type.name === "link" && typeof entryId === "string" && entryId) ids.add(entryId);
      }
    });
    // **同じ顔ぶれなら投げ直さない。** 打つ度に doc が変わるので、そのまま出すと
    // 1 文字ごとに問い合わせが飛ぶ。
    const key = [...ids].sort().join(",");
    if (key === this.asked) return;
    this.asked = key;
    this.dispatchEvent(new CustomEvent("linkresolve", { detail: [...ids] }));
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
      const doc = flatten(toTaskList(foldUnknown(liftCaption(parsed), this.knownNames(extensions))));
      return Array.isArray(doc.content) && doc.content.length > 0 ? doc : EMPTY_DOC;
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
    const doc = fromTaskList(unfold(this.editor.getJSON()));
    const text = JSON.stringify(doc);
    if (text === this.lastSent) return;
    this.lastSent = text;
    this.dispatchEvent(new CustomEvent("docchange", { detail: text }));
  }
}

if (!customElements.get("tiptap-editor")) {
  customElements.define("tiptap-editor", TiptapEditor);
}
