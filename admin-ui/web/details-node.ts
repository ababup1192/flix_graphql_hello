// 折りたたみ（details）。`attrs.summary` は空でない文字列（`RichText.checkDetails`）。
//
// WhyNot: summary を子ノードにしない。CMS は属性で持つ（`<details><summary>…`）ので、
// 子にすると保存の形が合わない。引用の出典とはここだけ作りが違う。
//
// WhyNot: 畳んだ状態を doc に書かない。CMS は `attrs.summary` しか見ず、Markdown の往復でも
// 落ちる。保存すると開閉が失われる中途半端な物になるので、開閉は node view の中だけに持つ。
//
// WhyNot: 畳んだ中身をキャレットの行き先に残さない。`display: none` の中に選択が入ると、
// 見えない所で編集が進み、保存してから気付く。畳む時は中の選択を外へ出し、畳んでいる間に
// 入ってきた選択も外へ戻す（`closedPlugin`）。
//
// WhyNot: summary が空のまま doc に書かない。CMS の validate が断り、保存の時に初めて
// 分かる。空になった瞬間に既定の見出しへ戻し、**doc はいつ読んでも空でない**形にする。

import { Node, mergeAttributes } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { leaveBlock } from "./block-edges";
import { ICONS, svg } from "./icons";
import { bar, field, iconButton, owns } from "./ui";

const DEFAULT_SUMMARY = "詳細";
const PLACEHOLDER = "見出しを入力";

/** doc に入れる時の形。 */
export const newDetails = () => ({
  type: "details",
  attrs: { summary: DEFAULT_SUMMARY },
  content: [{ type: "paragraph" }],
});

/** 畳んである折りたたみ（`is-closed`）の中に選択があれば、その外へ出す。
 *
 * WhyNot: 開閉を state に持たない。開閉は node view の中だけの物で、doc にも plugin の
 * state にも無い。DOM の class が唯一の持ち主なので、そこを見る。 */
function closedPlugin() {
  return new Plugin({
    key: new PluginKey("detailsClosed"),
    view(view: any) {
      const push = () => {
        const { $from } = view.state.selection;
        for (let depth = $from.depth; depth > 0; depth -= 1) {
          const node = $from.node(depth);
          if (node.type.name !== "details") continue;
          const pos = $from.before(depth);
          const dom = view.nodeDOM(pos);
          if (dom instanceof HTMLElement && dom.classList.contains("is-closed")) leaveBlock(view, pos, node.nodeSize, 1);
          return;
        }
      };
      return { update: push };
    },
  });
}

type ViewArgs = {
  node: any;
  getPos: () => number | undefined;
  editor: any;
};

export const DetailsNode = Node.create({
  name: "details",
  group: "block",
  content: "block+",
  defining: true,

  addAttributes() {
    return {
      summary: {
        default: DEFAULT_SUMMARY,
        parseHTML: (element: HTMLElement) => element.querySelector("summary")?.textContent || DEFAULT_SUMMARY,
        renderHTML: () => ({}),
      },
    };
  },

  parseHTML() {
    return [{ tag: "details" }];
  },

  renderHTML({ node, HTMLAttributes }) {
    return ["details", mergeAttributes(HTMLAttributes, { open: "" }), ["summary", {}, String(node.attrs.summary ?? DEFAULT_SUMMARY)], ["div", {}, 0]];
  },

  addProseMirrorPlugins() {
    return [closedPlugin()];
  },

  addNodeView() {
    return ({ node, getPos, editor }: ViewArgs) => {
      const dom = document.createElement("div");
      dom.className = "tt-details";

      const write = (value: string) => {
        const pos = getPos();
        if (pos === undefined) return;
        const state = editor.view.state;
        if (String(state.doc.nodeAt(pos)?.attrs?.summary ?? "") === value) return;
        editor.view.dispatch(state.tr.setNodeAttribute(pos, "summary", value));
      };

      // 畳んである間だけ true。**doc には出さない。**
      let closed = false;

      // 中に選択があるなら外へ出してから畳む（畳んだ後では中の位置が測れない）。
      const leaveIfInside = () => {
        const pos = getPos();
        if (pos === undefined) return;
        const state = editor.view.state;
        const node = state.doc.nodeAt(pos);
        if (!node) return;
        const { from } = state.selection;
        if (from <= pos || from >= pos + node.nodeSize) return;
        leaveBlock(editor.view, pos, node.nodeSize, 1);
      };

      const mark = iconButton({
        className: "tt-details-toggle",
        icon: svg(ICONS.details),
        title: "閉じる",
        pressed: true,
        onClick: () => {
          if (!closed) leaveIfInside();
          closed = !closed;
          paintOpen();
        },
      });
      const paintOpen = () => {
        dom.classList.toggle("is-closed", closed);
        mark.setAttribute("aria-pressed", String(!closed));
        // 押すとどうなるかをラベルにする（読み上げも title も同じ物を見る）。
        mark.title = closed ? "開く" : "閉じる";
        mark.setAttribute("aria-label", mark.title);
      };

      const input = field({
        className: "tt-details-summary",
        placeholder: PLACEHOLDER,
        label: "折りたたみの見出し",
        value: String(node.attrs.summary ?? DEFAULT_SUMMARY),
        // 打っている間の空は、欄の中だけの空にする（doc には既定の見出しを入れておく）。
        onInput: (value) => write(value.trim() === "" ? DEFAULT_SUMMARY : value),
        // 離れた時は欄も doc に揃える（空のまま残すと、次に開いた時に食い違う）。
        onCommit: (value) => {
          if (value.trim() !== "") return;
          input.value = DEFAULT_SUMMARY;
          write(DEFAULT_SUMMARY);
        },
        onLeave: (dir) => {
          const pos = getPos();
          if (pos === undefined) return;
          const size = editor.view.state.doc.nodeAt(pos)?.nodeSize ?? 1;
          leaveBlock(editor.view, pos, size, dir);
        },
      });

      const tools = bar({ className: "tt-details-bar", children: [mark, input] });
      paintOpen();

      const body = document.createElement("div");
      body.className = "tt-details-body";
      dom.append(tools, body);

      const paint = (current: { attrs: Record<string, unknown> }) => {
        const summary = String(current.attrs.summary ?? DEFAULT_SUMMARY);
        // WhyNot: 打っている最中に書き戻さない。1 文字ごとの往復が欄の中身を追い越し、
        // キャレットが末尾へ飛ぶ（コードのファイル名で実際に飛んだ）。
        if (document.activeElement === input) return;
        if (input.value !== summary) input.value = summary;
      };
      paint(node);

      return {
        dom,
        contentDOM: body,
        update(updated: { type: { name: string }; attrs: Record<string, unknown> }) {
          if (updated.type.name !== "details") return false;
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
