// 本文が長くても道具の帯が押せる（貼り付く）所と、その上に浮く面が出る所。
//
// WhyNot: 画面の上の帯（下書き保存 / 公開）との重なりはここでは見られない。あれは Elm の
// 画面が持つ物で、この検査はエディタの部品を 1 つだけ立てる。人が実機で見る。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { mount, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(async () => {
  harness?.destroy();
  window.scrollTo(0, 0);
});

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const box = (el: Element) => el.getBoundingClientRect();

const visible = (el: Element) => box(el).top >= 0 && box(el).bottom <= window.innerHeight;

test("本文を長くして送ってもツールバーが見える", async () => {
  const h = (harness = await mount("long"));
  window.scrollTo(0, 900);
  await vi.waitFor(() => expect(window.scrollY).toBeGreaterThan(0));
  await vi.waitFor(() => expect(visible(at(h, ".tt-bar"))).toBe(true));
});

test("言語の候補が貼り付いたツールバーの下に隠れない", async () => {
  const h = (harness = await mount("long"));
  window.scrollTo(0, 900);
  await vi.waitFor(() => expect(window.scrollY).toBeGreaterThan(0));
  await userEvent.click(at(h, ".tt-code-lang"));
  await vi.waitFor(() => expect(at(h, ".tt-code-pop").hidden).toBe(false));
  const pop = box(at(h, ".tt-code-pop"));
  const hit = document.elementFromPoint((pop.left + pop.right) / 2, pop.top + 6);
  expect(!!hit?.closest(".tt-code-pop")).toBe(true);
});

// 広げて書く。**切り替えるのは Elm の画面**（`is-big` を付ける）で、送るのは本文の方。
test("広げて書くでも送ったあとツールバーが本文の上に残る", async () => {
  const h = (harness = await mount("long"));
  h.editor.classList.add("is-big");
  h.editor.style.height = "400px";
  await settle();
  at(h, ".tt-mount").scrollBy(0, 900);
  await vi.waitFor(() => expect(at(h, ".tt-mount").scrollTop).toBeGreaterThan(0));
  await vi.waitFor(() => {
    const bar = box(at(h, ".tt-bar"));
    expect({ visible: visible(at(h, ".tt-bar")), above: bar.bottom <= box(at(h, ".tt-mount")).top + 1 }).toEqual({
      visible: true,
      above: true,
    });
  });
});
