// 数式。CMS は既に 2 つの形を受ける（`RichText.flix`）。
//
//   - 文の中: `text` に `math` の mark。**mark は 1 つだけ**（太字と重ねると INVALID）
//   - 段落として: `mathBlock` の node に `attrs.tex`
//
// **入力は TeX を直に打つ。** 調べた 15 例で GUI のパレットを持つ物は 1 つも無かった。
// 代わりに、書いている間ずっと描画を見せる（Craft と同じ）。
//
// 文の中の数式は**カーソルが乗った時だけ TeX に戻る**（Notion / Craft と同じ）。

import { Mark, Node, markInputRule, mergeAttributes, nodeInputRule } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import katex from "katex";

// KaTeX は投げる事がある（書きかけの TeX は当たり前に壊れている）。
// **壊れていても書けなくしない。** 赤字で出すだけ。
function render(target: HTMLElement, tex: string, display: boolean) {
  try {
    katex.render(tex, target, { displayMode: display, throwOnError: false, output: "html" });
  } catch {
    target.textContent = tex;
    target.classList.add("is-bad");
  }
}

export const MathMark = Mark.create({
  name: "math",
  // 他の飾りと重ねられない（CMS が mark を 1 つしか許さない）。
  excludes: "_",
  parseHTML() {
    return [{ tag: "span[data-math='inline']" }];
  },
  renderHTML({ HTMLAttributes }) {
    return ["span", mergeAttributes(HTMLAttributes, { "data-math": "inline" }), 0];
  },
  // `$…$` で数式にする。Zenn・GitHub・esa・Craft が全部この記法なので、指が覚えている。
  addInputRules() {
    return [markInputRule({ find: /(?:^|[^$])\$([^$]+)\$$/, type: this.type })];
  },
  addProseMirrorPlugins() {
    const type = this.type;
    return [
      new Plugin({
        key: new PluginKey("mathInline"),
        props: {
          decorations(state) {
            const found: Decoration[] = [];
            const { from, to } = state.selection;
            state.doc.descendants((node, pos) => {
              if (!node.isText || !type.isInSet(node.marks)) return;
              const start = pos;
              const end = pos + node.nodeSize;
              // **カーソルが乗っている間は TeX のまま**（直せなくなる）。
              if (from <= end && to >= start) return;
              const tex = node.text ?? "";
              found.push(Decoration.inline(start, end, { class: "tt-math-src" }));
              found.push(
                Decoration.widget(end, () => {
                  const span = document.createElement("span");
                  span.className = "tt-math";
                  render(span, tex, false);
                  return span;
                })
              );
            });
            return DecorationSet.create(state.doc, found);
          },
        },
      }),
    ];
  },
});

export const MathBlock = Node.create({
  name: "mathBlock",
  group: "block",
  atom: true,
  addAttributes() {
    return { tex: { default: "" } };
  },
  parseHTML() {
    return [{ tag: "div[data-math='block']" }];
  },
  renderHTML({ HTMLAttributes }) {
    return ["div", mergeAttributes(HTMLAttributes, { "data-math": "block" })];
  },
  // `$$` + Enter で段落の数式にする。
  addInputRules() {
    return [nodeInputRule({ find: /^\$\$[\s\n]$/, type: this.type })];
  },
  // **上に描画、下に TeX**（Craft と同じ並び）。打っている間ずっと更新する。
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "tt-mathblock";

      const shown = document.createElement("div");
      shown.className = "tt-mathblock-out";

      const source = document.createElement("textarea");
      source.className = "tt-mathblock-src";
      source.placeholder = "TeX で書く（例: E = mc^2）";
      source.rows = 2;
      source.value = String(node.attrs.tex ?? "");

      dom.append(shown, source);
      render(shown, source.value, true);

      source.addEventListener("input", () => {
        shown.classList.remove("is-bad");
        render(shown, source.value, true);
        const pos = getPos();
        if (pos === undefined) return;
        const found = editor.view.state.doc.nodeAt(pos);
        if (!found) return;
        editor.view.dispatch(
          editor.view.state.tr.setNodeMarkup(pos, undefined, { ...found.attrs, tex: source.value })
        );
      });

      return {
        dom,
        update(updated) {
          if (updated.type.name !== "mathBlock") return false;
          const tex = String(updated.attrs.tex ?? "");
          if (document.activeElement !== source) {
            source.value = tex;
            shown.classList.remove("is-bad");
            render(shown, tex, true);
          }
          return true;
        },
        ignoreMutation() {
          return true;
        },
        stopEvent() {
          return true;
        },
      };
    };
  },
});
