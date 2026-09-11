// 埋め込み（embed）。attrs は `url` だけで、提供元は URL から毎回決める（`url-cards.ts`）。
//
// 編集画面では**提供元名と URL の薄い枠**。iframe は置かない（`link-card-node.ts` と同じ理由に加え、
// 編集中に動画のプレイヤーが動くとスクロールとキー操作を奪う）。

import { Node } from "@tiptap/core";
import { cardView, revertToUrl } from "./link-card-node";
import { providerOf } from "./url-cards";

export const EmbedNode = Node.create({
  name: "embed",
  group: "block",
  atom: true,
  draggable: true,
  selectable: true,

  addAttributes() {
    return { url: { default: null } };
  },

  parseHTML() {
    return [{ tag: "div[data-embed]", getAttrs: (element) => ({ url: (element as HTMLElement).getAttribute("data-url") }) }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["div", { "data-embed": "", "data-url": String(HTMLAttributes.url ?? "") }];
  },

  addNodeView() {
    return cardView("embed", "tt-embed", (url) => providerOf(url) ?? "埋め込み");
  },

  addKeyboardShortcuts() {
    return {
      Backspace: () => revertToUrl(this.editor, this.name),
      Delete: () => revertToUrl(this.editor, this.name),
    };
  },
});
