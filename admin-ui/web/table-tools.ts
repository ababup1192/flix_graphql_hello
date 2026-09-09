// 表への操作。**行・列ではなく、表そのものを相手にする物**をここに置く。
//
//   - 大きさ（行数 × 列数）を選び直す
//   - カーソルのある列の寄せ
//
// 掴み（tt-grip）は行と列を相手にするので別。

import type { Editor } from "@tiptap/core";
import type { Node as PmNode } from "@tiptap/pm/model";
import { TableMap } from "@tiptap/pm/tables";

export type Align = "left" | "center" | "right";

// カーソルが入っている表と、その位置。
function tableAt(editor: Editor): { node: PmNode; pos: number; depth: number } | null {
  const $from = editor.state.selection.$from;
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const node = $from.node(depth);
    if (node.type.name === "table") return { node, pos: $from.before(depth), depth };
  }
  return null;
}

/** 今の表の大きさ。表の中にいなければ null。 */
export function tableSize(editor: Editor): { rows: number; cols: number } | null {
  const found = tableAt(editor);
  if (!found) return null;
  const map = TableMap.get(found.node);
  return { rows: map.height, cols: map.width };
}

/**
 * カーソルのある列の寄せを変える。**列の全セルに同じ値を入れる。**
 *
 * WhyNot: セル 1 つだけに入れない。Markdown の区切り行は列に 1 つしか寄せを持てないので、
 * 列の中で混ざると書き出しで落ちる（MCP の出力と履歴の差分がここを通る）。
 */
export function alignColumn(editor: Editor, align: Align | null): boolean {
  const found = tableAt(editor);
  if (!found) return false;
  const { state, view } = editor;
  const map = TableMap.get(found.node);
  const start = found.pos + 1;

  // カーソルのセルが何列目か。
  const $from = state.selection.$from;
  let cellPos = -1;
  for (let depth = $from.depth; depth > found.depth; depth -= 1) {
    const node = $from.node(depth);
    if (node.type.name === "tableCell" || node.type.name === "tableHeader") cellPos = $from.before(depth);
  }
  if (cellPos < 0) return false;
  const column = map.colCount(cellPos - start);

  const tr = state.tr;
  const done = new Set<number>();
  for (let row = 0; row < map.height; row += 1) {
    const at = map.map[row * map.width + column];
    if (at === undefined || done.has(at)) continue;
    done.add(at);
    const cell = tr.doc.nodeAt(at + start);
    if (!cell) continue;
    tr.setNodeMarkup(at + start, undefined, { ...cell.attrs, align });
  }
  if (!tr.docChanged) return false;
  view.dispatch(tr);
  editor.commands.focus();
  return true;
}

/** カーソルのある列の今の寄せ。揃っていなければ null。 */
export function columnAlign(editor: Editor): Align | null {
  const found = tableAt(editor);
  if (!found) return null;
  const $from = editor.state.selection.$from;
  for (let depth = $from.depth; depth > found.depth; depth -= 1) {
    const node = $from.node(depth);
    if (node.type.name === "tableCell" || node.type.name === "tableHeader") {
      const align = node.attrs.align;
      return align === "left" || align === "center" || align === "right" ? align : null;
    }
  }
  return null;
}

/**
 * 大きさを選び直す。**足りない分は空のセル、はみ出た分は中身ごと捨てる。**
 *
 * WhyNot: 行と列の足し引きの命令を並べて呼ばない。今のセルの位置に依存するので、
 * 8 行 8 列から 2 行 2 列にするような時に命令の順で結果が変わる。表を組み直す方が読める。
 *
 * WhyNot: 結合したセルを保たない。エディタは結合を作れないが、API や取り込みが入れた表は
 * 1 マスずつに割れる。**保つと組み直しの筋がもう 1 本増える**ので、割る方に倒す。
 */
export function resizeTable(editor: Editor, rows: number, cols: number): boolean {
  const found = tableAt(editor);
  if (!found) return false;
  const { state, view } = editor;
  const schema = state.schema;
  const map = TableMap.get(found.node);
  if (map.height === rows && map.width === cols) return false;

  // 元のセルは 1 つにつき 1 回だけ使う（結合していると同じ位置が複数のマスに出る）。
  const used = new Set<number>();
  const header = found.node.firstChild?.firstChild?.type.name === "tableHeader";

  const madeRows: PmNode[] = [];
  for (let row = 0; row < rows; row += 1) {
    const type = row === 0 && header ? schema.nodes.tableHeader : schema.nodes.tableCell;
    const cells: PmNode[] = [];
    for (let col = 0; col < cols; col += 1) {
      const at = row < map.height && col < map.width ? map.map[row * map.width + col] : undefined;
      let old: PmNode | null = null;
      if (at !== undefined && !used.has(at)) {
        used.add(at);
        old = found.node.nodeAt(at);
      }
      const attrs = { colspan: 1, rowspan: 1, colwidth: null, align: old?.attrs.align ?? null };
      const made = old && old.content.size > 0 ? type.createChecked(attrs, old.content) : type.createAndFill(attrs);
      if (made) cells.push(made);
    }
    madeRows.push(schema.nodes.tableRow.createChecked(null, cells));
  }
  const table = found.node.type.createChecked(found.node.attrs, madeRows);
  const tr = state.tr.replaceWith(found.pos, found.pos + found.node.nodeSize, table);
  view.dispatch(tr.scrollIntoView());
  editor.commands.focus();
  return true;
}
