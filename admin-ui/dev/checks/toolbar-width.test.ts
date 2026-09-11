// 窓の幅を変えても道具の帯が横に溢れない。
//
// 帯に何が並ぶかは `toolbar.test.ts`。
import { expect, test, afterEach, vi } from "vitest";
import { page } from "vitest/browser";
import { mount, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(async () => {
  harness?.destroy();
  await page.viewport(1440, 900);
});

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;

for (const width of [1440, 1024, 768]) {
  test(`幅 ${width} でツールバーが横に溢れず、ボタンも枠からはみ出さない`, async () => {
    const h = (harness = await mount("empty"));
    await page.viewport(width, 900);
    // **窓の大きさが変わり切るまで待つ。** 変えた直後に測ると前の幅の帯を見る。
    await vi.waitFor(() => expect(window.innerWidth).toBe(width));
    await vi.waitFor(() => {
      const bar = at(h, ".tt-bar");
      const area = bar.getBoundingClientRect();
      expect({
        fits: bar.scrollWidth <= bar.clientWidth + 1,
        outside: [...bar.children].filter((one) => one.getBoundingClientRect().right > area.right + 1).length,
      }).toEqual({ fits: true, outside: 0 });
    });
  });
}
