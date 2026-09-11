// 引用（blockquote）に出典を付ける。
//
// node 名は `blockquote` のまま、attrs に `cite` / `citeUrl` を足す。`getJSON` の形が CMS の
// doc と同じになる（`docs/design/richtext-note-style.md` 3.2）。
//
// WhyNot: 出典を blockquote の中の段落にしない。引用の平文化で出典が本文に混ざる。
// 欄は contentDOM の外（`dom` の中、contentDOM の後ろ）に置き、欄の操作は doc に混ぜない
// （`image-node.ts` の gallery の帯と同じ流儀）。

import Blockquote from "@tiptap/extension-blockquote";
import { dropPendingLine, leaveBlock } from "./block-edges";
import { isHttpUrl, noteInput, urlInput, walkInputs } from "./note-input";

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

      // 右下の薄い「出典を追加」。押すと 2 欄が出る。両方空で離れたら畳む。
      const add = document.createElement("button");
      add.type = "button";
      add.className = "tt-quote-add";
      add.textContent = "出典を追加";

      const fields = document.createElement("div");
      fields.className = "tt-quote-fields";
      const write = () => {
        const pos = getPos();
        if (pos === undefined) return;
        const found = editor.view.state.doc.nodeAt(pos);
        if (!found) return;
        const next = { cite: cite.value.trim() || null, citeUrl: citeUrl.value.trim() || null };
        if ((found.attrs.cite ?? null) === next.cite && (found.attrs.citeUrl ?? null) === next.citeUrl) return;
        editor.view.dispatch(editor.view.state.tr.setNodeMarkup(pos, undefined, { ...found.attrs, ...next }));
      };
      // WhyNot: 2 欄で互いを指し合わない。上下の矢印が出典 ⇄ 出典の URL を往復するだけになり、
      // 引用の外の行へ出られなかった（数式の TeX の欄と同じ負。`block-edges.ts` の `leaveBlock`）。
      const leave = (dir: -1 | 1) => {
        const pos = getPos();
        if (pos === undefined) return;
        const found = editor.view.state.doc.nodeAt(pos);
        if (!found) return;
        leaveBlock(editor.view, pos, found.nodeSize, dir);
      };
      const cite = noteInput("出典", "tt-quote-field tt-quote-cite", write, (dir) =>
        walkInputs([cite, citeUrl], 0, dir, leave)
      );
      const citeUrl = urlInput("出典の URL", "tt-quote-field tt-quote-cite-url", write, (dir) =>
        walkInputs([cite, citeUrl], 1, dir, leave)
      );
      fields.append(cite, citeUrl);
      const show = (open: boolean) => {
        fields.hidden = !open;
        add.hidden = open;
      };
      // 置きっぱなしの疑似行を先に消す（残すと、欄から矢印で出た先が 1 つずれる）。
      //
      // WhyNot: click で開かない。ボタンに焦点が移ると本文が blur し、`BlockEdges` が疑似行を
      // 消して doc が変わる。mouseup が来る前にこのボタンごと描き直され、click が発火しない
      // （矢印で引用の外へ出た後、「出典を追加」が 1 回目の押下で効かなかった）。
      // WhyNot: 焦点が入った後に疑似行を消さない。本文に焦点がある間に doc を変えると
      // ProseMirror が DOM の選択を貼り直し、欄から焦点を奪う。
      add.addEventListener("mousedown", (event) => {
        event.preventDefault();
        dropPendingLine(editor.view);
        show(true);
        cite.focus();
      });
      // 欄の間を渡る時は畳まない（relatedTarget が欄の中）。
      fields.addEventListener("focusout", (event) => {
        const to = (event as FocusEvent).relatedTarget as globalThis.Node | null;
        if (to && fields.contains(to)) return;
        if (cite.value.trim() === "" && citeUrl.value.trim() === "") show(false);
      });

      dom.append(quote, add, fields);

      const paint = (attrs: Record<string, unknown>) => {
        if (document.activeElement !== cite) cite.value = text(attrs, "cite");
        if (document.activeElement !== citeUrl) citeUrl.value = text(attrs, "citeUrl");
        citeUrl.classList.toggle("is-bad", !isHttpUrl(citeUrl.value.trim()));
        if (!fields.contains(document.activeElement)) show(cite.value !== "" || citeUrl.value !== "");
      };
      paint(node.attrs);

      return {
        dom,
        contentDOM: quote,
        update(updated: { type: { name: string }; attrs: Record<string, unknown> }) {
          if (updated.type.name !== "blockquote") return false;
          paint(updated.attrs);
          return true;
        },
        ignoreMutation(mutation: { type: string; target: globalThis.Node }) {
          return add.contains(mutation.target) || fields.contains(mutation.target);
        },
        stopEvent(event: Event) {
          const target = event.target as globalThis.Node;
          return add.contains(target) || fields.contains(target);
        },
      };
    };
  },
});
