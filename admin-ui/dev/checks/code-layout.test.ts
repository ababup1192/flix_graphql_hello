// コードブロックの帯と行番号の置き所・色・打てない余白。
//
// 帯に入る値（ファイル名・言語・強調行）は `code-block.test.ts`。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const box = (el: Element) => el.getBoundingClientRect();

// 帯の余白（中の欄にもボタンにも当たらない点）。
function gapOf(bar: HTMLElement): { x: number; y: number } | null {
  const area = box(bar);
  const y = area.top + area.height / 2;
  for (let x = area.left + 3; x < area.right - 3; x += 2) {
    if (document.elementFromPoint(x, y) === bar) return { x, y };
  }
  return null;
}

test("言語とファイル名の帯がコードの下にある", async () => {
  const h = (harness = await mount("code"));
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-code pre")).not.toBeNull());
  expect(box(at(h, ".tt-code-bar")).top >= box(at(h, ".tt-code pre")).bottom - 1).toBe(true);
});

test("強調の帯が行番号と縦で揃う", async () => {
  const h = (harness = await mount("code-lines"));
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-code-line")).toHaveLength(5));
  const rows = () => [...h.editor.querySelectorAll<HTMLElement>(".tt-code-line")];
  press(rows()[0]);
  await settle();
  press(rows()[2]);
  await settle();
  press(rows()[4], { shiftKey: true });
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-code-band").length).toBeGreaterThan(0));
  const bands = [...h.editor.querySelectorAll(".tt-code-band")].map(box);
  expect(bands.map((band) => rows().some((row) => Math.abs(box(row).top - band.top) < 2))).toEqual(bands.map(() => true));
});

test("言語の候補の印に色が付く", async () => {
  const h = (harness = await mount("code-lines"));
  const field = at<HTMLInputElement>(h, ".tt-code-lang");
  await userEvent.click(field);
  await userEvent.fill(field, "c++");
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-code-item .tt-code-mark")).not.toBeNull());
  expect(getComputedStyle(at(h, ".tt-code-item .tt-code-mark")).backgroundColor).not.toBe("rgba(0, 0, 0, 0)");
});

test("選んだ言語で色が付く", async () => {
  const h = (harness = await mount("code-lines"));
  const field = at<HTMLInputElement>(h, ".tt-code-lang");
  await userEvent.click(field);
  await userEvent.fill(field, "c++");
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-code-item").length).toBeGreaterThan(0));
  await userEvent.keyboard("{Enter}");
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-body pre code span").length).toBeGreaterThan(0));
});

test("帯の余白を押して打っても帯にも doc にも入らない", async () => {
  const h = (harness = await mount("code"));
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-code-bar")).not.toBeNull());
  const gap = gapOf(at(h, ".tt-code-bar"))!;
  await userEvent.click(document.elementFromPoint(gap.x, gap.y)!);
  await userEvent.keyboard("zzzz");
  await settle();
  expect({ bar: at(h, ".tt-code-bar").textContent?.includes("zzzz"), doc: JSON.stringify(h.doc()).includes("zzzz") }).toEqual({
    bar: false,
    doc: false,
  });
});

test("焦点が外れると帯の placeholder が消える", async () => {
  const h = (harness = await mount("blocks"));
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-code")).not.toBeNull());
  (h.editor as any).editor.commands.focus("end");
  await vi.waitFor(() => expect(at(h, ".tt-code").classList.contains("is-idle")).toBe(true));
});
