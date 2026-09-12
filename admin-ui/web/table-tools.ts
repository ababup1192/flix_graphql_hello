// 表への操作。**行・列ではなく、表そのものを相手にする物**をここに置く。
//
//   - 大きさ（行数 × 列数）を選び直す
//   - カーソルのある列の寄せ
//
// 掴み（tt-grip）は行と列を相手にするので別。

import type { Editor } from "@tiptap/core";
import type { Node as PmNode } from "@tiptap/pm/model";
import { Selection } from "@tiptap/pm/state";
import { TableMap } from "@tiptap/pm/tables";

export type Align = "left" | "center" | "right";

// 表と、その位置。**`at` を渡した時はそこを起点にする**（帯はカーソルの無い表にも出る）。
function tableAt(editor: Editor, at?: number): { node: PmNode; pos: number; depth: number } | null {
  const $from = at === undefined ? editor.state.selection.$from : editor.state.doc.resolve(at);
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const node = $from.node(depth);
    if (node.type.name === "table") return { node, pos: $from.before(depth), depth };
  }
  return null;
}

/** 今の表の大きさ。表の中にいなければ null。 */
export function tableSize(editor: Editor, at?: number): { rows: number; cols: number } | null {
  const found = tableAt(editor, at);
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
export function alignColumn(editor: Editor, align: Align | null, at?: number): boolean {
  const found = tableAt(editor, at);
  if (!found) return false;
  const { state, view } = editor;
  const map = TableMap.get(found.node);
  const start = found.pos + 1;

  // 起点のセルが何列目か。
  const $from = at === undefined ? state.selection.$from : state.doc.resolve(at);
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
    const inColumn = map.map[row * map.width + column];
    if (inColumn === undefined || done.has(inColumn)) continue;
    done.add(inColumn);
    const cell = tr.doc.nodeAt(inColumn + start);
    if (!cell) continue;
    tr.setNodeMarkup(inColumn + start, undefined, { ...cell.attrs, align });
  }
  if (!tr.docChanged) return false;
  view.dispatch(tr);
  editor.commands.focus();
  return true;
}

/** カーソルのある列の今の寄せ。揃っていなければ null。 */
export function columnAlign(editor: Editor, at?: number): Align | null {
  const found = tableAt(editor, at);
  if (!found) return null;
  const $from = at === undefined ? editor.state.selection.$from : editor.state.doc.resolve(at);
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
 * マス目 1 つ分。`cell` はそのマスから始まるセル、`covered` は左か上のセルに覆われているマス。
 *
 * WhyNot: 覆われているマスを「空のセル」と同じ null で置かない。組み直しで結合が割れた時に
 * そこを埋めるべきか、隣のセルの一部として消すべきかが読めなくなる。
 */
type Slot = { kind: "cell"; node: PmNode | null; colspan: number; rowspan: number } | { kind: "covered" };

type CellSlot = Extract<Slot, { kind: "cell" }>;

const emptySlot = (): CellSlot => ({ kind: "cell", node: null, colspan: 1, rowspan: 1 });

/** 表をマス目の並びにする。結合したセルは元のマスに置き、覆われたマスは `covered`。 */
function gridOf(node: PmNode): { grid: Slot[][]; header: boolean } {
  const map = TableMap.get(node);
  const used = new Set<number>();
  const grid: Slot[][] = [];
  for (let row = 0; row < map.height; row += 1) {
    const line: Slot[] = [];
    for (let col = 0; col < map.width; col += 1) {
      const at = map.map[row * map.width + col];
      const cell = at !== undefined && !used.has(at) ? node.nodeAt(at) : null;
      if (at !== undefined && cell) {
        used.add(at);
        line.push({
          kind: "cell",
          node: cell,
          colspan: Math.max(1, cell.attrs.colspan ?? 1),
          rowspan: Math.max(1, cell.attrs.rowspan ?? 1),
        });
      } else {
        line.push({ kind: "covered" });
      }
    }
    grid.push(line);
  }
  return { grid, header: node.firstChild?.firstChild?.type.name === "tableHeader" };
}

/**
 * それぞれのセルが結合を保てるか決める。保つ物には覆うマスを割り当て、保てない物は 1 マスにする。
 *
 * WhyNot: 1 つでも保てない結合があったら全部割る、にしない。組み直しは表の形を変えるので
 * 端の結合だけがはみ出る事が多く、それで表の真ん中の結合まで割れると中身の読み方が変わる。
 */
function fitSpans(grid: Slot[][], width: number): { owner: Array<number | null>; spans: Map<number, [number, number]> } {
  const height = grid.length;
  const owner: Array<number | null> = new Array(height * width).fill(null);
  const spans = new Map<number, [number, number]>();
  const isCell = (row: number, col: number) => grid[row]?.[col]?.kind === "cell";
  for (let row = 0; row < height; row += 1) {
    for (let col = 0; col < width; col += 1) {
      const slot = grid[row][col];
      if (!slot || slot.kind !== "cell") continue;
      const at = row * width + col;
      const fits =
        row + slot.rowspan <= height &&
        col + slot.colspan <= width &&
        [...Array(slot.rowspan).keys()].every((dy) =>
          [...Array(slot.colspan).keys()].every(
            (dx) => (dy === 0 && dx === 0) || (!isCell(row + dy, col + dx) && owner[(row + dy) * width + col + dx] === null)
          )
        );
      const [rowspan, colspan] = fits ? [slot.rowspan, slot.colspan] : [1, 1];
      spans.set(at, [rowspan, colspan]);
      for (let dy = 0; dy < rowspan; dy += 1) {
        for (let dx = 0; dx < colspan; dx += 1) owner[(row + dy) * width + col + dx] = at;
      }
    }
  }
  return { owner, spans };
}

/** その位置が表の中か。 */
const inside = (at: number, found: { node: PmNode; pos: number }) =>
  at > found.pos && at < found.pos + found.node.nodeSize;

/** マス目の並びから表に戻して置き換える。 */
function writeGrid(editor: Editor, found: { node: PmNode; pos: number }, grid: Slot[][], header: boolean): boolean {
  const { state, view } = editor;
  const schema = state.schema;
  const width = grid.reduce((most, line) => Math.max(most, line.length), 0);
  const { owner, spans } = fitSpans(grid, width);
  const rows = grid.map((line, row) => {
    const type = row === 0 && header ? schema.nodes.tableHeader : schema.nodes.tableCell;
    const cells: PmNode[] = [];
    for (let col = 0; col < width; col += 1) {
      const at = row * width + col;
      const slot = line[col];
      // 覆う相手を失ったマスは空のセルで埋める。埋めないと行の幅が足りず表の形が壊れる。
      const made = slot?.kind === "cell" ? slot : owner[at] === null ? emptySlot() : null;
      if (!made) continue;
      const [rowspan, colspan] = slot?.kind === "cell" ? spans.get(at)! : [1, 1];
      const attrs = { colspan, rowspan, colwidth: null, align: made.node?.attrs.align ?? null };
      const cell =
        made.node && made.node.content.size > 0
          ? type.createChecked(attrs, made.node.content)
          : type.createAndFill(attrs);
      if (cell) cells.push(cell);
    }
    return schema.nodes.tableRow.createChecked(null, cells);
  });
  const table = found.node.type.createChecked(found.node.attrs, rows);
  const tr = state.tr.replaceWith(found.pos, found.pos + found.node.nodeSize, table);
  // 組み直した表の中へカーソルを入れ直してから送る。
  //
  // WhyNot: 元の選択を送り先にしない。帯はカーソルの無い表にも出るので、大きさを変えた時に
  // カーソルが本文の別の所に残っていると、そこまで面が飛んで編集していた表が画面から消える。
  if (!inside(state.selection.from, found) || !inside(state.selection.to, found)) {
    tr.setSelection(Selection.near(tr.doc.resolve(found.pos + 1)));
  }
  view.dispatch(tr.scrollIntoView());
  editor.commands.focus();
  return true;
}

/** 並びを 1 つ動かす。 */
function moved<T>(list: T[], from: number, to: number): T[] {
  const next = list.slice();
  const [taken] = next.splice(from, 1);
  next.splice(to, 0, taken);
  return next;
}

/**
 * 行を入れ替える。
 *
 * **見出しは place であって行ではない。** 1 行目を下へ動かすと、そこにあった行の中身が
 * 見出しになり、見出しだった中身が本文の行になる。見出しの席は常に 1 行目に残る。
 */
export function moveRow(editor: Editor, from: number, to: number): boolean {
  const found = tableAt(editor);
  if (!found || from === to) return false;
  const { grid, header } = gridOf(found.node);
  if (from < 0 || to < 0 || from >= grid.length || to >= grid.length) return false;
  return writeGrid(editor, found, moved(grid, from, to), header);
}

/** 列を入れ替える。 */
export function moveColumn(editor: Editor, from: number, to: number): boolean {
  const found = tableAt(editor);
  if (!found || from === to) return false;
  const { grid, header } = gridOf(found.node);
  const width = grid[0]?.length ?? 0;
  if (from < 0 || to < 0 || from >= width || to >= width) return false;
  return writeGrid(editor, found, grid.map((line) => moved(line, from, to)), header);
}

/**
 * 大きさを選び直す。**足りない分は空のセル、はみ出た分は中身ごと捨てる。**
 *
 * WhyNot: 行と列の足し引きの命令を並べて呼ばない。今のセルの位置に依存するので、
 * 8 行 8 列から 2 行 2 列にするような時に命令の順で結果が変わる。表を組み直す方が読める。
 *
 * WhyNot: 結合したセルを全部割らない。**新しい大きさに覆う先が収まる結合はそのまま残し、
 * はみ出す結合だけを 1 マスに割る。** 大きさを変えるのは表の外枠の話なので、枠の中に収まって
 * いる結合まで割ると、直したつもりのない所の中身の読み方が変わる。
 */
export function resizeTable(editor: Editor, rows: number, cols: number, at?: number): boolean {
  const found = tableAt(editor, at);
  if (!found) return false;
  const map = TableMap.get(found.node);
  if (map.height === rows && map.width === cols) return false;
  const { grid, header } = gridOf(found.node);
  const next: Slot[][] = [];
  for (let row = 0; row < rows; row += 1) {
    const line: Slot[] = [];
    for (let col = 0; col < cols; col += 1) line.push(grid[row]?.[col] ?? emptySlot());
    next.push(line);
  }
  return writeGrid(editor, found, next, header);
}
