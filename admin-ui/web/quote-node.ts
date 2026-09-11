// 引用（blockquote）に出典を付ける。
//
// node 名は `blockquote` のまま、attrs に `cite` / `citeUrl` を足す。`getJSON` の形が CMS の
// doc と同じになる（`docs/design/richtext-note-style.md` 3.2）。
//
// WhyNot: 出典を blockquote の中の段落にしない。引用の平文化で出典が本文に混ざる。
// 欄は contentDOM の外（`dom` の中、contentDOM の後ろ）に置き、欄の操作は doc に混ぜない
// （`image-node.ts` の gallery の帯と同じ流儀）。
//
// WhyNot: 出典と出典の URL を横に 2 欄で並べない。note の実物は出典が 1 つで、URL は
// その文字に掛かるリンク。2 欄は右下に 2 つの下線が並び、どちらが本体か読めなかった。
//
// WhyNot: URL を入れるボタンを出典の行に置かない。行に出すのは出典の文字だけ
// （`docs/design/richtext-quote-mock.html` のどの状態にも印が無い）。`citeUrl` は読んで
// 書き戻すだけで、画面から入れる口は部品の整理（`docs/design/editor-dom-parts.md`）の後に
// 出典の文字を選ぶ帯として作る。今は Markdown と API から入る。

import Blockquote from "@tiptap/extension-blockquote";
import { dropPendingLine, leaveBlock } from "./block-edges";
import { isHttpUrl, noteInput } from "./note-input";

type ViewArgs = {
  node: { attrs: Record<string, unknown> };
  getPos: () => number | undefined;
  editor: any;
};

function text(attrs: Record<string, unknown>, name: string): string {
  return typeof attrs[name] === "string" ? (attrs[name] as string) : "";
}

export const QuoteNode = Blockquote.extend({
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

      // 箱の外の下、右寄せの 1 行。欄は 1 つだけ。
      const row = document.createElement("div");
      row.className = "tt-quote-cite-row";

      // 今の値。URL は画面から入れる口を持たないので、読んで書き戻すだけ。
      let citeText = text(node.attrs, "cite");
      let urlText = text(node.attrs, "citeUrl");

      const write = () => {
        const pos = getPos();
        if (pos === undefined) return;
        const found = editor.view.state.doc.nodeAt(pos);
        if (!found) return;
        const next = { cite: citeText.trim() || null, citeUrl: urlText.trim() || null };
        if ((found.attrs.cite ?? null) === next.cite && (found.attrs.citeUrl ?? null) === next.citeUrl) return;
        editor.view.dispatch(editor.view.state.tr.setNodeMarkup(pos, undefined, { ...found.attrs, ...next }));
      };
      // 欄が 1 つなので、↑ も ↓ も引用の外の行へ出る（`block-edges.ts` の `leaveBlock`）。
      const leave = (dir: -1 | 1) => {
        const pos = getPos();
        if (pos === undefined) return;
        const found = editor.view.state.doc.nodeAt(pos);
        if (!found) return;
        leaveBlock(editor.view, pos, found.nodeSize, dir);
      };
      const take = (value: string) => {
        citeText = value;
        write();
      };
      const field = noteInput("出典を入力", "tt-quote-field tt-quote-cite", take, leave);

      // 置きっぱなしの疑似行を先に消してから焦点を入れる（残すと、欄から矢印で出た先が 1 つずれる）。
      // WhyNot: 既定の焦点に任せない。ProseMirror が押下を握るので、欄を押しても焦点が入らない。
      field.addEventListener("mousedown", (event) => {
        if (document.activeElement === field) return;
        event.preventDefault();
        dropPendingLine(editor.view);
        field.focus();
      });
      field.addEventListener("input", () => {
        citeText = field.value;
        paintField();
      });

      row.append(field);
      dom.append(quote, row);

      // 焦点が引用の中か欄にあるか、出典か URL が入っている時だけ行を出す。
      // どちらも無いまま離れたら、placeholder ごと出さない。
      const active = () => {
        const pos = getPos();
        if (pos === undefined) return false;
        if (row.contains(document.activeElement)) return true;
        if (!editor.view.hasFocus()) return false;
        const size = editor.view.state.doc.nodeAt(pos)?.nodeSize ?? 1;
        const selection = editor.state.selection;
        return selection.from >= pos && selection.to <= pos + size;
      };
      const paintField = () => {
        const url = urlText.trim();
        // URL が掛かっている出典はリンクとして見せる（下線）。URL は乗せると読める。
        field.classList.toggle("is-linked", url !== "" && isHttpUrl(url));
        field.classList.toggle("is-bad", url !== "" && !isHttpUrl(url));
        field.title = url;
      };
      // 行は「出た状態」で doc に入れる。隠したまま入れると、出し直しても焦点を受け付けない。
      let mounted = false;
      const paint = (attrs: Record<string, unknown>) => {
        if (document.activeElement !== field) {
          citeText = text(attrs, "cite");
          field.value = citeText;
        }
        urlText = text(attrs, "citeUrl");
        paintField();
        row.classList.toggle("is-quiet", mounted && !(active() || citeText !== "" || urlText !== ""));
      };
      let attrs = node.attrs;
      paint(attrs);
      requestAnimationFrame(() => {
        mounted = true;
        paint(attrs);
      });
      const sync = () => paint(attrs);
      editor.on("transaction", sync);
      editor.on("focus", sync);
      editor.on("blur", sync);

      return {
        dom,
        contentDOM: quote,
        update(updated: { type: { name: string }; attrs: Record<string, unknown> }) {
          if (updated.type.name !== "blockquote") return false;
          attrs = updated.attrs;
          paint(attrs);
          return true;
        },
        ignoreMutation(mutation: { type: string; target: globalThis.Node }) {
          return row.contains(mutation.target);
        },
        stopEvent(event: Event) {
          return row.contains(event.target as globalThis.Node);
        },
        destroy() {
          editor.off("transaction", sync);
          editor.off("focus", sync);
          editor.off("blur", sync);
        },
      };
    };
  },
});
