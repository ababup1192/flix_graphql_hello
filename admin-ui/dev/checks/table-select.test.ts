// 表のセルを範囲で選んだ時の見た目。選んだセルが選んでいないセルと違って見えるか。
//
// 結合ボタンの押せる / 押せないは `table-merge.test.ts`。
import { expect, test, afterEach } from "vitest";
import { CellSelection } from "@tiptap/pm/tables";
import { mount, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => {
  harness?.destroy();
  delete document.documentElement.dataset.theme;
});

const inner = (h: Harness) => (h.editor as any).editor;

const cells = (h: Harness) => [...h.editor.querySelectorAll<HTMLElement>(".tt-body table th, .tt-body table td")];

// doc に出てくる順のセルの位置。
function cellPositions(h: Harness): number[] {
  const found: number[] = [];
  inner(h).state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "tableCell" || node.type.name === "tableHeader") found.push(pos);
  });
  return found;
}

// セルを範囲で選ぶ。素のドラッグは再現しにくいので CellSelection を直に置く。
function selectCells(h: Harness, from: number, to: number) {
  const view = inner(h);
  const positions = cellPositions(h);
  const state = view.state;
  view.view.dispatch(state.tr.setSelection(CellSelection.create(state.doc, positions[from], positions[to])));
  view.view.focus();
}

// セル 1 つにカーソルを置いて選択を解く。
function caretInCell(h: Harness, index = 0) {
  const view = inner(h);
  view.commands.focus();
  view.commands.setTextSelection(cellPositions(h)[index] + 2);
}

// "rgb(r, g, b)" と "#rrggbb" と color-mix が返す "color(srgb r g b)" を 0..255 の 3 つに。
function channels(color: string): [number, number, number] {
  const hex = color.trim().match(/^#([\da-f]{6})$/i);
  if (hex) {
    const n = parseInt(hex[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  const scale = color.trim().startsWith("color(srgb") ? 255 : 1;
  const found = color.match(/[\d.]+/g)!.map(Number);
  return [found[0] * scale, found[1] * scale, found[2] * scale];
}

// WCAG の相対輝度。
function luminance(color: string): number {
  const [r, g, b] = channels(color).map((one) => {
    const v = one / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

// 2 色のコントラスト比（1 なら同じ色）。
function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

const background = (cell: HTMLElement) => getComputedStyle(cell).backgroundColor;

// セルの地。選んでいないセルは自分では塗らないので、実際に透けて見える面の色を使う。
const ground = () => getComputedStyle(document.documentElement).getPropertyValue("--color-panel");

for (const theme of ["light", "dark"] as const) {
  test(`${theme}: 複数のセルを選ぶと、選んだセルの背景が選んでいないセルとはっきり違う`, async () => {
    document.documentElement.dataset.theme = theme;
    const h = (harness = await mount("table"));
    selectCells(h, 0, 1);
    const [first, second, other] = cells(h);
    expect({
      同じ: background(first) === background(second),
      選んでいない方は塗らない: background(other) === "rgba(0, 0, 0, 0)",
      差: contrast(background(first), ground()) >= 1.35,
    }).toEqual({ 同じ: true, 選んでいない方は塗らない: true, 差: true });
  });

  test(`${theme}: 選んだセルの中の文字はそのまま読める`, async () => {
    document.documentElement.dataset.theme = theme;
    const h = (harness = await mount("table"));
    selectCells(h, 0, 1);
    const first = cells(h)[0];
    expect(contrast(background(first), getComputedStyle(first).color) >= 4.5).toBe(true);
  });

  test(`${theme}: 選択を解くと背景が選んでいないセルと同じに戻る`, async () => {
    document.documentElement.dataset.theme = theme;
    const h = (harness = await mount("table"));
    const plain = background(cells(h)[2]);
    selectCells(h, 0, 1);
    caretInCell(h, 0);
    expect(background(cells(h)[0])).toBe(plain);
  });
}

test("選んだセルには範囲の形が分かる内側の枠が付く", async () => {
  const h = (harness = await mount("table"));
  selectCells(h, 0, 1);
  const [first, , other] = cells(h);
  expect({
    選んだ: getComputedStyle(first).boxShadow !== "none",
    選んでいない: getComputedStyle(other).boxShadow !== "none",
  }).toEqual({ 選んだ: true, 選んでいない: false });
});
