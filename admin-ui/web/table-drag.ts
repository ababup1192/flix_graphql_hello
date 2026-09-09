// 行と列を掴んで入れ替える。
//
// **表の端にマウスを乗せると ↔ / ↕ になり、掴んで動かすと入れ替わる。**
// 足し引きの代わりにこれで並びを直す（末尾に足して末尾から減らす、の間を埋める）。
//
// 動かしている間に出す物:
//   - 掴んだ行・列を、元の場所で青く残す
//   - 同じ大きさの塊がカーソルに付いてくる
//   - 落ちる境目に線を出す。**線は滑って動く**（どこに入るかを目で追える）
//
// WhyNot: 本文の DOM を動かさない。ProseMirror が「知らない DOM 変更」として戻すので、
// セルに transform を掛けても効かない（class も style も戻された）。動きは全部この層で描く。

import type { Editor } from "@tiptap/core";
import { moveColumn, moveRow } from "./table-tools";

type Kind = "col" | "row";

// 動かしている最中か。
//
// **描き直しを止めるために要る。** 覆いの層は描き直しで中身を丸ごと入れ替えるので、
// 動かしている間に表からカーソルが外れて描き直しが走ると、掴んだ物も塊も線も消える
// （実際に、表の外に少しずれただけで動きが止まった）。
let dragging = false;

export function isDraggingTable(): boolean {
  return dragging;
}

type Args = {
  editor: Editor;
  table: HTMLTableElement;
  layer: HTMLElement;
  base: DOMRect;
  clip: DOMRect;
  headerRow: boolean;
  onDone: () => void;
};

// 列（行）ごとの、画面での始まりと終わり。
function bandsOf(table: HTMLTableElement, kind: Kind): Array<{ start: number; end: number }> {
  if (kind === "row") {
    return Array.from(table.rows).map((row) => {
      const at = row.getBoundingClientRect();
      return { start: at.top, end: at.bottom };
    });
  }
  const head = table.rows[0];
  if (!head) return [];
  return Array.from(head.cells).map((cell) => {
    const at = cell.getBoundingClientRect();
    return { start: at.left, end: at.right };
  });
}

//
// 落ちる先。**掴んだ物を抜いた並びの中で、何番目に挿すか**を返す。
// 抜いてから挿す（`moved`）ので、番号は抜いた後の並びで数える。
//
// WhyNot: 掴んだ物を入れたまま真ん中を跨いだかで数えない。**自分自身の真ん中も数える**ので、
// 隣に動かしたつもりが 1 つ飛ぶ（実際に飛んだ）。
//
// WhyNot: 真ん中と同じ位置を「まだ跨いでいない」にしない。幅の同じ隣どうしでは、
// 掴んだ物が隣にぴったり重なった時がちょうど真ん中で、入れ替わらずに戻る。
//
function targetOf(bands: Array<{ start: number; end: number }>, held: number, at: number): number {
  let insert = 0;
  bands.forEach((band, index) => {
    if (index !== held && at >= (band.start + band.end) / 2) insert += 1;
  });
  return insert;
}

// その番号に挿す時、線を引く場所。
function edgeOf(bands: Array<{ start: number; end: number }>, held: number, insert: number): number {
  const others = bands.filter((_, index) => index !== held);
  if (others.length === 0) return bands[held]?.start ?? 0;
  return insert === 0 ? others[0].start : (others[Math.min(insert, others.length) - 1]?.end ?? 0);
}

/** 掴みを作る。表の上端（列）と左端（行）に敷く。 */
export function tableHandles(args: Args): HTMLElement[] {
  const { table, headerRow } = args;
  const at = table.getBoundingClientRect();
  const made: HTMLElement[] = [];

  bandsOf(table, "col").forEach((band, index) => {
    const left = Math.max(band.start, args.clip.left);
    const right = Math.min(band.end, args.clip.right);
    if (right - left < 8) return;
    // 表の上の罫線をまたぐ帯。**上に置き切れない**（帯が余白を使う）ので、
    // 見出しの行の上端に少し掛ける。
    made.push(handle(args, "col", index, { left, top: at.top - 4, width: right - left, height: 10 }));
  });

  bandsOf(table, "row").forEach((band, index) => {
    // 見出しの行は動かせない。
    if (headerRow && index === 0) return;
    made.push(handle(args, "row", index, { left: at.left - 10, top: band.start, width: 10, height: band.end - band.start }));
  });

  return made;
}

function handle(args: Args, kind: Kind, index: number, box: { left: number; top: number; width: number; height: number }): HTMLElement {
  const dom = document.createElement("div");
  dom.className = `tt-handle tt-handle-${kind}`;
  dom.title = kind === "col" ? `${index + 1} 列目を動かす` : `${index + 1} 行目を動かす`;
  dom.style.left = `${box.left - args.base.left}px`;
  dom.style.top = `${box.top - args.base.top}px`;
  dom.style.width = `${box.width}px`;
  dom.style.height = `${box.height}px`;
  dom.addEventListener("mousedown", (event) => {
    event.preventDefault();
    event.stopPropagation();
    startDrag(args, kind, index, event);
  });
  return dom;
}

function startDrag(args: Args, kind: Kind, index: number, event: MouseEvent) {
  const { table, layer, base, clip } = args;
  const bands = bandsOf(table, kind);
  const held = bands[index];
  if (!held) return;
  const at = table.getBoundingClientRect();
  const across = kind === "col"
    ? { left: 0, width: held.end - held.start, top: at.top - base.top, height: at.height }
    : { left: Math.max(at.left, clip.left) - base.left, width: Math.min(at.right, clip.right) - Math.max(at.left, clip.left), top: 0, height: held.end - held.start };

  // 掴んだ物を元の場所で青く残す。
  const source = document.createElement("div");
  source.className = "tt-move-source";
  source.style.left = `${kind === "col" ? held.start - base.left : across.left}px`;
  source.style.top = `${kind === "col" ? across.top : held.start - base.top}px`;
  source.style.width = `${across.width}px`;
  source.style.height = `${across.height}px`;

  // カーソルに付いてくる塊。
  const ghost = source.cloneNode(false) as HTMLElement;
  ghost.className = "tt-move-ghost";

  // 落ちる境目の線。**滑って動く。**
  const line = document.createElement("div");
  line.className = `tt-move-line tt-move-line-${kind}`;

  layer.append(source, ghost, line);
  dragging = true;
  document.body.classList.add(kind === "col" ? "tt-dragging-col" : "tt-dragging-row");

  const grabbed = kind === "col" ? event.clientX - held.start : event.clientY - held.start;
  let target = index;

  const place = (pointer: number) => {
    const start = pointer - grabbed;
    if (kind === "col") ghost.style.left = `${start - base.left}px`;
    else ghost.style.top = `${start - base.top}px`;

    target = targetOf(bands, index, start + (held.end - held.start) / 2);
    if (args.headerRow && kind === "row" && target === 0) target = 1;
    const to = edgeOf(bands, index, target);
    if (kind === "col") line.style.left = `${to - base.left}px`;
    else line.style.top = `${to - base.top}px`;
  };
  if (kind === "col") {
    line.style.top = `${across.top}px`;
    line.style.height = `${across.height}px`;
  } else {
    line.style.left = `${across.left}px`;
    line.style.width = `${across.width}px`;
  }
  place(kind === "col" ? event.clientX : event.clientY);

  const move = (moved: MouseEvent) => place(kind === "col" ? moved.clientX : moved.clientY);
  const stop = () => {
    document.removeEventListener("mousemove", move);
    document.removeEventListener("mouseup", stop);
    dragging = false;
    document.body.classList.remove("tt-dragging-col", "tt-dragging-row");
    source.remove();
    ghost.remove();
    line.remove();
    if (target !== index) {
      if (kind === "col") moveColumn(args.editor, index, target);
      else moveRow(args.editor, index, target);
    }
    args.onDone();
  };
  document.addEventListener("mousemove", move);
  document.addEventListener("mouseup", stop);
}
