// 表の帯と掴みの置き所、掴んで動かす所、幅を変えた時のはみ出し。
//
// 中身（升の数・寄せの入り方・升の中に入れられる物）は `table.test.ts`。
import { expect, test, afterEach, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { mount, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(async () => {
  harness?.destroy();
  await page.viewport(1440, 900);
});

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const all = (h: Harness, selector: string) => [...h.editor.querySelectorAll<HTMLElement>(selector)];
const box = (el: Element) => el.getBoundingClientRect();

// 最初の升の中にカーソルを置く。**升は押しても ProseMirror のカーソルが動かない**ので、
// 選択そのものを置く（`table.test.ts` と同じ）。
function caretInCell(h: Harness) {
  const view = (h.editor as any).editor;
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "tableHeader" && found < 0) found = pos;
  });
  view.commands.focus();
  view.commands.setTextSelection(found + 2);
}

// 表の道具が出るまで待つ。
async function tableTools(h: Harness) {
  caretInCell(h);
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-tablebar")).not.toBeNull());
}

const headings = (h: Harness) =>
  all(h, ".tt-body table tr:first-child th, .tt-body table tr:first-child td").map((cell) => cell.textContent);

test("表の上に出る帯は 1 つ", async () => {
  const h = (harness = await mount("table"));
  await tableTools(h);
  expect(h.editor.querySelectorAll(".tt-tablebar")).toHaveLength(1);
});

// 結合と解除の押せる・押せないと、押した結果は `table-merge.test.ts`。
test("帯は 大きさ / 寄せ 3 つ / 結合 / 解除 / 表を消す の順に並ぶ", async () => {
  const h = (harness = await mount("table"));
  await tableTools(h);
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

test("古い掴み（tt-grip）は出ない", async () => {
  const h = (harness = await mount("table"));
  await tableTools(h);
  expect(h.editor.querySelectorAll(".tt-grip")).toHaveLength(0);
});

test("帯が表の真上に付く", async () => {
  const h = (harness = await mount("table"));
  await tableTools(h);
  const bar = box(at(h, ".tt-tablebar"));
  const table = box(at(h, ".tt-body table"));
  expect({ left: Math.abs(bar.left - table.left) < 4, above: bar.bottom <= table.top + 4 }).toEqual({
    left: true,
    above: true,
  });
});

test("列の掴みが列の数だけ、行の掴みが行の数だけ出る（見出しの行も入る）", async () => {
  const h = (harness = await mount("table"));
  await tableTools(h);
  expect({ col: all(h, ".tt-handle-col").length, row: all(h, ".tt-handle-row").length }).toEqual({ col: 3, row: 2 });
});

test("列の掴みが列の幅と左端に揃う", async () => {
  const h = (harness = await mount("table"));
  await tableTools(h);
  const cells = all(h, ".tt-body table tr:first-child th, .tt-body table tr:first-child td").map(box);
  const gaps = all(h, ".tt-handle-col").map((handle, index) => ({
    width: Math.abs(box(handle).width - cells[index].width) <= 3,
    left: Math.abs(box(handle).left - cells[index].left) <= 3,
  }));
  expect(gaps).toEqual(cells.map(() => ({ width: true, left: true })));
});

// 掴んで動かす。掴みは mousedown で始まり、追うのは document の mousemove / mouseup。
function drag(h: Harness, from: HTMLElement, to: HTMLElement, over: number) {
  const start = box(from);
  const end = box(to);
  press(from, { clientX: start.left + start.width / 2, clientY: start.top + 5 });
  document.dispatchEvent(
    new MouseEvent("mousemove", { bubbles: true, clientX: end.left + end.width / 2 + over, clientY: end.top + 5 }),
  );
}

test("動かしている間は落ちる境目の線が 1 本出る", async () => {
  const h = (harness = await mount("table"));
  await tableTools(h);
  const handles = all(h, ".tt-handle-col");
  drag(h, handles[0], handles[1], 6);
  expect(h.editor.querySelectorAll(".tt-move-line")).toHaveLength(1);
  document.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
});

test("掴んで列を入れ替えられる", async () => {
  const h = (harness = await mount("table"));
  await tableTools(h);
  expect(headings(h)).toEqual(["1-1", "1-2", "1-3"]);
  const handles = all(h, ".tt-handle-col");
  drag(h, handles[0], handles[1], 6);
  document.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
  await vi.waitFor(() => expect(headings(h)).toEqual(["1-2", "1-1", "1-3"]));
});

test("表から離れると帯が消え、表に乗せると戻る", async () => {
  const h = (harness = await mount("table"));
  await tableTools(h);
  (h.editor as any).editor.commands.focus("end");
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-tablebar")).toHaveLength(0));
  at(h, ".tt-body table th").dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-tablebar")).toHaveLength(1));
});

// 幅を変えても本文の枠を越えない。**列の多い表と、折り返せない長い文字**の両方で見る。
for (const width of [1440, 1024, 768]) {
  test(`幅 ${width} で列の多い表が本文の枠を越えず、ページも横に送れない`, async () => {
    const h = (harness = await mount("table-wide"));
    caretInCell(h);
    await settle();
    await userEvent.keyboard("とても長い日本語のセルの中身です。折り返して読めるはずです。");
    await page.viewport(width, 900);
    // **窓の大きさが変わり切るまで待つ。** 変えた直後に測ると、前の幅のままの敷き直しを見る。
    await vi.waitFor(() => expect(window.innerWidth).toBe(width));
    await vi.waitFor(() => {
      const wrap = box(at(h, ".tt-body .tableWrapper"));
      const body = box(at(h, ".tt-body"));
      expect({
        inBody: wrap.right <= body.right + 1,
        noPageScroll: document.documentElement.scrollWidth <= window.innerWidth + 1,
      }).toEqual({ inBody: true, noPageScroll: true });
    });
  });
}
