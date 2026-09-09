// ブロックとブロックの間にカーソルを置く。
//
// **表・コードブロック・見出し・リストが本文の先頭にあると、その上に行けない。**
// Enter は行の中でしか効かず、先頭のブロックの上には届かない。コードブロックに至っては
// Enter がコードの改行になるので、上に段落を作る道が無い。
//
// ここで足す物:
//   - ブロックの間の余白を押す → そこにカーソル
//   - 先頭のブロックの頭で ArrowUp / 末尾の尻で ArrowDown → その外へ
//   - 区切り線や画像のような、中に入れないブロックを矢印で越える時 → その手前・その先へ
//   - 先頭の空行で Backspace → その行を消して、次の行の頭へ
//
// **置くのは疑似行。** 空の段落を 1 つ入れてそこに入り、打たずに離れたら消える。
// 本文にも取り消しの履歴にも残さず、`docchange` も出さない（触っていないのに
// 「未保存」にならない）。カーソルの置き場であって、書いた物ではない。
//
// WhyNot: TipTap が持つギャップカーソル（prosemirror-gapcursor）を使わない。
// **立つのが「中に文章を持たないブロック」の前後だけ**で、表・リスト・引用・
// コードブロック・見出し・段落の前後では ProseMirror が「そこは無効」と答える。
// 置ける所と置けない所ができるのが、そもそもの負。
//
// WhyNot: ギャップカーソルと疑似行を場所によって使い分けない。**見た目が違う。**
// ギャップカーソルは横一本の線なので、区切り線の上に立つと区切り線と見分けが付かない
// （実際に付かなかった）。全部を疑似行に揃える。

import { Extension } from "@tiptap/core";
import type { Node as PmNode } from "@tiptap/pm/model";
import type { EditorState, Transaction } from "@tiptap/pm/state";
import { NodeSelection, Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import type { EditorView } from "@tiptap/pm/view";

type Pending = { pos: number | null };

const key = new PluginKey<Pending>("blockEdges");

/** 疑似行が今あるか。エディタ本体が `docchange` を出すかの判断に使う。 */
export function hasPendingLine(state: EditorState): boolean {
  return key.getState(state)?.pos != null;
}

function pendingLine(state: EditorState): { pos: number; size: number; empty: boolean } | null {
  const pos = key.getState(state)?.pos;
  if (pos == null) return null;
  const node = state.doc.nodeAt(pos);
  if (!node || node.type.name !== "paragraph") return null;
  return { pos, size: node.nodeSize, empty: node.content.size === 0 };
}

function clear(state: EditorState): Transaction {
  return state.tr.setMeta(key, { pos: null } satisfies Pending);
}

// 疑似行から出た。空のままなら消す。
function dropPending(state: EditorState): Transaction | null {
  const line = pendingLine(state);
  if (!line) return key.getState(state)?.pos == null ? null : clear(state);
  if (!line.empty) return clear(state);
  if (state.selection.from >= line.pos && state.selection.to <= line.pos + line.size) return null;
  return state.tr
    .delete(line.pos, line.pos + line.size)
    .setMeta(key, { pos: null } satisfies Pending)
    .setMeta("addToHistory", false);
}

// 既にそこにある空の段落。**あればそれに入る**（押す度に空行が増えない）。
function reuse(doc: PmNode, at: number): number | null {
  const $at = doc.resolve(at);
  const after = $at.nodeAfter;
  if (after && after.type.name === "paragraph" && after.content.size === 0) return at + 1;
  const before = $at.nodeBefore;
  if (before && before.type.name === "paragraph" && before.content.size === 0) return at - 1;
  return null;
}

function place(view: EditorView, at: number): boolean {
  const state = view.state;
  const paragraph = state.schema.nodes.paragraph;
  if (!paragraph) return false;

  const tr = state.tr;
  let target = at;

  // **先に、前に置いた疑似行を消す。** 消さずに次を置くと、跨いだ後ろに空行が残る
  // （矢印で区切り線を越えるだけで空行が 1 つずつ増えた）。
  const line = pendingLine(state);
  if (line && line.empty) {
    tr.delete(line.pos, line.pos + line.size);
    if (line.pos < target) target -= line.size;
  }

  const spot = reuse(tr.doc, target);
  if (spot !== null) {
    tr.setSelection(TextSelection.create(tr.doc, spot));
    tr.setMeta(key, { pos: null } satisfies Pending);
  } else {
    tr.insert(target, paragraph.create());
    tr.setSelection(TextSelection.create(tr.doc, target + 1));
    tr.setMeta(key, { pos: target } satisfies Pending);
  }
  tr.setMeta("addToHistory", false);
  view.dispatch(tr.scrollIntoView());
  view.focus();
  return true;
}

// 一番外側のブロックそれぞれの、画面での上端と下端。
function bands(view: EditorView): { top: number; bottom: number; after: number }[] {
  const out: { top: number; bottom: number; after: number }[] = [];
  const doc = view.state.doc;
  let pos = 0;
  for (let index = 0; index < doc.childCount; index += 1) {
    const node = doc.child(index);
    const dom = view.nodeDOM(pos) as HTMLElement | null;
    const box = dom?.getBoundingClientRect?.();
    if (box) out.push({ top: box.top, bottom: box.bottom, after: pos + node.nodeSize });
    pos += node.nodeSize;
  }
  return out;
}

// 押した所が、どのブロックの上でも無い（間か、上下の余白）なら、その位置。
// **左右の余白では返さない**（行の横を押しただけで行が増える）。
function boundaryOfClick(view: EditorView, event: MouseEvent): number | null {
  const box = (view.dom as HTMLElement).getBoundingClientRect();
  if (event.clientX < box.left || event.clientX > box.right) return null;
  const rows = bands(view);
  if (rows.length === 0) return null;
  const y = event.clientY;
  if (y < rows[0].top) return 0;
  if (y > rows[rows.length - 1].bottom) return view.state.doc.content.size;
  for (let index = 0; index < rows.length - 1; index += 1) {
    if (y > rows[index].bottom && y < rows[index + 1].top) return rows[index].after;
  }
  return null;
}

// 先頭の空行で Backspace。**その行を消して、次の行の頭へ。**
//
// 先頭には手前が無いので、ProseMirror の Backspace（`joinBackward`）は何もしない。
// 上に付いた空行を消す道が無く、選んで消すしかなかった（実際に消せなかった）。
function eatFirstEmptyLine(view: EditorView): boolean {
  const state = view.state;
  const selection = state.selection;
  if (!selection.empty || !(selection instanceof TextSelection)) return false;

  const $from = selection.$from;
  // 一番外側の行の、先頭の行の、頭にいるか。
  if ($from.depth !== 1 || $from.before(1) !== 0 || $from.parentOffset !== 0) return false;

  const first = $from.parent;
  if (first.type.name !== "paragraph" || first.content.size !== 0) return false;
  // **最後の 1 行は消さない**（本文がノードを 1 つも持たない形は作れない）。
  if (state.doc.childCount < 2) return false;

  const tr = state.tr.delete(0, first.nodeSize);
  tr.setSelection(TextSelection.near(tr.doc.resolve(0), 1));
  tr.setMeta(key, { pos: null } satisfies Pending);
  view.dispatch(tr.scrollIntoView());
  return true;
}

// 中に入れないブロック（区切り線・画像・埋め込み・数式）。
// **中に入れる物（表・リスト・引用）は素の動きに任せる。** 矢印で中へ入るのが自然で、
// ここで止めると表に入れなくなる。
function isSolid(node: PmNode | null | undefined): boolean {
  return !!node && (node.isAtom || node.isLeaf);
}

export const BlockEdges = Extension.create({
  name: "blockEdges",

  addProseMirrorPlugins() {
    return [
      new Plugin({
        key,

        state: {
          init: (): Pending => ({ pos: null }),
          apply: (tr, value): Pending => {
            const set = tr.getMeta(key) as Pending | undefined;
            if (set) return set;
            if (value.pos == null || !tr.docChanged) return value;
            return { pos: tr.mapping.map(value.pos, -1) };
          },
        },

        appendTransaction: (_trs, _old, next) => dropPending(next) ?? undefined,

        props: {
          handleDOMEvents: {
            mousedown(view, event) {
              const at = boundaryOfClick(view, event as MouseEvent);
              if (at === null) return false;
              event.preventDefault();
              return place(view, at);
            },

            // 欄から離れた時も消す。**選択が動かないので appendTransaction では拾えない。**
            blur(view) {
              const line = pendingLine(view.state);
              if (!line) return false;
              view.dispatch(
                line.empty
                  ? view.state.tr
                      .delete(line.pos, line.pos + line.size)
                      .setMeta(key, { pos: null } satisfies Pending)
                      .setMeta("addToHistory", false)
                  : clear(view.state)
              );
              return false;
            },
          },

          handleKeyDown(view, event) {
            if (event.key === "Backspace") return eatFirstEmptyLine(view);

            const up = event.key === "ArrowUp";
            const down = event.key === "ArrowDown";
            if (!up && !down) return false;
            if (event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) return false;

            const selection = view.state.selection;

            // ブロックそのものを選んでいる時（区切り線や画像を押した後）。
            // **ここで素の動きに任せると、次に打った文字がそのブロックを置き換える**
            // （区切り線が文字に化ける）。
            if (selection instanceof NodeSelection && selection.$from.depth === 0) {
              return place(view, up ? selection.from : selection.to);
            }

            if (!selection.empty || !(selection instanceof TextSelection)) return false;

            const $from = selection.$from;
            if ($from.depth === 0) return false;
            // その行の中で、もう上（下）に行けない所にいるか。
            if ($from.parentOffset !== (up ? 0 : $from.parent.content.size)) return false;
            if (!view.endOfTextblock(up ? "up" : "down")) return false;

            const doc = view.state.doc;
            const at = up ? $from.before(1) : $from.after(1);
            if (at === (up ? 0 : doc.content.size)) return place(view, at);

            const $at = doc.resolve(at);
            const solid = up ? $at.nodeBefore : $at.nodeAfter;
            if (!isSolid(solid) || !solid) return false;

            // **既にその境目の空行にいるなら、区切り線などを跨いで向こう側へ。**
            // 跨がないと、同じ空行に戻され続けて区切り線の手前で止まる（実際に止まった）。
            const here = $from.node(1);
            const stuck = here.type.name === "paragraph" && here.content.size === 0;
            const target = stuck ? (up ? at - solid.nodeSize : at + solid.nodeSize) : at;
            if (target < 0 || target > doc.content.size) return false;
            return place(view, target);
          },
        },
      }),
    ];
  },
});
