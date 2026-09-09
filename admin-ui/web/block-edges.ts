// ブロックの上と下にカーソルを置く。
//
// **表・コードブロック・見出し・リストが本文の先頭にあると、その上に行けない。**
// Enter は行の中でしか効かず、先頭のブロックの上には届かない。コードブロックに至っては
// Enter がコードの改行になるので、上に段落を作る道が無い。
//
// TipTap（prosemirror-gapcursor）が持つギャップカーソルは、**中に文章を持たない
// ブロックの前後にしか立たない**（区切り線・画像・数式・埋め込み）。表・リスト・引用・
// コードブロック・見出し・段落の前後では ProseMirror が「そこは無効」と答える。
//
// ここで足す物:
//   - 本文の上の余白を押す → 先頭のブロックの上にカーソル
//   - 本文の下の空きを押す → 末尾のブロックの下にカーソル
//   - 先頭のブロックの頭で ArrowUp → 上へ
//   - 末尾のブロックの尻で ArrowDown → 下へ
//
// 置き方は 2 通り。**ギャップカーソルが立つ所には立てる**（本文を変えない）。
// 立たない所には空の段落を 1 つ入れてそこに入る。**既に空の段落があればそれを使う**
// （押す度に空行が増えない）。
//
// 足した段落は**疑似行**。打たずにそこから離れたら消える。本文にも入らない
// （`docchange` を出さないので、触っていないのに「未保存」にならない）。
// 取り消しの履歴にも積まない。カーソルの置き場であって、書いた物ではない。

import { Extension } from "@tiptap/core";
import { GapCursor } from "@tiptap/pm/gapcursor";
import type { ResolvedPos } from "@tiptap/pm/model";
import type { EditorState, Transaction } from "@tiptap/pm/state";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import type { EditorView } from "@tiptap/pm/view";

type Edge = "head" | "tail";

type Pending = { pos: number | null };

const key = new PluginKey<Pending>("blockEdges");

// 疑似行が今あるか。エディタ本体が `docchange` を出すかの判断に使う。 
export function hasPendingLine(state: EditorState): boolean {
  return key.getState(state)?.pos != null;
}

// 疑似行の中身。無ければ null。 
function pendingLine(state: EditorState): { pos: number; size: number; empty: boolean } | null {
  const pos = key.getState(state)?.pos;
  if (pos == null) return null;
  const node = state.doc.nodeAt(pos);
  if (!node || node.type.name !== "paragraph") return null;
  return { pos, size: node.nodeSize, empty: node.content.size === 0 };
}

// 疑似行から出た。空のままなら消す。 
function dropPending(state: EditorState): Transaction | null {
  const line = pendingLine(state);
  if (!line) return state.tr.setMeta(key, { pos: null } satisfies Pending);
  if (!line.empty) return state.tr.setMeta(key, { pos: null } satisfies Pending);
  const inside = state.selection.from >= line.pos && state.selection.to <= line.pos + line.size;
  if (inside) return null;
  return state.tr
    .delete(line.pos, line.pos + line.size)
    .setMeta(key, { pos: null } satisfies Pending)
    .setMeta("addToHistory", false);
}


// **`valid` は prosemirror-gapcursor の実装にあるが .d.ts に出ていない。**
// ここで聞かずに GapCursor を立てると、無効な所では選択が黙って消える。
const gapValid = (GapCursor as unknown as { valid(pos: ResolvedPos): boolean }).valid;

// その端の位置（本文の先頭 = 0、末尾 = 中身の長さ）。
function posOf(view: EditorView, edge: Edge): number {
  return edge === "head" ? 0 : view.state.doc.content.size;
}

// 端に既にある空の段落。**あればそれに入る**（新しく足さない）。
function emptyAt(view: EditorView, edge: Edge) {
  const doc = view.state.doc;
  if (doc.childCount === 0) return null;
  const node = edge === "head" ? doc.firstChild : doc.lastChild;
  if (!node || node.type.name !== "paragraph" || node.content.size > 0) return null;
  return edge === "head" ? 1 : doc.content.size - 1;
}

function place(view: EditorView, edge: Edge): boolean {
  const { state } = view;
  const inside = emptyAt(view, edge);
  if (inside !== null) {
    view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, inside)).scrollIntoView());
    view.focus();
    return true;
  }

  const at = posOf(view, edge);
  const $at = state.doc.resolve(at);
  if (gapValid($at)) {
    view.dispatch(state.tr.setSelection(new GapCursor($at)).scrollIntoView());
    view.focus();
    return true;
  }

  const paragraph = state.schema.nodes.paragraph;
  if (!paragraph) return false;
  const tr = state.tr.insert(at, paragraph.create());
  tr.setSelection(TextSelection.create(tr.doc, at + 1));
  // 疑似行。打たずに離れたら消える物なので、取り消しの履歴には積まない。
  tr.setMeta(key, { pos: at } satisfies Pending);
  tr.setMeta("addToHistory", false);
  view.dispatch(tr.scrollIntoView());
  view.focus();
  return true;
}

// 押した所が、先頭のブロックより上か、末尾のブロックより下か。
// **左右の余白では返さない**（行の横を押しただけで段落が増える）。
function edgeOfClick(view: EditorView, event: MouseEvent): Edge | null {
  const dom = view.dom as HTMLElement;
  const first = dom.firstElementChild;
  const last = dom.lastElementChild;
  if (!first || !last) return null;
  const box = dom.getBoundingClientRect();
  if (event.clientX < box.left || event.clientX > box.right) return null;
  if (event.clientY < first.getBoundingClientRect().top) return "head";
  if (event.clientY > last.getBoundingClientRect().bottom) return "tail";
  return null;
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

        // 疑似行から出たら消す。**選択が動いた回だけ見る**（打っている間は消さない）。
        appendTransaction: (_trs, _old, next) => dropPending(next) ?? undefined,

        props: {
          handleDOMEvents: {
            mousedown(view, event) {
              const edge = edgeOfClick(view, event as MouseEvent);
              if (!edge) return false;
              event.preventDefault();
              return place(view, edge);
            },

            // 欄から離れた時も消す。**選択が動かないので appendTransaction では拾えない。**
            blur(view) {
              const line = pendingLine(view.state);
              if (!line) return false;
              if (line.empty) {
                view.dispatch(
                  view.state.tr
                    .delete(line.pos, line.pos + line.size)
                    .setMeta(key, { pos: null } satisfies Pending)
                    .setMeta("addToHistory", false)
                );
              } else {
                view.dispatch(view.state.tr.setMeta(key, { pos: null } satisfies Pending));
              }
              return false;
            },
          },

          handleKeyDown(view, event) {
            const up = event.key === "ArrowUp";
            const down = event.key === "ArrowDown";
            if (!up && !down) return false;
            if (event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) return false;

            const selection = view.state.selection;
            if (!selection.empty || !(selection instanceof TextSelection)) return false;

            const $from = selection.$from;
            // 一番外側のブロックのうち、先頭（末尾）の物にいるか。
            if ($from.depth === 0) return false;
            const outer = $from.before(1);
            if (up && outer !== 0) return false;
            if (down && $from.after(1) !== view.state.doc.content.size) return false;

            // その行の中で、もう上（下）に行けない所にいるか。
            if ($from.parentOffset !== (up ? 0 : $from.parent.content.size)) return false;
            if (!view.endOfTextblock(up ? "up" : "down")) return false;

            return place(view, up ? "head" : "tail");
          },
        },
      }),
    ];
  },
});
