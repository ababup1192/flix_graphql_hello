// 上付き・下付き・蛍光ペン。
//
// **どれも中身であって飾りではない。** H₂O・m²・™ は書いた人が意味を決めた物で、
// 蛍光ペンは「ここが大事」という役割。だから HTML の要素（sub / sup / mark）で出す。
//
// WhyNot: 文字色と文字サイズは入れない。ヘッドレス CMS の役割は中身で、見た目はサイトが決める。
// 本文に色や大きさを埋めると、サイトのデザインより本文が強くなり、リニューアルと
// 暗いテーマで壊れる。Contentful / Sanity / Strapi も持っていない。
//
// WhyNot: @tiptap/extension-subscript などを入れない。**この 3 つは中身が数行**で、
// 依存を 3 つ増やすほどの物ではない。

import { InputRule, Mark, mergeAttributes } from "@tiptap/core";

type Spec = { name: string; tag: string; sign: string; excludes?: string };

// WhyNot: 上付きと下付きを重ねられるようにしない。**片方の中にもう片方は無い。**
// 重ねると `<sub><sup>a</sup></sub>` になり、Markdown（`~a~` と `^a^`）にも HTML にも
// 意味の無い形で残る。後に押した方が前の物を外す。
const SPECS: Spec[] = [
  { name: "sub", tag: "sub", sign: "~", excludes: "sub sup" },
  { name: "sup", tag: "sup", sign: "^", excludes: "sub sup" },
  { name: "highlight", tag: "mark", sign: "==" },
];

//
// `~x~` `^x^` `==x==`。CMS の Markdown 方言と同じ書き方。
//
// WhyNot: TipTap の `markInputRule` を使わない。**前の 1 文字を巻き込んで消す**ので、
// `H~2~O` の `H` が落ちる（実際に落ちた）。下付き・上付きは語にくっ付けて書く物なので、
// 前を空白に限る形も取れない。記号だけを消して、中の文字に印を付ける。
//
function ruleOf(sign: string) {
  const escaped = sign.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const inner = sign.length === 1 ? escaped : escaped[1];
  return new RegExp(`${escaped}([^${inner}\\s][^${inner}]*)${escaped}$`);
}

function markOf(spec: Spec) {
  return Mark.create({
    name: spec.name,
    excludes: spec.excludes,

    parseHTML() {
      return [{ tag: spec.tag }];
    },

    renderHTML({ HTMLAttributes }) {
      return [spec.tag, mergeAttributes(HTMLAttributes), 0];
    },

    addInputRules() {
      const name = spec.name;
      return [
        new InputRule({
          find: ruleOf(spec.sign),
          handler: ({ range, match, chain }) => {
            chain()
              .deleteRange(range)
              .insertContent({ type: "text", text: match[1], marks: [{ type: name }] })
              .unsetMark(name)
              .run();
          },
        }),
      ];
    },
  });
}

export const Subscript = markOf(SPECS[0]);
export const Superscript = markOf(SPECS[1]);
export const Highlight = markOf(SPECS[2]);

// 上付き・下付きの点滅カーソル。
//
// **押した瞬間に、打つ大きさのカーソルになる。** 印を付けただけでは本文が変わらないので、
// カーソルは今いる文字の大きさのまま（付けても小さくならず、外しても小さいまま）。
// 打つ位置に幅ゼロの目印を置き、それを付ける印で包む。カーソルはその中に立つ。
//
// WhyNot: ProseMirror の markCursor に任せない。**変換中（composition）にしか動かない**
// （`compositionstart` でだけ立てて、すぐ null に戻している）。ボタンで印を変えた時は通らない。
//
// WhyNot: 上付き・下付き以外には出さない。太字や色ではカーソルの見た目が変わらないので、
// 目印を置くだけ無駄で、DOM を余計に動かす。

import { Extension } from "@tiptap/core";
import { Mark as PmMark } from "@tiptap/pm/model";
import { Plugin, TextSelection } from "@tiptap/pm/state";
import type { EditorState } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";

type Observer = { disconnectSelection?: () => void; connectSelection?: () => void; setCurSelection?: () => void };

const RAISED = new Set(["sub", "sup"]);

// 目印を置くべき印。**打つ印と、今いる場所の印が食い違っている時だけ。**
function caretMarks(state: EditorState): readonly PmMark[] | null {
  const selection = state.selection;
  if (!(selection instanceof TextSelection) || !selection.empty) return null;
  const stored = state.storedMarks;
  if (!stored) return null;
  const here = selection.$head.marks();
  if (PmMark.sameSet(stored, here)) return null;
  const raised = (mark: PmMark) => RAISED.has(mark.type.name);
  if (!stored.some(raised) && !here.some(raised)) return null;
  return stored;
}

function caretPlugin() {
  let held: { marks: readonly PmMark[]; dom: HTMLImageElement } | null = null;

  const widget = (marks: readonly PmMark[]) => {
    if (held && PmMark.sameSet(held.marks, marks)) return held.dom;
    const dom = document.createElement("img");
    // ProseMirror が幅ゼロの目印に使っている class。`display: inline` の CSS が付いている。
    dom.className = "ProseMirror-separator";
    dom.setAttribute("alt", "");
    held = { marks, dom };
    return dom;
  };

  return new Plugin({
    props: {
      decorations(state) {
        const marks = caretMarks(state);
        if (!marks) {
          held = null;
          return null;
        }
        return DecorationSet.create(state.doc, [
          Decoration.widget(state.selection.from, widget(marks), { raw: true, marks, side: 0 }),
        ]);
      },
    },

    // 目印を描いただけでは、ブラウザのカーソルはそこに入らない。**目印の直後に置き直す。**
    view() {
      return {
        update(view) {
          const dom = held?.dom;
          const parent = dom?.parentNode;
          if (!dom || !parent || !view.hasFocus()) return;
          const at = Array.prototype.indexOf.call(parent.childNodes, dom) + 1;
          const selection = (view.root as Document).getSelection?.() ?? window.getSelection();
          if (!selection) return;
          if (selection.anchorNode === parent && selection.anchorOffset === at) return;

          // **見張りを外してから置く。** ProseMirror は DOM の選択が動くのを見張っていて、
          // 自分が知っている位置（下付きの文字の中）へ戻す。置いた直後に戻された
          // （実際に戻された）。ProseMirror 自身も、変換入力の目印を置く時に同じ事をしている。
          const watch = (view as unknown as { domObserver: Observer }).domObserver;
          watch?.disconnectSelection?.();
          selection.collapse(parent, at);
          watch?.setCurSelection?.();
          watch?.connectSelection?.();
        },
      };
    },
  });
}

/** 上付き・下付きの点滅カーソルを、打つ大きさに合わせる。 */
export const RaisedCaret = Extension.create({
  name: "raisedCaret",
  addProseMirrorPlugins() {
    return [caretPlugin()];
  },
});
