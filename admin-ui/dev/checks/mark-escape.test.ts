// 掛けた装飾から抜ける道（`web/mark-escape.ts`）。
//
// 抜けたかどうかは**次に打った 1 文字に乗ったマーク**で見る。storedMarks は
// 入力規則が消した後だと空になり、抜けたのか掛かっていないのか区別できない。
// 本文は docs/design/editor-dom-parts.md の「マークの抜け方」。
import { expect, test, afterEach } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, toEnd, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

// 文字を選んで帯の道具で掛けた形を作る。**掛けた直後は storedMarks が立たない**ので、
// TipTap の `exitable` が動かない（帯の道具は選ばないと押せないため、必ずこの形になる）。
async function marked(name: string): Promise<Harness> {
  const h = (harness = await mount("empty"));
  toEnd(h);
  h.apply(name);
  return h;
}

test("→ キーでコードの箱から出る", async () => {
  const h = await marked("code");
  await userEvent.keyboard("abc");
  expect(h.lastMarks()).toContain("code");
  await userEvent.keyboard("{ArrowRight}x");
  expect(h.lastMarks()).not.toContain("code");
});

test("Space 2 回でコードの箱から出る。1 つ目は中に残る", async () => {
  const h = await marked("code");
  await userEvent.keyboard("a b");
  expect(h.text()).toContain("a b");
  expect(h.lastMarks()).toContain("code");
  await userEvent.keyboard("  x");
  expect(h.lastMarks()).not.toContain("code");
});

test("下線でも同じ道で抜けられる", async () => {
  const h = await marked("underline");
  await userEvent.keyboard("abc");
  expect(h.lastMarks()).toContain("underline");
  await userEvent.keyboard("{ArrowRight}x");
  expect(h.lastMarks()).not.toContain("underline");
});

test("Enter で段落を変えると装飾が落ちる", async () => {
  const h = await marked("underline");
  await userEvent.keyboard("abc{Enter}x");
  expect(h.lastMarks()).not.toContain("underline");
});
