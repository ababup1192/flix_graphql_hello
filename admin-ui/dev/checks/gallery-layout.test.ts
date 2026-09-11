// 並べた画像の枠と列、その下の空の段落に出る「+」の置き所。
//
// キャプションの開け閉めや画像の読み込みは transaction 抜きで高さを変えるので、
// 一度測ったきりの置き所は取り残される。**高さが変わる道を通してから**測る。
//
// 並べた画像の帯と 1 枚ずつへの分け方は `image.test.ts`。
import { expect, test, afterEach, vi } from "vitest";
import { mount, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const box = (el: Element) => el.getBoundingClientRect();

// キャプションを開いてから末尾の空の段落へ移す（高さが変わる道）。
async function throughCaption(h: Harness) {
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-gallery-grid")).not.toBeNull());
  h.caretInCaption();
  await settle();
  (h.editor as any).editor.commands.focus("end");
  await settle();
}

test("並べた画像の下の空の段落でも「+」が本文の枠の中に出る", async () => {
  const h = (harness = await mount("gallery"));
  await throughCaption(h);
  const plus = at(h, ".tt-plus");
  const body = box(at(h, ".tt-body"));
  expect({ hidden: plus.hidden, inside: box(plus).top >= body.top && box(plus).bottom <= body.bottom }).toEqual({
    hidden: false,
    inside: true,
  });
});

test("「+」が空の段落の高さに並ぶ", async () => {
  const h = (harness = await mount("gallery"));
  await throughCaption(h);
  const view = (h.editor as any).editor;
  const line = view.view.nodeDOM(view.state.selection.$from.before()) as HTMLElement;
  const plus = box(at(h, ".tt-plus"));
  const off = plus.top + plus.height / 2 - (box(line).top + box(line).height / 2);
  expect(Math.abs(off) <= 4).toBe(true);
});

test("並べた画像の中の 1 枚が枠に収まる", async () => {
  const h = (harness = await mount("gallery"));
  await throughCaption(h);
  const area = box(at(h, ".tt-gallery"));
  const outs = [...h.editor.querySelectorAll(".tt-gallery-grid .tt-image")].map((one) => box(one).right - area.right);
  expect(outs.map((out) => out <= 0)).toEqual(outs.map(() => true));
});

test("列を選ぶ帯は無く、列は枚数から決まる（3 枚で 3 列）", async () => {
  const h = (harness = await mount("gallery"));
  await throughCaption(h);
  expect({
    bars: h.editor.querySelectorAll(".tt-gallery-bar").length,
    columns: getComputedStyle(at(h, ".tt-gallery-grid")).gridTemplateColumns.split(" ").length,
  }).toEqual({ bars: 0, columns: 3 });
});
