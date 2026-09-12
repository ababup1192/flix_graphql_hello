// 囲み（callout）。`attrs.kind` は note / tip / warning のどれか（`RichText.calloutKinds`）。
//
// WhyNot: 種別を文字列の欄にしない。CMS は 3 つしか受けず、打ち間違いはその場では分からず
// 保存の時に断られる。帯の 3 つのボタンなら外れた値を作れない。
//
// WhyNot: 種別を「+」の一覧で 3 行に割らない。一覧が 10 行を超えて探す物が沈むうえ、
// 入れた後に種別を変える道が別に要る。入れる口は 1 つで、切り替えは帯に置く。
//
// WhyNot: 引用（blockquote）に寄せない。中身が普通のブロックで見た目も近いが、
// CMS では別の node で、引用は出典を持ち callout は種別を持つ。

import { Node, mergeAttributes } from "@tiptap/core";
import { ICONS, svg } from "./icons";
import { bar, iconButton, owns } from "./ui";

const KINDS: Array<[string, string, string]> = [
  ["note", "ノート", ICONS.note],
  ["tip", "ヒント", ICONS.tip],
  ["warning", "警告", ICONS.warning],
];

const DEFAULT_KIND = "note";

/** doc に入れる時の形。中身が無いと `block+` を満たせない。 */
export const newCallout = () => ({
  type: "callout",
  attrs: { kind: DEFAULT_KIND },
  content: [{ type: "paragraph" }],
});

type ViewArgs = {
  node: any;
  getPos: () => number | undefined;
  editor: any;
};

export const CalloutNode = Node.create({
  name: "callout",
  group: "block",
  content: "block+",
  defining: true,

  addAttributes() {
    return {
      kind: {
        default: DEFAULT_KIND,
        parseHTML: (element: HTMLElement) => element.getAttribute("data-kind") ?? DEFAULT_KIND,
        // WhyNot: 既定の note を書かないで済ませない。CMS は kind を必須で見るので、
        // 属性ごと消えた callout は保存で断られる。
        renderHTML: (attributes: Record<string, unknown>) => ({ "data-kind": String(attributes.kind ?? DEFAULT_KIND) }),
      },
    };
  },

  parseHTML() {
    return [{ tag: "aside[data-kind]" }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["aside", mergeAttributes(HTMLAttributes), 0];
  },

  addNodeView() {
    return ({ node, getPos, editor }: ViewArgs) => {
      const dom = document.createElement("div");
      dom.className = "tt-callout";

      const setKind = (kind: string) => {
        const pos = getPos();
        if (pos === undefined) return;
        editor.view.dispatch(editor.view.state.tr.setNodeAttribute(pos, "kind", kind));
      };

      const buttons = KINDS.map(([kind, title, icon]) =>
        iconButton({
          className: "tt-callout-kind",
          icon: svg(icon),
          title,
          onClick: () => setKind(kind),
        }),
      );
      const tools = bar({ className: "tt-callout-bar", children: buttons });

      const body = document.createElement("aside");
      body.className = "tt-callout-body";
      dom.append(tools, body);

      const paint = (current: { attrs: Record<string, unknown> }) => {
        const kind = String(current.attrs.kind ?? DEFAULT_KIND);
        dom.setAttribute("data-kind", kind);
        body.setAttribute("data-kind", kind);
        buttons.forEach((button, index) => {
          const on = KINDS[index][0] === kind;
          button.setAttribute("aria-pressed", String(on));
          button.classList.toggle("is-on", on);
        });
      };
      paint(node);

      return {
        dom,
        contentDOM: body,
        update(updated: { type: { name: string }; attrs: Record<string, unknown> }) {
          if (updated.type.name !== "callout") return false;
          paint(updated);
          return true;
        },
        // WhyNot: 帯の中だけを見ない。**この node view 自身の class の書き換えも
        // ProseMirror から見れば「知らない DOM の変化」**で、node view ごと作り直され、
        // 中だけに持っている状態（畳んである / いない）が黙って戻る（実際に戻った）。
        // 中身（contentDOM）の外で起きた事はすべて node view の持ち物。
        ignoreMutation(mutation: { type: string; target: globalThis.Node }) {
          if (mutation.type === "selection") return false;
          return dom.contains(mutation.target) && !body.contains(mutation.target);
        },
        stopEvent(event: Event) {
          return owns([tools], event);
        },
      };
    };
  },
});
