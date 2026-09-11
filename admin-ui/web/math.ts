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
import type { Editor } from "@tiptap/core";
import { NodeSelection, Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import katex from "katex";
import { dropPendingLine, leaveBlock } from "./block-edges";
import { ICONS, svg } from "./icons";
import { bar as barOf, iconButton, isSelectAll } from "./ui";

// 帯のアイコンの大きさ（画像・リンクカードの帯と同じ）。
const BAR_ICON = 22;
// ホバーで右上に出る削除のアイコンの大きさ（28px の面に 16px）。
const CORNER_ICON = 16;
// TeX の欄の最低の行数。
const MIN_ROWS = 2;

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

// 普段は TeX の欄を隠しているので、外から「開いて焦点を入れる」を呼べるようにする。
//
// WhyNot: `dom.querySelector(".tt-mathblock-src").focus()` だけで済ませない。隠れた要素には
// 焦点が入らない。node view の中の開く手続きを引いてから呼ぶ。
const openers = new WeakMap<HTMLElement, () => void>();

/** mathBlock を消して、その場所に空の段落を残しカーソルを置く。 */
function removeMathAt(editor: Editor, pos: number) {
  const { state } = editor.view;
  const found = state.doc.nodeAt(pos);
  if (!found || found.type.name !== "mathBlock") return;
  const tr = state.tr.replaceWith(pos, pos + found.nodeSize, state.schema.nodes.paragraph.create());
  tr.setSelection(TextSelection.create(tr.doc, pos + 1));
  editor.view.dispatch(tr);
  editor.view.focus();
}

/** 入れた直後に、その mathBlock の TeX の欄へ焦点を移す。
 *
 * WhyNot: ProseMirror の選択は動かさない。node を選ぶ選択に変えると editable に焦点が戻り、
 * 打った字が node を置き換える。DOM の焦点だけ textarea に渡す（`stopEvent` が鍵を食べる）。
 */
function focusMathSource(editor: Editor, near: number) {
  // node view は dispatch の後の描画で作られるので、1 つ後の回に回す。
  window.setTimeout(() => {
    // WhyNot: 入れる前に数えた位置をそのまま使わない。段落を node で置き換えると深さが変わり、
    // node の頭は打った所と 1 ずれる。入れた辺りにある mathBlock を拾う。
    let at = -1;
    editor.state.doc.descendants((node, pos) => {
      if (node.type.name !== "mathBlock") return;
      if (at < 0 || Math.abs(pos - near) < Math.abs(at - near)) at = pos;
    });
    if (at < 0) return;
    const dom = editor.view.nodeDOM(at);
    if (!(dom instanceof HTMLElement)) return;
    openers.get(dom)?.();
  }, 0);
}

/** TeX の欄のカーソルが、もう上（-1）下（1）へ行けない行にいるか。
 *
 * WhyNot: 画面の折り返しで数えない。TeX は 1 行が短く、折り返しの見えている行と
 * 改行で区切った行がずれるのは書いている本人にも分からない。改行で数える。
 */
function atEdgeLine(source: HTMLTextAreaElement, dir: -1 | 1): boolean {
  const { selectionStart, selectionEnd, value } = source;
  if (selectionStart !== selectionEnd) return false;
  return dir < 0
    ? !value.slice(0, selectionStart).includes("\n")
    : !value.slice(selectionEnd).includes("\n");
}

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
  //
  // WhyNot: `nodeInputRule` をそのまま使わない。入れた後の選択は node の**次**に置かれ、
  // TeX の欄は node view の中の textarea なので焦点が入らない（打った字が下の段落に流れる）。
  addInputRules() {
    const editor = this.editor;
    const rule = nodeInputRule({ find: /^\$\$[\s\n]$/, type: this.type });
    // WhyNot: 入れ方まで書き直さない。段落を node に替える所は TipTap の物をそのまま使い、
    // 焦点を移す分だけ足す。
    const insert = rule.handler.bind(rule);
    rule.handler = (props) => {
      insert(props);
      focusMathSource(editor, props.range.from);
    };
    return [rule];
  },
  // **普段は組版だけ。箱のどこを押しても下に TeX の欄が開く**（Notion / Craft と同じ 3 状態。
  // `docs/design/richtext-math-ui.md`）。打っている間ずっと組版を描き直す。
  // 消すのはホバーで右上に出る削除から。
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "tt-mathblock";

      const remove = () => {
        const pos = getPos();
        if (pos !== undefined) removeMathAt(editor, pos);
      };

      // 選んだ時だけ上に浮く、削除だけの帯（画像・リンクカードと同じ部品）。
      const trash = iconButton({
        className: "tt-image-tool tt-image-icon",
        icon: svg(ICONS.trash, BAR_ICON),
        title: "削除",
        onClick: remove,
      });
      const bar = barOf({ className: "tt-image-bar", children: [trash] });
      bar.hidden = true;

      // ホバーの間だけ右上に出る削除（案 B）。選ばなくても消せる。
      const corner = iconButton({
        className: "tt-block-corner",
        icon: svg(ICONS.trash, CORNER_ICON),
        title: "削除",
        onClick: remove,
      });
      corner.hidden = !editor.isEditable;

      const shown = document.createElement("div");
      shown.className = "tt-mathblock-out";

      const source = document.createElement("textarea");
      source.className = "tt-mathblock-src";
      source.placeholder = "TeX で書く（例: E = mc^2）";
      source.rows = MIN_ROWS;
      source.hidden = true;
      source.value = String(node.attrs.tex ?? "");

      dom.append(bar, corner, shown, source);

      // 掴んで伸ばす代わりに、中身の行数に合わせて自分で伸びる（枠からはみ出さない）。
      const fit = () => {
        // WhyNot: 隠れている間に測らない。`display: none` の欄は高さが全部 0 で返るので、
        // 最低の行数まで縮んだ欄が開く。
        if (source.hidden) return;
        source.style.height = "auto";
        const style = window.getComputedStyle(source);
        const line = Number.parseFloat(style.lineHeight) || 19;
        // 欄は border-box なので、付ける高さには上下の padding と枠線も入れる。
        const pads = Number.parseFloat(style.paddingTop) + Number.parseFloat(style.paddingBottom);
        const border = source.offsetHeight - source.clientHeight;
        const least = Math.round(line * MIN_ROWS) + pads;
        source.style.height = `${Math.ceil(Math.max(source.scrollHeight, least)) + border}px`;
        // WhyNot: `scrollHeight` を信じきらない。下の padding を数えない実装があり、
        // 最後の行の下半分だけが切れる。付けた後に残っている溢れを足して閉じる。
        const over = source.scrollHeight - source.clientHeight;
        if (over > 0) source.style.height = `${source.offsetHeight + over}px`;
      };

      const paint = (tex: string) => {
        shown.classList.remove("is-bad");
        shown.classList.toggle("is-empty", tex.trim() === "");
        if (tex.trim() === "") {
          shown.textContent = "数式を入力";
          return;
        }
        render(shown, tex, true);
      };
      paint(source.value);

      const open = () => {
        // 置きっぱなしの疑似行を先に消す（残すと、欄から矢印で出た先が 1 つずれる）。
        dropPendingLine(editor.view);
        source.hidden = false;
        fit();
        source.focus();
      };
      const close = () => {
        source.hidden = true;
      };
      openers.set(dom, open);

      // 箱のどこを押しても TeX の欄へ入る（組版の上・余白・枠のどれでも同じ）。
      // WhyNot: ProseMirror に任せない。`stopEvent` で鍵を食べている node の上では近い位置を
      // 推測してカーソルが別の行に当たる。
      // WhyNot: `shown` だけに付けない。当たり判定が組版の字の面だけになり、押す場所で
      // 「編集」と「選択」が入れ替わる（ユーザーの指摘）。
      dom.addEventListener("mousedown", (event) => {
        if (!editor.isEditable) return;
        // 帯の道具と掴みは自分の動きを持つ。欄そのものはカーソルを置く所なので邪魔しない。
        const target = event.target;
        if (target instanceof Element && target.closest(".tt-image-bar, .tt-block-corner, .tt-mathblock-src")) return;
        event.preventDefault();
        open();
      });

      // ホバーしている間だけ右上に出る削除。押す口を「押す = 編集」に一本化した代わりに、
      // 選ばずに消せる口をここに置く（`docs/design/richtext-math-ui.md` の案 B）。
      // 箱の mousedown（押す = TeX の欄を開く）まで上らせない。
      corner.addEventListener("mousedown", (event) => event.stopPropagation());
      dom.addEventListener("pointerenter", () => {
        corner.hidden = !editor.isEditable;
      });

      source.addEventListener("blur", () => {
        close();
      });

      source.addEventListener("keydown", (event) => {
        // 全選択は欄の中だけ（ブラウザの既定に任せ、本文へは伝えない）。
        if (isSelectAll(event)) {
          event.stopPropagation();
          return;
        }
        const pos = getPos();
        if (event.key === "Escape") {
          event.preventDefault();
          close();
          if (pos === undefined) return;
          const tr = editor.view.state.tr;
          tr.setSelection(NodeSelection.create(tr.doc, pos));
          editor.view.dispatch(tr);
          editor.view.focus();
          return;
        }
        // 1 行目の ↑ と最終行の ↓ で欄を閉じ、前後の行へ出る（無ければ疑似行を置く）。
        //
        // WhyNot: `stopEvent` に任せない。node view が鍵を全部食べるので、上下の矢印が
        // `BlockEdges` に届かず、TeX を打っている間は前後の行へ移れなかった（画像の
        // 代替テキストと同じ負。`block-edges.ts` の `leaveBlock`）。
        if ((event.key === "ArrowUp" || event.key === "ArrowDown") && !event.shiftKey) {
          const dir = event.key === "ArrowUp" ? -1 : 1;
          if (atEdgeLine(source, dir) && pos !== undefined) {
            const found = editor.view.state.doc.nodeAt(pos);
            if (found) {
              event.preventDefault();
              close();
              leaveBlock(editor.view, pos, found.nodeSize, dir);
              return;
            }
          }
        }
        // 空の欄の Backspace は node ごと消して段落に戻す（中に文字がある時は 1 字消す）。
        if (event.key === "Backspace" && source.value === "") {
          event.preventDefault();
          if (pos !== undefined) removeMathAt(editor, pos);
        }
      });

      source.addEventListener("input", () => {
        fit();
        paint(source.value);
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
            // 外から入った TeX でも行数に高さを合わせる（合わせ直さないと最後の行が切れる）。
            fit();
            paint(tex);
          }
          return true;
        },
        ignoreMutation() {
          return true;
        },
        stopEvent() {
          return true;
        },
        selectNode() {
          dom.classList.add("ProseMirror-selectednode");
          bar.hidden = false;
          close();
        },
        deselectNode() {
          dom.classList.remove("ProseMirror-selectednode");
          bar.hidden = true;
        },
        destroy() {
          openers.delete(dom);
        },
      };
    };
  },
  // 選んだ状態からの Esc は本文へ戻す（欄の中の Esc は node view が受ける）。
  addKeyboardShortcuts() {
    const name = this.name;
    return {
      Escape: () => {
        const { selection } = this.editor.state;
        if (!(selection instanceof NodeSelection) || selection.node.type.name !== name) return false;
        return this.editor.commands.setTextSelection(selection.to);
      },
    };
  },
});
