// 表の升の結合と解除。帯の 2 つのボタンと、押した後の doc の colspan / rowspan。
//
// 帯の置き所と掴みは `table-layout.test.ts`、升の数と寄せは `table.test.ts`。
import { expect, test, afterEach, vi } from "vitest";
import { CellSelection } from "@tiptap/pm/tables";
import { mount, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const all = (h: Harness, selector: string) => [...h.editor.querySelectorAll<HTMLElement>(selector)];

const inner = (h: Harness) => (h.editor as any).editor;

// doc に出てくる順の升の位置。
function cellPositions(h: Harness): number[] {
  const found: number[] = [];
  inner(h).state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "tableCell" || node.type.name === "tableHeader") found.push(pos);
  });
  return found;
}

// 升 1 つの中にカーソルを置く。**升は押しても ProseMirror のカーソルが動かない**ので、
// 選択そのものを置く（`table.test.ts` と同じ）。
function caretInCell(h: Harness, index = 0) {
  const view = inner(h);
  view.commands.focus();
  view.commands.setTextSelection(cellPositions(h)[index] + 2);
}

// 升を範囲で選ぶ。素のドラッグは再現しにくいので CellSelection を直に置く。
function selectCells(h: Harness, from: number, to: number) {
  const view = inner(h);
  const cells = cellPositions(h);
  const state = view.state;
  view.view.dispatch(state.tr.setSelection(CellSelection.create(state.doc, cells[from], cells[to])));
  view.view.focus();
}

// 帯が出るまで待つ。
async function tableBar(h: Harness) {
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-tablebar")).not.toBeNull());
}

const button = (h: Harness, title: string) =>
  all(h, ".tt-tablebar-button").find((one) => one.title.startsWith(title))!;

const off = (h: Harness, title: string) => button(h, title).classList.contains("is-off");

// 表の中の升の colspan / rowspan を出た順に並べる。
function spans(h: Harness): Array<[number, number]> {
  const found: Array<[number, number]> = [];
  inner(h).state.doc.descendants((node: any) => {
    if (node.type.name === "tableCell" || node.type.name === "tableHeader") {
      found.push([node.attrs.colspan ?? 1, node.attrs.rowspan ?? 1]);
    }
  });
  return found;
}

test("帯は 大きさ / 寄せ 3 つ / 結合 / 解除 / 表を消す の順に並ぶ", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  expect(all(h, ".tt-tablebar-button").map((one) => one.title.replace(/（.*$/, ""))).toEqual([
    "大きさを変える",
    "左に寄せる",
    "中央に寄せる",
    "右に寄せる",
    "セルを結合する",
    "結合を解く",
    "表を消す",
  ]);
});

test("削除は帯の右端にいる", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  expect(all(h, ".tt-tablebar-button").at(-1)!.classList.contains("tt-tablebar-remove")).toBe(true);
});

test("升 1 つにカーソルがある時は、結合も解除も押せない", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  expect({ merge: off(h, "セルを結合する"), split: off(h, "結合を解く") }).toEqual({ merge: true, split: true });
});

test("押せない時のヒントが title に出る", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  expect([button(h, "セルを結合する").title, button(h, "結合を解く").title]).toEqual([
    "セルを結合する（2 つ以上選ぶと押せます）",
    "結合を解く（結合したセルで押せます）",
  ]);
});

test("升を 2 つ選ぶと結合だけが押せる", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  selectCells(h, 0, 1);
  await vi.waitFor(() => expect(off(h, "セルを結合する")).toBe(false));
  expect({ merge: off(h, "セルを結合する"), split: off(h, "結合を解く") }).toEqual({ merge: false, split: true });
});

test("押せる時の title は条件の括弧が付かない", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  selectCells(h, 0, 1);
  await vi.waitFor(() => expect(button(h, "セルを結合する").title).toBe("セルを結合する"));
});

test("結合を押すと升が 1 つにまとまり colspan が 2 になる", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  selectCells(h, 0, 1);
  await vi.waitFor(() => expect(off(h, "セルを結合する")).toBe(false));
  press(button(h, "セルを結合する"));
  await vi.waitFor(() =>
    expect(spans(h)).toEqual([
      [2, 1],
      [1, 1],
      [1, 1],
      [1, 1],
      [1, 1],
    ]),
  );
});

test("結合した升にカーソルを置くと解除だけが押せる", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  selectCells(h, 0, 1);
  await vi.waitFor(() => expect(off(h, "セルを結合する")).toBe(false));
  press(button(h, "セルを結合する"));
  await vi.waitFor(() => expect(spans(h)[0]).toEqual([2, 1]));
  caretInCell(h, 0);
  await vi.waitFor(() => expect(off(h, "結合を解く")).toBe(false));
  expect({ merge: off(h, "セルを結合する"), split: off(h, "結合を解く") }).toEqual({ merge: true, split: false });
});

test("解除を押すと結合した升が割れる", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  selectCells(h, 0, 1);
  await vi.waitFor(() => expect(off(h, "セルを結合する")).toBe(false));
  press(button(h, "セルを結合する"));
  await vi.waitFor(() => expect(spans(h)[0]).toEqual([2, 1]));
  caretInCell(h, 0);
  await vi.waitFor(() => expect(off(h, "結合を解く")).toBe(false));
  press(button(h, "結合を解く"));
  await vi.waitFor(() =>
    expect(spans(h)).toEqual([
      [1, 1],
      [1, 1],
      [1, 1],
      [1, 1],
      [1, 1],
      [1, 1],
    ]),
  );
});

test("押せないボタンは消えずに残る", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await settle();
  expect(all(h, ".tt-tablebar-button")).toHaveLength(7);
});

test("寄せと結合の間に仕切りが 1 本入る", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await tableBar(h);
  expect(at(h, ".tt-tablebar").querySelectorAll(".tt-tablebar-divider")).toHaveLength(1);
});
