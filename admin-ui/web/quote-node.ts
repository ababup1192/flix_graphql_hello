// 引用（blockquote）と、その出典（quoteCite）。
//
// 出典は blockquote の**最後の子**の `quoteCite` の中身（text と mark）で、attrs には持たない
// （`docs/design/richtext-note-style.md` 3.2）。掛けられるマークは画像のキャプションと同じ
// bold / italic / strike / code / link（CMS の `RichText.captionMarkNames`）。
//
// WhyNot: 出典を文字列の attr にしない。note は出典にリンクを張る文化で、attr だと
// link / bold のような mark を掛ける場所が無い（画像のキャプションと同じ理由）。
//
// WhyNot: 出典を引用の中の段落にしない。引用の平文化で出典が本文に混ざる。箱の外の下に
// 出すのは CSS（`.tt-body blockquote > cite`）で、doc の上では引用の最後の子のまま。
//
// WhyNot: 出典と出典の URL を横に 2 欄で並べない。note の実物は出典が 1 つで、URL は
// その文字に掛かるリンク。2 欄は右下に 2 つの下線が並び、どちらが本体か読めなかった。
//
// WhyNot: 空の出典を doc に残さない。書き出しに `quoteCite` だけの node が出ると CMS の
// Markdown が出典の無い `— ` を書く。空の物は焦点が外れた時に落とし、置き場は
// node view の行（`.tt-quote-cite-row`）が高さだけ持つ。

import { Node } from "@tiptap/core";
import Blockquote from "@tiptap/extension-blockquote";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { dropPendingLine, leaveBlock } from "./block-edges";

const CITE = "quoteCite";
const PLACEHOLDER = "出典を入力";

type ViewArgs = {
  node: any;
  getPos: () => number | undefined;
  editor: any;
};

/** 選択が引用の出典の中にあるか（出典の文字を選んでいる時も含む）。 */
export function insideQuoteCite(state: any): boolean {
  const $from = state.selection.$from;
  for (let depth = $from.depth; depth > 0; depth -= 1) if ($from.node(depth).type.name === CITE) return true;
  return false;
}

/** 出典が空（中身が無い）か。 */
function isEmpty(node: { content: { size: number } }): boolean {
  return node.content.size === 0;
}

// 空の出典を落とす。**焦点がその中にある間だけ残す。**
function emptyCites(doc: any, keep: { from: number; to: number } | null): Array<{ pos: number; size: number }> {
  const found: Array<{ pos: number; size: number }> = [];
  doc.descendants((node: any, pos: number) => {
    if (node.type.name !== CITE) return true;
    const inside = keep !== null && keep.from > pos && keep.to < pos + node.nodeSize;
    if (isEmpty(node) && !inside) found.push({ pos, size: node.nodeSize });
    return false;
  });
  return found;
}

function dropEmptyCites(view: any, keepSelection: boolean) {
  const state = view.state;
  const found = emptyCites(state.doc, keepSelection ? state.selection : null);
  if (found.length === 0) return;
  const tr = state.tr;
  for (const one of found.reverse()) tr.delete(tr.mapping.map(one.pos), tr.mapping.map(one.pos + one.size));
  view.dispatch(tr.setMeta("addToHistory", false));
}

function citePlugin() {
  return new Plugin({
    key: new PluginKey("quoteCiteNotEmpty"),
    appendTransaction(transactions: readonly any[], _old: any, next: any) {
      if (!transactions.some((transaction) => transaction.docChanged || transaction.selectionSet)) return null;
      const found = emptyCites(next.doc, next.selection);
      if (found.length === 0) return null;
      const tr = next.tr;
      for (const one of found.reverse()) tr.delete(tr.mapping.map(one.pos), tr.mapping.map(one.pos + one.size));
      return tr.setMeta("addToHistory", false);
    },
    props: {
      // 離れた時も落とす。**選択が動かないので appendTransaction では拾えない**（`block-edges.ts` の疑似行と同じ）。
      handleDOMEvents: {
        blur(view: any) {
          dropEmptyCites(view, false);
          return false;
        },
      },
      // 出典の中では入力規則を効かせない。
      // WhyNot: schema に任せない。「# 」や「> 」は引用そのものを包み直したり置き換えたりして、
      // 出典を打っていたつもりの引用が壊れる（画像のキャプションと同じ直し方）。
      handleTextInput(view: any, from: number, to: number, inserted: string) {
        if (!insideQuoteCite(view.state)) return false;
        view.dispatch(view.state.tr.insertText(inserted, from, to));
        return true;
      },
    },
  });
}

/** 引用の出典。中身は text と mark だけで、画像のキャプションと同じ形。 */
export const QuoteCite = Node.create({
  name: CITE,
  // WhyNot: `inline*` にしない。hardBreak が入り、出典が 2 行になる（CMS も text しか受けない）。
  content: "text*",
  marks: "bold italic strike code link",
  selectable: false,
  defining: true,
  isolating: true,

  parseHTML() {
    return [{ tag: "cite[data-quote-cite]" }];
  },

  renderHTML() {
    return ["cite", { "data-quote-cite": "", class: "tt-quote-cite" }, 0];
  },

  addKeyboardShortcuts() {
    const inCite = () => insideQuoteCite(this.editor.state);
    const swallow = () => inCite();
    // 上下の矢印は引用の外の行へ（欄だった頃と同じで、↑ も ↓ も引用そのものの外に出る）。
    const leave = (dir: -1 | 1) => () => {
      const state = this.editor.state;
      if (!inCite()) return false;
      const $from = state.selection.$from;
      const depth = $from.depth - 1;
      if (depth < 1) return false;
      return leaveBlock(this.editor.view, $from.before(depth), $from.node(depth).nodeSize, dir);
    };
    // 末尾で Delete を素の動きに任せると、引用の段落と結合して出典が消える。
    //
    // WhyNot: Backspace は書かない。先頭の Backspace は blockEdges が先に受けていて、
    // ここに書いても一度も呼ばれない（2026-09-12 に外して振る舞いが変わらない事を見た）。
    const atEnd = () => {
      const state = this.editor.state;
      if (!inCite() || !state.selection.empty) return false;
      const $from = state.selection.$from;
      return $from.parentOffset === $from.parent.content.size;
    };
    return {
      Enter: swallow,
      "Shift-Enter": swallow,
      "Mod-Enter": swallow,
      ArrowUp: leave(-1),
      ArrowDown: leave(1),
      Delete: atEnd,
    };
  },

  addProseMirrorPlugins() {
    return [citePlugin()];
  },
});

/**
 * 旧い形（blockquote の attrs.cite / citeUrl）を、読む時だけ `quoteCite` に写す。
 * 書く時は `quoteCite` しか出さない。`quoteCite` が既にあればそちらが勝つ。
 */
export function liftQuoteCite(node: any): any {
  if (!node || typeof node !== "object") return node;
  const next = Array.isArray(node.content) ? { ...node, content: node.content.map(liftQuoteCite) } : { ...node };
  if (next.type !== "blockquote" || !next.attrs) return next;
  const { cite, citeUrl, ...attrs } = next.attrs;
  const content: any[] = Array.isArray(next.content) ? next.content : [];
  const already = content.some((child: any) => child?.type === CITE);
  const legacy = typeof cite === "string" ? cite.trim() : "";
  if (already || legacy === "") return { ...next, attrs, content };
  const url = typeof citeUrl === "string" ? citeUrl.trim() : "";
  const marks = url === "" ? undefined : [{ type: "link", attrs: { href: url } }];
  return { ...next, attrs, content: [...content, { type: CITE, content: [{ type: "text", text: legacy, ...(marks ? { marks } : {}) }] }] };
}

export const QuoteNode = Blockquote.extend({
  // 出典は最後の子の 1 つだけ（CMS の `RichText.checkQuoteChildren` と同じ形）。
  content: "block+ quoteCite?",

  addExtensions() {
    return [QuoteCite];
  },

  // WhyNot: 旧い attrs を schema から外さない。外すと ProseMirror が JSON を読む時に黙って捨て、
  // `liftQuoteCite` を通していない doc の出典が消える。書き出しでは null になり、`dropEmptyAttrs` が落とす。
  addAttributes() {
    return {
      ...this.parent?.(),
      cite: {
        default: null,
        parseHTML: (element: HTMLElement) => element.getAttribute("data-cite"),
        renderHTML: (attributes: Record<string, unknown>) => (attributes.cite ? { "data-cite": String(attributes.cite) } : {}),
      },
      citeUrl: {
        default: null,
        parseHTML: (element: HTMLElement) => element.getAttribute("data-cite-url"),
        renderHTML: (attributes: Record<string, unknown>) =>
          attributes.citeUrl ? { "data-cite-url": String(attributes.citeUrl) } : {},
      },
    };
  },

  addNodeView() {
    return ({ node, getPos, editor }: ViewArgs) => {
      const dom = document.createElement("div");
      dom.className = "tt-quote";
      const quote = document.createElement("blockquote");

      // 箱の外の下、右寄せの 1 行。**出典そのものは contentDOM（引用の中）に居る**ので、
      // この行は高さを空けるだけ。中身が無い間だけ placeholder を出し、押すと出典を作る。
      const row = document.createElement("div");
      row.className = "tt-quote-cite-row";
      const hint = document.createElement("span");
      hint.className = "tt-quote-hint";
      hint.textContent = PLACEHOLDER;
      row.append(hint);
      dom.append(quote, row);

      const found = () => {
        const pos = getPos();
        if (pos === undefined) return null;
        const at = editor.view.state.doc.nodeAt(pos);
        return at ? { pos, node: at } : null;
      };

      // placeholder を押したら出典を作って、その中に焦点を入れる。
      // 置きっぱなしの疑似行を先に消してから入れる（残すと、出典から矢印で出た先が 1 つずれる）。
      // WhyNot: 既定の焦点に任せない。ProseMirror が押下を握るので、行を押しても焦点が入らない。
      const open = () => {
        const here = found();
        if (!here) return;
        const type = editor.view.state.schema.nodes[CITE];
        if (!type) return;
        const last = here.node.lastChild;
        const state = editor.view.state;
        if (last && last.type.name === CITE) {
          // 既にある出典の末尾へ（引用の閉じの 1 つ内側が出典の閉じ）。
          const at = here.pos + here.node.nodeSize - 2;
          editor.view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, at)));
          editor.view.focus();
          return;
        }
        const at = here.pos + here.node.nodeSize - 1;
        const tr = state.tr.insert(at, type.create());
        tr.setSelection(TextSelection.create(tr.doc, at + 1));
        tr.setMeta("addToHistory", false);
        editor.view.dispatch(tr.scrollIntoView());
        editor.view.focus();
      };
      row.addEventListener("mousedown", (event) => {
        event.preventDefault();
        dropPendingLine(editor.view);
        open();
      });

      // 焦点が引用の中にあるか、出典が入っている時だけ placeholder を出す。
      const active = () => {
        const pos = getPos();
        if (pos === undefined) return false;
        if (!editor.view.hasFocus()) return false;
        const size = editor.view.state.doc.nodeAt(pos)?.nodeSize ?? 1;
        const selection = editor.state.selection;
        return selection.from >= pos && selection.to <= pos + size;
      };

      // 出典は箱の下に重ねて置くので、行はその高さだけ持つ（次のブロックが出典に乗らない）。
      let watch: ResizeObserver | null = null;
      const fit = () => {
        const cite = quote.querySelector<HTMLElement>(":scope > cite");
        watch?.disconnect();
        watch = null;
        hint.hidden = cite !== null;
        if (!cite) {
          row.style.height = "";
          return;
        }
        row.style.height = `${cite.offsetHeight}px`;
        watch = new ResizeObserver(() => {
          row.style.height = `${cite.offsetHeight}px`;
        });
        watch.observe(cite);
      };

      // 行は「出た状態」で doc に入れる。隠したまま入れると、出し直しても押下を受け付けない。
      let mounted = false;
      const paint = () => {
        fit();
        row.classList.toggle("is-quiet", mounted && hint.hidden === false && !active());
      };
      paint();
      requestAnimationFrame(() => {
        mounted = true;
        paint();
      });
      const sync = () => paint();
      editor.on("transaction", sync);
      editor.on("focus", sync);
      editor.on("blur", sync);

      return {
        dom,
        contentDOM: quote,
        update(updated: { type: { name: string } }) {
          if (updated.type.name !== "blockquote") return false;
          paint();
          return true;
        },
        ignoreMutation(mutation: { type: string; target: globalThis.Node }) {
          return mutation.type !== "selection" && row.contains(mutation.target);
        },
        stopEvent(event: Event) {
          return row.contains(event.target as globalThis.Node);
        },
        destroy() {
          watch?.disconnect();
          editor.off("transaction", sync);
          editor.off("focus", sync);
          editor.off("blur", sync);
        },
      };
    };
  },
});
