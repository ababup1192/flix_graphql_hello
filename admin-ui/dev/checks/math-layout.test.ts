// 数式の箱の当たり判定と、ホバーで出る右上の削除（`docs/design/richtext-math-ui.md` の案 B）。
//
// TeX の値と焦点の行き先は `math.test.ts`。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { mount, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const box = (el: Element) => el.getBoundingClientRect();

// 焦点と指を数式の箱から離す。**指も離す。**押した直後は指が箱の上に残っていて、
// ホバーで出る物が出たままになる。
async function away(h: Harness) {
  (h.editor as any).editor.commands.focus("start");
  await userEvent.hover(at(h, ".tt-bar"));
  await settle();
}

test("TeX の欄は掴んで伸ばせない", async () => {
  const h = (harness = await mount("math"));
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-mathblock-src")).not.toBeNull());
  expect(getComputedStyle(at(h, ".tt-mathblock-src")).resize).toBe("none");
});

for (const [where, side] of [["箱の左端", 3], ["箱の右端", -3]] as const) {
  test(`${where}を押しても TeX の欄が開く`, async () => {
    const h = (harness = await mount("math"));
    await vi.waitFor(() => expect(h.editor.querySelector(".tt-mathblock")).not.toBeNull());
    await away(h);
    const area = box(at(h, ".tt-mathblock"));
    const x = side < 0 ? area.right + side : area.left + side;
    press(document.elementFromPoint(x, area.top + area.height / 2)!);
    await vi.waitFor(() => expect(at(h, ".tt-mathblock-src").hidden).toBe(false));
  });
}

test("触っていない間は右上の削除が見えない", async () => {
  const h = (harness = await mount("math"));
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-mathblock .tt-block-corner")).not.toBeNull());
  await away(h);
  expect(getComputedStyle(at(h, ".tt-mathblock .tt-block-corner")).opacity).toBe("0");
});

test("ホバーすると右上の削除が出る", async () => {
  const h = (harness = await mount("math"));
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-mathblock .tt-block-corner")).not.toBeNull());
  await away(h);
  await userEvent.hover(at(h, ".tt-mathblock"));
  await vi.waitFor(() => expect(getComputedStyle(at(h, ".tt-mathblock .tt-block-corner")).opacity).toBe("1"));
});
